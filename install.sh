#!/usr/bin/env bash
# =============================================================================
#  e3372-proxmox — one-shot driver/setup for Huawei E3372 HiLink modems
#  on Proxmox VE / Debian.  БЕЗ ЗАВИСИМОСТЕЙ и БЕЗ apt.
#
#  Использует только то, что уже есть в Proxmox из коробки:
#    systemd-networkd, udev, iproute2, bash. Ничего не скачивает.
#
#  Что делает:
#    1. поднимает интерфейсы модемов по DHCP (systemd-networkd, матч по драйверу)
#    2. loose rp_filter (иначе ответы на 20 iface режутся)
#    3. per-modem policy routing (своя таблица на модем) — реконсайлер + systemd timer
#       (замена networkd-dispatcher, без сторонних пакетов)
#    4. защита от коллизии подсети модема с сетью хоста (авто-skip)
#    5. ставит диагностику e3372-check
#
#  Одна команда на новом сервере:
#    bash <(curl -fsSL https://raw.githubusercontent.com/Tovarish666/e3372-proxmox/main/install.sh)
#
#  Идемпотентно.
# =============================================================================
set -euo pipefail

NETDIR=/etc/systemd/network
ROUTE_SH=/usr/local/sbin/e3372-route.sh
CHECK=/usr/local/bin/e3372-check
OLD_HOOK=/etc/networkd-dispatcher/routable.d/50-e3372   # чистим наследие старой версии

c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_r=$'\033[1;31m'; c_0=$'\033[0m'
log(){  printf '%s[e3372]%s %s\n' "$c_g" "$c_0" "$*"; }
warn(){ printf '%s[e3372]%s %s\n' "$c_y" "$c_0" "$*"; }
die(){  printf '%s[e3372] %s%s\n' "$c_r" "$*" "$c_0" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "нужен root"
command -v systemctl >/dev/null 2>&1 || die "нужен systemd"
command -v ip >/dev/null 2>&1        || die "нужен iproute2 (есть в Proxmox по умолчанию)"

# systemd-networkd входит в systemd, отдельно ставить НЕ надо
[ -x /lib/systemd/systemd-networkd ] || [ -x /usr/lib/systemd/systemd-networkd ] \
  || warn "systemd-networkd бинарь не найден — очень необычно для Proxmox, продолжаю"

log "1/5 драйверы ядра (есть в стоке, грузим на всякий)…"
modprobe -a cdc_ether rndis_host cdc_ncm huawei_cdc_ncm 2>/dev/null || true
[ -f "$OLD_HOOK" ] && { rm -f "$OLD_HOOK"; log "удалён старый networkd-dispatcher hook"; }

# ---------------------------------------------------------------------------
log "2/5 systemd-networkd: подъём HiLink-интерфейсов по DHCP…"
install -d "$NETDIR"
cat > "$NETDIR/25-hilink.network" <<'NET'
# Матчим ТОЛЬКО модемы по драйверу (physical NIC/vmbr не трогаем).
# У всех E3372 одинаковый MAC — матч по имени/MAC не годится.
[Match]
Driver=cdc_ether rndis_host cdc_ncm huawei_cdc_ncm

[Network]
DHCP=ipv4
LinkLocalAddressing=no
IPv6AcceptRA=no

[DHCPv4]
UseDNS=no
UseNTP=no
UseGateway=false
UseRoutes=false

[Link]
RequiredForOnline=no
NET

# ---------------------------------------------------------------------------
log "3/5 sysctl: loose reverse-path filter…"
cat > /etc/sysctl.d/99-e3372.conf <<'SYS'
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
SYS
sysctl -q --system >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
log "4/5 policy-routing: реконсайлер + systemd timer (без внешних демонов)…"
install -d "$(dirname "$ROUTE_SH")"
cat > "$ROUTE_SH" <<'ROUTE'
#!/bin/bash
# Идемпотентно приводит per-modem policy routing к нужному виду.
# Подсеть выводится из выданного DHCP адреса 192.168.<N>.100.
sysctl -q -w net.ipv4.conf.all.rp_filter=2 2>/dev/null || true
ip -4 -o addr show | awk '/192\.168\.[0-9]+\.100\//{print $2, $4}' | while read -r IFACE CIDR; do
  IP=${CIDR%/*}; N=$(printf '%s' "$IP" | cut -d. -f3)
  # коллизия: если 192.168.<N>.x занята другим (не этим) интерфейсом (LAN хоста) — пропускаем
  if ip -4 -o addr show | awk -v pat="192.168.$N." -v me="$IFACE" \
       '$2!=me && index($4,pat)==1 {f=1} END{exit !f}'; then
    logger -t e3372 "skip N=$N ($IFACE): подсеть занята хостом"
    continue
  fi
  ip route replace 192.168.$N.0/24 dev "$IFACE" src "$IP" table "$N"
  ip route replace default via 192.168.$N.1 dev "$IFACE" table "$N"
  ip rule show | grep -q "from $IP " || ip rule add from "$IP/32" table "$N" priority $((1000+N))
done
ROUTE
chmod +x "$ROUTE_SH"

cat > /etc/systemd/system/e3372-route.service <<EOF
[Unit]
Description=e3372 per-modem policy routing (reconcile)
After=systemd-networkd.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$ROUTE_SH
EOF

cat > /etc/systemd/system/e3372-route.timer <<'EOF'
[Unit]
Description=e3372 routing reconcile (boot + каждые 15с, ловит hotplug)

[Timer]
OnBootSec=10
OnUnitActiveSec=15
AccuracySec=2s

[Install]
WantedBy=timers.target
EOF

# udev-«толчок»: при появлении сетевого устройства сразу дёрнуть реконсайлер
cat > /etc/udev/rules.d/72-e3372.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="net", ENV{ID_NET_DRIVER}=="cdc_ether", RUN+="/bin/systemctl start --no-block e3372-route.service"
ACTION=="add", SUBSYSTEM=="net", ENV{ID_NET_DRIVER}=="rndis_host", RUN+="/bin/systemctl start --no-block e3372-route.service"
EOF
udevadm control --reload 2>/dev/null || true

# ---------------------------------------------------------------------------
log "5/5 включаю сервисы + применяю сейчас…"
systemctl daemon-reload
systemctl enable --now systemd-networkd >/dev/null 2>&1 || true
systemctl enable --now e3372-route.timer >/dev/null 2>&1 || true
systemctl restart systemd-networkd
sleep 2
systemctl start e3372-route.service || true

# диагностика
cat > "$CHECK" <<'CHK'
#!/bin/bash
# Проверка модемов E3372 HiLink: USB -> iface/IP -> webui -> cellular -> exit IP
echo "== USB (12d1:14dc): $(lsusb | grep -c 12d1:14dc) шт. =="
printf "%-4s %-16s %-16s %-6s %-9s %-5s %s\n" N IFACE HOST-IP WEBUI CONN NET EXIT-IP
ip -4 -o addr show | awk '/192\.168\.[0-9]+\.100\//{print $2,$4}' | sort -t. -k3 -n | \
while read -r IFACE CIDR; do
  IP=${CIDR%/*}; N=$(printf '%s' "$IP" | cut -d. -f3); GW="192.168.$N.1"
  ST=$(curl -s -m3 "http://$GW/api/monitoring/status" 2>/dev/null)
  if [ -z "$ST" ]; then WEB="—"; CONN="—"; NET="—"
  else
    WEB=ok
    CS=$(printf '%s' "$ST" | grep -oP '(?<=<ConnectionStatus>)[0-9]+')
    NET=$(printf '%s' "$ST" | grep -oP '(?<=<CurrentNetworkType>)[0-9]+'); NET=${NET:-?}
    case "$CS" in 901)CONN=онлайн;;902)CONN=offline;;900)CONN=конн;;904|905)CONN=нет-сети;;"")CONN="?";;*)CONN=$CS;;esac
  fi
  EXIT=$(curl --interface "$IP" -s -m8 http://ip.me 2>/dev/null); [ -z "$EXIT" ] && EXIT="—"
  printf "%-4s %-16s %-16s %-6s %-9s %-5s %s\n" "$N" "$IFACE" "$IP" "$WEB" "$CONN" "$NET" "$EXIT"
done
CHK
chmod +x "$CHECK"

echo
log "готово — без единой внешней зависимости. проверка:  e3372-check"
echo
"$CHECK" 2>/dev/null || warn "curl не найден для диагностики — сам роутинг это не затрагивает"
echo
warn "Роутинг переприменяется на boot и каждые 15с (ловит hotplug). Лог: journalctl -t e3372"
