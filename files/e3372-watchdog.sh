#!/bin/bash
# e3372 watchdog: routing reconcile + modem health + DNS safety-net.
# Не трогает default route/DNS хоста (кроме пустого resolv.conf-файла).
DRIVERS='cdc_ether|rndis_host|cdc_ncm|huawei_cdc_ncm'
ip -4 -o addr show | awk '/192\.168\.[0-9]+\.100\//{print $2,$4}' | while read -r IFACE CIDR; do
  IP=${CIDR%/*}; N=$(printf '%s' "$IP"|cut -d. -f3)
  ip -4 -o addr show | awk -v pat="192.168.$N." -v me="$IFACE" \
    '$2!=me && index($4,pat)==1{f=1}END{exit !f}' && { logger -t e3372-wd "skip N=$N: коллизия"; continue; }
  ip route replace 192.168.$N.0/24 dev "$IFACE" src "$IP" table "$N"
  ip route replace default via 192.168.$N.1 dev "$IFACE" table "$N"
  ip rule show | grep -q "from $IP " || ip rule add from "$IP/32" table "$N" priority $((1000+N))
done
for L in $(ip -o link show up | awk -F': ' '{print $2}' | sed 's/@.*//'); do
  drv=$(ethtool -i "$L" 2>/dev/null | awk '/^driver:/{print $2}')
  printf '%s' "$drv" | grep -qE "^($DRIVERS)$" || continue
  ip -4 -o addr show dev "$L" | grep -q 'inet ' && continue
  logger -t e3372-wd "iface $L без IP — reconfigure"; networkctl reconfigure "$L" 2>/dev/null || true
done
if [ ! -L /etc/resolv.conf ] && ! grep -q '^nameserver' /etc/resolv.conf 2>/dev/null; then
  logger -t e3372-wd "resolv.conf пуст — фолбэк 1.1.1.1/8.8.8.8"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
fi
