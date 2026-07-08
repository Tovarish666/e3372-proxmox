#!/usr/bin/env bash
# Откат e3372-proxmox: конфиги, hook, правила, таблицы.
#   PURGE_PKGS=1 — также удалить установленные пакеты (usb-modeswitch, networkd-dispatcher).
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "нужен root" >&2; exit 1; }

echo "[e3372] удаляю конфиги/hook…"
rm -f /etc/systemd/network/25-hilink.network \
      /etc/sysctl.d/99-e3372.conf \
      /etc/networkd-dispatcher/routable.d/50-e3372 \
      /usr/local/bin/e3372-check
rm -rf /var/cache/e3372

echo "[e3372] снимаю ip rule / таблицы модемов…"
while read -r IP; do
  N=$(printf '%s' "$IP" | cut -d. -f3)
  ip rule del from "$IP/32" table "$N" 2>/dev/null || true
  ip route flush table "$N" 2>/dev/null || true
done < <(ip rule show | grep -oP '(?<=from )192\.168\.[0-9]+\.100')

systemctl restart systemd-networkd 2>/dev/null || true
sysctl -q -w net.ipv4.conf.all.rp_filter=1 2>/dev/null || true

if [ "${PURGE_PKGS:-0}" = "1" ]; then
  echo "[e3372] удаляю пакеты…"
  apt-get remove -y usb-modeswitch usb-modeswitch-data networkd-dispatcher >/dev/null 2>&1 || true
fi
echo "[e3372] готово. Интерфейсы модемов останутся, но без маршрутов."
