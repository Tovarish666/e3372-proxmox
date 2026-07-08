#!/usr/bin/env bash
# Откат e3372-proxmox: убирает конфиги, сервисы, правила и таблицы маршрутов.
# Ничего не устанавливалось из пакетов — удалять нечего.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "нужен root" >&2; exit 1; }

echo "[e3372] останавливаю таймер/сервис…"
systemctl disable --now e3372-route.timer   >/dev/null 2>&1 || true
systemctl disable --now e3372-route.service >/dev/null 2>&1 || true

echo "[e3372] удаляю файлы…"
rm -f /etc/systemd/system/e3372-route.service \
      /etc/systemd/system/e3372-route.timer \
      /usr/local/sbin/e3372-route.sh \
      /etc/systemd/network/25-hilink.network \
      /etc/sysctl.d/99-e3372.conf \
      /etc/udev/rules.d/72-e3372.rules \
      /etc/networkd-dispatcher/routable.d/50-e3372 \
      /usr/local/bin/e3372-check
systemctl daemon-reload
udevadm control --reload 2>/dev/null || true

echo "[e3372] снимаю ip rule / таблицы модемов…"
while read -r IP; do
  N=$(printf '%s' "$IP" | cut -d. -f3)
  ip rule del from "$IP/32" table "$N" 2>/dev/null || true
  ip route flush table "$N" 2>/dev/null || true
done < <(ip rule show | grep -oP '(?<=from )192\.168\.[0-9]+\.100')

systemctl restart systemd-networkd 2>/dev/null || true
sysctl -q -w net.ipv4.conf.all.rp_filter=1 2>/dev/null || true
echo "[e3372] готово. Интерфейсы модемов останутся, но без маршрутов."
