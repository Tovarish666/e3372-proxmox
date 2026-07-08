#!/usr/bin/env bash
# =============================================================================
#  e3372-proxmox — one-shot driver/setup for Huawei E3372 HiLink modems
#  on Proxmox VE / Debian.
#
#  Все зависимости вшиты в репозиторий (deb/, локальный apt-репо, trixie/amd64) —
#  ставятся офлайн, без обращения к внешним apt-зеркалам.
#
#  Что делает:
#    1. ставит usb-modeswitch(+data) и networkd-dispatcher из вшитого репо
#    2. поднимает интерфейсы модемов по DHCP (systemd-networkd, матч по драйверу)
#    3. loose rp_filter
#    4. per-modem policy routing через networkd-dispatcher (авто на boot/hotplug)
#    5. защита от коллизии подсети модема с сетью хоста (авто-skip)
#    6. ставит диагностику e3372-check
#
#  Одна команда:
#    bash <(curl -fsSL https://raw.githubusercontent.com/Tovarish666/e3372-proxmox/main/install.sh)
#  Идемпотентно, root, Debian 13 (trixie) / Proxmox VE 9, amd64.
# =============================================================================
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/Tovarish666/e3372-proxmox/main"
CACHE=/var/cache/e3372
DEBDIR="$CACHE/deb"
NETDIR=/etc/systemd/network
HOOK=/etc/networkd-dispatcher/routable.d/50-e3372
CHECK=/usr/local/bin/e3372-check

c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_r=$'\033[1;31m'; c_0=$'\033[0m'
log(){  printf '%s[e3372]%s %s\n' "$c_g" "$c_0" "$*"; }
warn(){ printf '%s[e3372]%s %s\n' "$c_y" "$c_0" "$*"; }
die(){  printf '%s[e3372] %s%s\n' "$c_r" "$*" "$c_0" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "нужен root"
command -v apt-get >/dev/null 2>&1 || die "нужен apt (Debian/Proxmox)"
command -v curl    >/dev/null 2>&1 || die "нужен curl"

# ---------------------------------------------------------------------------
log "1/6 качаю вшитый apt-репо зависимостей из GitHub…"
rm -rf "$DEBDIR"; mkdir -p "$DEBDIR"
for meta in Packages Packages.gz Release manifest.txt; do
  curl -fsSL "$REPO_RAW/deb/$meta" -o "$DEBDIR/$meta" || die "нет deb/$meta в репо"
done
n=0
while read -r f; do
  [ -n "$f" ] || continue
  curl -fsSL "$REPO_RAW/deb/$f" -o "$DEBDIR/$f" || die "не скачал deb/$f"
  n=$((n+1))
done < "$DEBDIR/manifest.txt"
log "скачано $n пакетов ($(du -sh "$DEBDIR" | cut -f1))"

# ---------------------------------------------------------------------------
log "2/6 ставлю зависимости офлайн из локального репо…"
echo "deb [trusted=yes] file:$DEBDIR ./" > "$CACHE/e3372.list"
APT=(apt-get
  -o Dir::Etc::SourceList="$CACHE/e3372.list"
  -o Dir::Etc::SourceParts=/dev/null
  -o APT::Get::List-Cleanup=0
  -o Acquire::AllowInsecureRepositories=true)
"${APT[@]}" update >/dev/null 2>&1 || warn "apt update (local) с предупреждениями"
"${APT[@]}" install -y --no-download --no-install-recommends --allow-unauthenticated \
    usb-modeswitch usb-modeswitch-data networkd-dispatcher \
  || die "установка из локального репо не удалась (см. вывод выше)"
modprobe -a cdc_ether rndis_host cdc_ncm huawei_cdc_ncm 2>/dev/null || true

# ---------------------------------------------------------------------------
log "3/6 systemd-networkd: подъём HiLink-интерфейсов по DHCP…"
install -d "$NETDIR"
cat > "$NETDIR/25-hilink.network" <<'NET'
# Матч ТОЛЬКО модемов по драйверу (physical NIC/vmbr не трогаем).
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
log "4/6 sysctl: loose reverse-path filter…"
cat > /etc/sysctl.d/99-e3372.conf <<'SYS'
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
SYS
sysctl -q --system >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
log "5/6 policy-routing hook (networkd-dispatcher, авто на boot/hotplug)…"
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
# коллизия: если 192.168.<N>.x занята другим (не этим) интерфейсом (LAN хоста) — пропускаем
if ip -4 -o addr show | awk -v pat="192.168.$N." -v me="$IFACE" \
     '$2!=me && index($4,pat)==1 {f=1} END{exit !f}'; then
  logger -t e3372 "skip N=$N ($IFACE): подсеть занята хостом"; exit 0
fi
ip route replace 192.168.$N.0/24 dev "$IFACE" src "$IP" table "$N"
ip route replace default via 192.168.$N.1 dev "$IFACE" table "$N"
ip rule show | grep -q "from $IP " || ip rule add from "$IP/32" table "$N" priority $((1000+N))
logger -t e3372 "up: $IFACE $IP -> table $N (gw 192.168.$N.1)"
HOOK
chmod +x "$HOOK"

# ---------------------------------------------------------------------------
log "6/6 сервисы + применяю к уже поднятым модемам…"
systemctl enable --now systemd-networkd    >/dev/null 2>&1 || true
systemctl enable --now networkd-dispatcher >/dev/null 2>&1 || true
systemctl restart systemd-networkd
sleep 2
applied=0
while read -r IFACE _; do
  [ -n "$IFACE" ] || continue
  IFACE="$IFACE" bash "$HOOK" && applied=$((applied+1)) || true
done < <(ip -4 -o addr show | awk '/192\.168\.[0-9]+\.100\//{print $2, $4}')
log "policy-routing применён к $applied модемам"

# диагностика
cat > "$CHECK" <<'CHK'
#!/bin/bash
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
log "готово (зависимости — из вшитого репо, без внешних зеркал). проверка:  e3372-check"
echo
"$CHECK" 2>/dev/null || true
