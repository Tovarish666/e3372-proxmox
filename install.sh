#!/usr/bin/env bash
# =============================================================================
#  e3372-proxmox — one-shot driver/setup for Huawei E3372 HiLink modems
#  on a Proxmox VE / Debian host.
#
#  Что делает за один прогон:
#    1. ставит usb-modeswitch (+data), networkd-dispatcher
#    2. переводит модемы в сетевую композицию HiLink (CD-ROM -> eth)
#    3. поднимает все интерфейсы модемов по DHCP (systemd-networkd)
#    4. вешает per-modem policy-routing (авто на boot и hotplug)
#    5. защита от коллизии подсети модема с сетью хоста (авто-skip)
#    6. ставит диагностику `e3372-check`
#
#  Запуск на новом сервере одной командой:
#    bash <(curl -fsSL https://raw.githubusercontent.com/Tovarish666/e3372-proxmox/main/install.sh)
#
#  Идемпотентно — можно гонять повторно.
# =============================================================================
set -euo pipefail

HOST_OCTET=100          # HiLink раздаёт хосту 192.168.<N>.100
NETDIR=/etc/systemd/network
HOOK=/etc/networkd-dispatcher/routable.d/50-e3372
CHECK=/usr/local/bin/e3372-check

c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_r=$'\033[1;31m'; c_0=$'\033[0m'
log(){  printf '%s[e3372]%s %s\n' "$c_g" "$c_0" "$*"; }
warn(){ printf '%s[e3372]%s %s\n' "$c_y" "$c_0" "$*"; }
die(){  printf '%s[e3372] %s%s\n' "$c_r" "$*" "$c_0" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "нужен root"
command -v apt-get >/dev/null 2>&1 || die "поддерживается только Debian/Proxmox (apt)"

# ---------------------------------------------------------------------------
log "1/6 пакеты…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq usb-modeswitch usb-modeswitch-data networkd-dispatcher curl iproute2 >/dev/null
# драйверы для CDC-Ether/RNDIS/NCM есть в стоковом ядре Proxmox — грузим на всякий
modprobe -a cdc_ether rndis_host cdc_ncm huawei_cdc_ncm 2>/dev/null || true

# ---------------------------------------------------------------------------
log "2/6 systemd-networkd: подъём HiLink-интерфейсов по DHCP…"
install -d "$NETDIR"
cat > "$NETDIR/25-hilink.network" <<'NET'
# Матчим ТОЛЬКО модемы по драйверу (физический NIC/vmbr не трогаем).
# У всех E3372 одинаковый MAC — поэтому матч по имени/MAC не годится.
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
log "3/6 sysctl: loose reverse-path filter (иначе ответы на 20 iface режутся)…"
cat > /etc/sysctl.d/99-e3372.conf <<'SYS'
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
SYS
sysctl -q --system >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
log "4/6 policy-routing hook (авто на boot/hotplug)…"
install -d "$(dirname "$HOOK")"
cat > "$HOOK" <<'HOOK'
#!/bin/bash
# networkd-dispatcher вызывает с env $IFACE, когда линк становится routable.
# Подсеть выводим из выданного DHCP адреса 192.168.<N>.100.
ip4=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | head -n1)
[ -n "$ip4" ] || exit 0
IP=${ip4%/*}
case "$IP" in 192.168.*."100") ;; *) exit 0 ;; esac
N=$(printf '%s' "$IP" | cut -d. -f3)

# --- защита от коллизии: если 192.168.<N>.x уже занята другим (не модемным)
#     интерфейсом (напр. LAN хоста на vmbr0) — не трогаем маршруты вообще.
if ip -4 -o addr show | awk -v pat="192.168.$N." -v me="$IFACE" \
     '$2!=me && index($4,pat)==1 {f=1} END{exit !f}'; then
  logger -t e3372 "skip N=$N ($IFACE): подсеть занята хостом"
  exit 0
fi

ip route replace 192.168.$N.0/24 dev "$IFACE" src "$IP" table "$N"
ip route replace default via 192.168.$N.1 dev "$IFACE" table "$N"
ip rule show | grep -q "from $IP " || ip rule add from "$IP/32" table "$N" priority $((1000+N))
logger -t e3372 "up: $IFACE $IP -> table $N (gw 192.168.$N.1)"
HOOK
chmod +x "$HOOK"

# ---------------------------------------------------------------------------
log "5/6 сервисы + применяю к уже поднятым модемам…"
systemctl enable --now systemd-networkd    >/dev/null 2>&1 || true
systemctl enable --now networkd-dispatcher >/dev/null 2>&1 || true
systemctl restart systemd-networkd
sleep 2   # дать DHCP выдать адреса

# dispatcher срабатывает только на переходах — прогоняем hook руками
# для интерфейсов, что уже подняты сейчас.
applied=0
while read -r IFACE _; do
  [ -n "$IFACE" ] || continue
  IFACE="$IFACE" bash "$HOOK" && applied=$((applied+1)) || true
done < <(ip -4 -o addr show | awk '/192\.168\.[0-9]+\.100\//{print $2, $4}')
log "policy-routing применён к $applied модемам"

# ---------------------------------------------------------------------------
log "6/6 ставлю диагностику e3372-check…"
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
log "готово. проверка:  e3372-check"
echo
"$CHECK" || true
echo
warn "Если у модема EXIT-IP='—' при CONN=онлайн — перепроверь его APN/сигнал."
warn "Модемы, чья подсеть 192.168.<N>.x совпала с сетью хоста, авто-пропущены (см. journalctl -t e3372)."
