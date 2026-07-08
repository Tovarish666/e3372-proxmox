# e3372-proxmox

Драйвер-инсталлер для модемов **Huawei E3372 (HiLink)** на хосте **Proxmox VE / Debian**.
Одна команда — и пачка модемов поднимается, маршрутизируется и готова к работе.

**Все зависимости вшиты в репозиторий** (`deb/` — локальный apt-репо, Debian 13 trixie / amd64):
`usb-modeswitch`, `networkd-dispatcher` и весь их dependency-closure. Ставятся **офлайн из репо**,
без обращения к внешним apt-зеркалам — не ломается на дохлом `security.debian.org` и одинаково
работает на любом сервере.

Проверено на E3372**h-153**; подходит для **h-607, s-153, K5160** (Balong, HiLink).

## Установка (одной командой)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Tovarish666/e3372-proxmox/main/install.sh)
```

Идемпотентно, root, Debian 13 (trixie) / Proxmox VE 9, amd64.

## Что делает

| Шаг | Действие |
|-----|----------|
| 1 | Качает вшитый apt-репо (`deb/`) из GitHub |
| 2 | Ставит `usb-modeswitch(+data)` и `networkd-dispatcher` **офлайн** из локального репо (apt ставит только недостающее, установленное новее — не трогает) |
| 3 | Поднимает интерфейсы модемов по DHCP — **systemd-networkd** (матч по драйверу, не по имени/MAC: у всех E3372 одинаковый MAC) |
| 4 | Loose `rp_filter` |
| 5 | **Per-modem policy routing** через networkd-dispatcher hook — авто на boot и hotplug |
| 6 | Ставит диагностику `e3372-check` |

## Как вшиты зависимости

`deb/` — это самодостаточный flat apt-репозиторий: 66 .deb (trixie/amd64) + `Packages`/`Packages.gz`/`Release`.
Инсталлер поднимает его как `deb [trusted=yes] file:...` и ставит через apt **без сети**. Пакеты уже
установленные (более новой версии) apt не переустанавливает и не даунгрейдит — берёт из репо только
реально отсутствующее (`networkd-dispatcher`, `python3-gi`, `libjim0.83`, `usb-modeswitch` и т.п.).

> Обновить вендоренные пакеты: `python3 tools/regen-debs.py` (см. `tools/`), затем commit.
> Набор под **trixie/amd64**; для другой версии Debian/арх — перегенерировать.

## Модель адресации

```
модем N:  192.168.N.0/24    шлюз/web-API 192.168.N.1    хост получает 192.168.N.100
```

> ⚠️ **Коллизия подсетей.** Если подсеть модема совпадает с сетью хоста (напр. модем в
> `192.168.88.x`, а `vmbr0` тоже `192.168.88.0/24`) — маршруты для него **не создаются**
> (иначе пересекутся шлюзы и ARP). Такой модем авто-пропускается (`journalctl -t e3372`).

## Проверка

```bash
e3372-check
```
```
N    IFACE            HOST-IP          WEBUI  CONN      NET   EXIT-IP
81   eth17            192.168.81.100   ok     онлайн    19    100.x.x.x   <- сотовый IP = работает
...
```

- `WEBUI=ok` — модем жив (маршрутизация для этого не нужна, адрес on-link).
- `EXIT-IP` = сотовый адрес — трафик реально выходит через модем.
- `EXIT-IP=—` при `CONN=онлайн` → policy routing; при `CONN=offline/нет-сети` → APN/сигнал/SIM.

## Что ставится в систему

```
/etc/systemd/network/25-hilink.network          # DHCP на модемных интерфейсах
/etc/sysctl.d/99-e3372.conf                      # rp_filter=2
/etc/networkd-dispatcher/routable.d/50-e3372     # policy routing hook
/usr/local/bin/e3372-check                       # диагностика
/var/cache/e3372/                                # временный локальный apt-репо
```

## Удаление

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Tovarish666/e3372-proxmox/main/uninstall.sh)
# PURGE_PKGS=1 — снести и установленные пакеты
```

## Заметки

- systemd-networkd работает **параллельно** с ifupdown2 Proxmox: `.network` матчит только
  модемы по драйверу, `enp*`/`vmbr*` не трогает.
- Смена IP модема (реконнект) — задача панели [modlink-linux](https://github.com/Tovarish666/modlink-linux), не этого слоя.
