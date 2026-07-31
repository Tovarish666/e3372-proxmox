#!/usr/bin/env bash
# =============================================================================
#  e3372-driver — установка.
#
#    bash <(curl -fsSL https://raw.githubusercontent.com/Tovarish666/e3372-proxmox/main/install.sh)
#  либо из клона репозитория:
#    git clone … && cd e3372-proxmox && sudo bash install.sh
#
#  Идемпотентно. Root. Debian 12/13, Proxmox VE 8/9, amd64.
# =============================================================================
set -uo pipefail

REPO_RAW="https://raw.githubusercontent.com/Tovarish666/e3372-proxmox/main"
TAR_URLS=(
  "https://codeload.github.com/Tovarish666/e3372-proxmox/tar.gz/refs/heads/main"
  "https://github.com/Tovarish666/e3372-proxmox/archive/refs/heads/main.tar.gz"
)

PREFIX_LIB=/usr/local/lib/e3372
PREFIX_SBIN=/usr/local/sbin
PREFIX_BIN=/usr/local/bin
CONFDIR=/etc/e3372

c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_r=$'\033[1;31m'; c_0=$'\033[0m'
log()  { printf '%s[e3372]%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s[e3372]%s %s\n' "$c_y" "$c_0" "$*"; }
die()  { printf '%s[e3372] %s%s\n' "$c_r" "$*" "$c_0" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "нужен root"
command -v systemctl >/dev/null 2>&1 || die "нужен systemd"
[ -d /etc/systemd/network ] || mkdir -p /etc/systemd/network

# ---------------------------------------------------------------------------
# 1. Исходники: локальный клон или архив с GitHub
# ---------------------------------------------------------------------------
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd) || SELF_DIR=""
SRC=""
if [ -n "$SELF_DIR" ] && [ -r "$SELF_DIR/lib/common.sh" ]; then
    SRC="$SELF_DIR"
    log "1/7 ставлю из локального дерева: $SRC"
else
    command -v curl >/dev/null 2>&1 || die "нужен curl (apt install curl)"
    log "1/7 качаю репозиторий с GitHub…"
    WORK=$(mktemp -d) || die "нет /tmp"
    trap 'rm -rf "$WORK"' EXIT
    ok=0
    for url in "${TAR_URLS[@]}"; do
        echo "      → $url"
        curl -fL --retry 5 --retry-delay 2 --retry-connrefused \
             --connect-timeout 30 --max-time 900 -o "$WORK/repo.tgz" "$url" && { ok=1; break; }
        warn "не вышло, пробую следующее зеркало…"
    done
    [ "$ok" = 1 ] || die "не скачал архив (нет связи с github.com)"
    tar -xzf "$WORK/repo.tgz" -C "$WORK" || die "битый архив"
    SRC=$(find "$WORK" -maxdepth 1 -type d -name 'e3372-*' | head -1)
    [ -r "$SRC/lib/common.sh" ] || die "в архиве нет lib/common.sh — неожиданно"
fi

# ---------------------------------------------------------------------------
# 2. Зависимости. Вшитый offline-репо, если он есть в дереве; иначе apt.
#    Ни одна из них не критична для запуска: без usb_modeswitch не работает
#    только Zero-CD, без curl — только web-API. Драйвер стартует в любом случае.
# ---------------------------------------------------------------------------
log "2/7 зависимости…"
NEED=""
for p in usb-modeswitch usb-modeswitch-data curl ethtool usbutils; do
    case "$p" in
        curl)     command -v curl     >/dev/null 2>&1 && continue ;;
        ethtool)  command -v ethtool  >/dev/null 2>&1 && continue ;;
        usbutils) command -v lsusb    >/dev/null 2>&1 && continue ;;
        usb-modeswitch) command -v usb_modeswitch >/dev/null 2>&1 && continue ;;
        usb-modeswitch-data) [ -d /usr/share/usb_modeswitch ] && continue ;;
    esac
    NEED="$NEED $p"
done

if [ -n "${NEED// /}" ]; then
    DEBDIR="$SRC/deb"
    if [ -s "$DEBDIR/Release" ]; then
        log "    ставлю офлайн из вшитого репо:$NEED"
        LIST=$(mktemp)
        echo "deb [trusted=yes] file:$DEBDIR ./" > "$LIST"
        APT=(apt-get -o Dir::Etc::SourceList="$LIST" -o Dir::Etc::SourceParts=/dev/null
             -o APT::Get::List-Cleanup=0 -o Acquire::AllowInsecureRepositories=true)
        "${APT[@]}" update >/dev/null 2>&1
        files=()
        while read -r pkg; do
            [ -n "$pkg" ] || continue
            fp=$(ls "$DEBDIR/${pkg}_"*.deb 2>/dev/null | head -1)
            [ -n "$fp" ] && files+=("$fp")
        done < <("${APT[@]}" install -s --no-install-recommends $NEED 2>/dev/null | awk '/^Inst /{print $2}')
        if [ "${#files[@]}" -gt 0 ]; then
            dpkg -i "${files[@]}" >/dev/null 2>&1 || dpkg -i "${files[@]}" >/dev/null 2>&1 || true
        fi
        rm -f "$LIST"
    else
        log "    ставлю через apt:$NEED"
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $NEED >/dev/null 2>&1 \
            || warn "apt не смог поставить часть пакетов — продолжаю, функциональность урезана"
    fi
fi
for c in usb_modeswitch curl ethtool; do
    command -v "$c" >/dev/null 2>&1 || warn "$c отсутствует — соответствующая часть драйвера отключится сама"
done

modprobe -a cdc_ether rndis_host cdc_ncm huawei_cdc_ncm >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 3. Файлы
# ---------------------------------------------------------------------------
log "3/7 раскладываю файлы…"
install -d "$PREFIX_LIB" "$PREFIX_SBIN" "$PREFIX_BIN" "$CONFDIR" \
           /etc/usb_modeswitch.d /etc/systemd/network /etc/udev/rules.d /etc/sysctl.d \
           /var/lib/e3372
install -m 0644 "$SRC/lib/common.sh"                  "$PREFIX_LIB/common.sh"
install -m 0755 "$SRC/sbin/e3372-reconcile"           "$PREFIX_SBIN/e3372-reconcile"
install -m 0755 "$SRC/bin/e3372-status"               "$PREFIX_BIN/e3372-status"
install -m 0755 "$SRC/bin/e3372-ctl"                  "$PREFIX_BIN/e3372-ctl"
install -m 0755 "$SRC/bin/e3372-doctor"               "$PREFIX_BIN/e3372-doctor"
install -m 0644 "$SRC/systemd/25-e3372.network"       /etc/systemd/network/25-e3372.network
install -m 0644 "$SRC/systemd/e3372-reconcile.service" /etc/systemd/system/e3372-reconcile.service
install -m 0644 "$SRC/systemd/e3372-reconcile.timer"   /etc/systemd/system/e3372-reconcile.timer
install -m 0644 "$SRC/udev/70-e3372.rules"            /etc/udev/rules.d/70-e3372.rules
install -m 0644 "$SRC/udev/71-e3372-ports.rules"      /etc/udev/rules.d/71-e3372-ports.rules
install -m 0644 "$SRC/sysctl/99-e3372.conf"           /etc/sysctl.d/99-e3372.conf
# конфиг пользователя не перезаписываем никогда
if [ ! -f "$CONFDIR/e3372.conf" ]; then
    install -m 0644 "$SRC/etc/e3372.conf" "$CONFDIR/e3372.conf"
else
    install -m 0644 "$SRC/etc/e3372.conf" "$CONFDIR/e3372.conf.new"
    warn "конфиг сохранён: свой оставлен, новый рядом как e3372.conf.new"
fi

# --- прежняя версия репозитория: снять то, что больше не используется --------
for old in /etc/networkd-dispatcher/routable.d/50-e3372 \
           /usr/local/sbin/e3372-watchdog.sh \
           /etc/systemd/network/25-hilink.network \
           /etc/systemd/system/e3372-watchdog.service \
           /etc/systemd/system/e3372-watchdog.timer; do
    [ -e "$old" ] || continue
    systemctl disable --now e3372-watchdog.timer >/dev/null 2>&1 || true
    rm -f "$old"
    warn "убран артефакт прошлой версии: $old"
done

# ---------------------------------------------------------------------------
# 4. usb_modeswitch: Zero-CD PID по FcSwitch.inf
# ---------------------------------------------------------------------------
log "4/7 usb_modeswitch: Zero-CD PID (вкл. ветку Vodafone K5150/K5160)…"
# 14fe/1505/155a/1c0b ставили прошлые версии — это switcher-serial PID
# (ew_hwusbdev.inf), а не mass storage. Конфиг для них бесполезен, убираем.
for stale in 14fe 1505 155a 1c0b; do
    cfg="/etc/usb_modeswitch.d/12d1:$stale"
    if [ -f "$cfg.e3372.bak" ]; then mv -f "$cfg.e3372.bak" "$cfg"
    elif [ -f "$cfg" ] && grep -q '^HuaweiNewMode=1' "$cfg" 2>/dev/null; then rm -f "$cfg"; fi
done
for pid in 1f01 1f02 1f10 1f11 1f12 1f13 1f14 1440; do
    cfg="/etc/usb_modeswitch.d/12d1:$pid"
    [ -f "$cfg" ] && [ ! -f "$cfg.e3372.bak" ] && cp -a "$cfg" "$cfg.e3372.bak"
    install -m 0644 "$SRC/modeswitch/zerocd.conf" "$cfg"
done

# ---------------------------------------------------------------------------
# 5. sysctl
# ---------------------------------------------------------------------------
log "5/7 sysctl…"
sysctl -q --system >/dev/null 2>&1 || warn "sysctl --system с предупреждениями"

# ---------------------------------------------------------------------------
# 6. Сервисы. Снимок resolv.conf до перезапуска networkd — если модемы его
#    обнулят, хост ослепнет, а мы это заметим только по симптомам.
# ---------------------------------------------------------------------------
log "6/7 сервисы…"
RESOLV_BAK=$(mktemp); cp -a /etc/resolv.conf "$RESOLV_BAK" 2>/dev/null || true

udevadm control --reload >/dev/null 2>&1 || true
udevadm trigger --subsystem-match=usb --attr-match=idVendor=12d1 >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable --now systemd-networkd >/dev/null 2>&1 || true
systemctl restart systemd-networkd >/dev/null 2>&1 || true
systemctl enable --now e3372-reconcile.timer >/dev/null 2>&1 \
    || die "не удалось включить e3372-reconcile.timer"

sleep 2
if [ ! -L /etc/resolv.conf ] && ! grep -q '^nameserver' /etc/resolv.conf 2>/dev/null; then
    warn "resolv.conf остался без nameserver — восстанавливаю"
    if grep -q '^nameserver' "$RESOLV_BAK" 2>/dev/null; then cp -a "$RESOLV_BAK" /etc/resolv.conf
    else printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf; fi
fi
rm -f "$RESOLV_BAK"

# ---------------------------------------------------------------------------
# 7. Первый проход
# ---------------------------------------------------------------------------
log "7/7 первый проход драйвера…"
"$PREFIX_SBIN/e3372-reconcile" || true

echo
log "готово. Драйвер работает сам: udev-триггер + таймер каждые 15с."
echo "   состояние:   e3372-status"
echo "   диагностика: e3372-doctor"
echo "   вручную:     e3372-ctl run | dataon --all | reset N | recfg --all"
echo "   журнал:      journalctl -t e3372 -f"
echo
warn "парк из десятков модемов сходится не мгновенно: Zero-CD, перебор"
warn "USB-конфигураций и дозвон занимают несколько циклов. Смотрите e3372-status"
warn "через 2-3 минуты после включения, а не сразу."
