#!/usr/bin/env bash
# Откат e3372-proxmox: убирает конфиги, hook, правила и таблицы маршрутов.
# Пакеты (usb-modeswitch и т.п.) НЕ удаляет — они безобидны и могут быть нужны другим.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "нужен root" >&2; exit 1; }

echo "[e3372] удаляю файлы конфигурации…"
rm -f /etc/systemd/network/25-hilink.network \
      /etc/sysctl.d/99-e3372.conf \
      /etc/networkd-dispatcher/routable.d/50-e3372 \
      /usr/local/bin/e3372-check

echo "[e3372] снимаю ip rule / таблицы модемов…"
while read -r IP; do
  N=$(printf '%s' "$IP" | cut -d. -f3)
  ip rule del from "$IP/32" table "$N" 2>/dev/null || true
  ip route flush table "$N" 2>/dev/null || true
done < <(ip rule show | grep -oP '(?<=from )192\.168\.[0-9]+\.100')

echo "[e3372] restart systemd-networkd…"
systemctl restart systemd-networkd 2>/dev/null || true
sysctl -q -w net.ipv4.conf.all.rp_filter=1 2>/dev/null || true

echo "[e3372] готово. Интерфейсы модемов останутся, но без маршрутов."
