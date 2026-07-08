#!/bin/bash
# per-modem policy routing reconciler (idempotent, no external deps)
sysctl -q -w net.ipv4.conf.all.rp_filter=2 2>/dev/null || true
ip -4 -o addr show | awk '/192\.168\.[0-9]+\.100\//{print $2, $4}' | while read -r IFACE CIDR; do
  IP=${CIDR%/*}; N=$(printf '%s' "$IP" | cut -d. -f3)
  if ip -4 -o addr show | awk -v pat="192.168.$N." -v me="$IFACE" \
       '$2!=me && index($4,pat)==1 {f=1} END{exit !f}'; then
    logger -t e3372 "skip N=$N ($IFACE): подсеть занята хостом"; continue
  fi
  ip route replace 192.168.$N.0/24 dev "$IFACE" src "$IP" table "$N"
  ip route replace default via 192.168.$N.1 dev "$IFACE" table "$N"
  ip rule show | grep -q "from $IP " || ip rule add from "$IP/32" table "$N" priority $((1000+N))
done
