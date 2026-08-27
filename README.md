# podkop-guard

[English](README.en.md)

Небольшой helper для OpenWrt, который сохраняет для [Podkop](https://github.com/itdoginfo/podkop) проверенное **Last Known Good (LKG)** состояние Community Lists и помогает пережить неудачный холодный старт, когда GitHub/`raw.githubusercontent.com` недоступен.

Проект появился из реального сбоя: после проблем с доступом к GitHub Podkop не смог получить часть списков, нужные IP-подсети не попали в `PodkopTable/podkop_subnets`, а после потери `/tmp` sing-box мог остаться без remote SRS cache. В результате часть доменно-маршрутизируемых сервисов продолжала работать, а нативные приложения, подключающиеся напрямую к IP, ломались.

`podkop-guard` не заменяет Podkop и не вмешивается в его обычную логику. Он держит рядом проверенную страховочную копию и обновляет её только после полного набора проверок.

Это независимый проект, он не является частью Podkop и не связан с его разработчиками.

## Статус

Текущая версия: **0.2.2**.

Полный pipeline проверен на реальном **Cudy TR3000 v1 / OpenWrt 24.10.5 / Podkop 0.7.21 / sing-box 1.12.22**:

- `refresh-test` успешно обработал все 14 используемых Community Lists;
- compile/decompile round-trip объединённого LKG прошёл без расхождений;
- получен Local Subnet LKG из 1161 безусловного CIDR; 8 conditional CIDR корректно пропущены;
- offline cold-start cache test прошёл с намеренно недоступным download path;
- `refresh-test` занял около 15 секунд и не изменил SHA-256 persistent LKG-файлов;
- выполнен настоящий reboot OpenWrt: `podkop-guard` на `START=98` восстановил cache до запуска Podkop на `START=99`;
- после reboot sing-box runtime поднялся, LKG-подсети загрузились в nftables, проверенные сервисы продолжили работать;
- `status` и `refresh-test` проверены через LuCI `Custom Commands`; в v0.2.2 исправлена совместимость `verify-lkg`/`derive-subnets` с BusyBox `mktemp`.

Это подтверждение конкретной протестированной конфигурации, а не гарантия совместимости со всеми версиями OpenWrt, Podkop и sing-box.

## Что делает

У проекта две независимые функции.

### 1. Восстановление после reboot/power loss

Обычный sing-box cache у Podkop лежит в:

```text
/tmp/sing-box/cache.db
```

`/tmp` пропадает после перезагрузки. `podkop-guard` хранит проверенную копию на flash:

```text
/etc/podkop-guard/cache.db
```

Init-сервис запускается с `START=98`, то есть непосредственно перед Podkop 0.7.21 (`START=99`), и восстанавливает cache в `/tmp` до запуска Podkop.

Если sing-box уже работает, boot-restore ничего не перезаписывает.

### 2. Периодическое безопасное обновление LKG

После загрузки тот же сервис запускает очень лёгкий procd-worker:

- startup grace: 300 секунд;
- проверка состояния: раз в 1 час;
- успешное обновление LKG: не чаще раза в 24 часа;
- при неудаче старый LKG остаётся нетронутым, следующая попытка — через час.

Большую часть времени worker просто спит. Более тяжёлые `jq`/`sing-box` операции выполняются через `nice -n 10`.

## Что хранится

```text
/etc/podkop-guard/lkg.srs
/etc/podkop-guard/lkg-subnets.lst
/etc/podkop-guard/cache.db
```

- `lkg.srs` — объединённый проверенный binary SRS из текущих `podkop.main.community_lists`;
- `lkg-subnets.lst` — обычный Podkop Local Subnet List только с безусловными `ip_cidr`;
- `cache.db` — проверенный sing-box remote rule-set cache для холодного старта.

`cache.db` также используется как маркер времени последнего полностью успешного refresh: отдельный timestamp-файл не нужен. Возраст snapshot определяется штатным BusyBox `date -r FILE +%s`, поэтому отдельный `stat`/coreutils не требуется.

## Как обновляется LKG

При refresh `podkop-guard` читает текущий список:

```text
podkop.main.community_lists
```

И для каждого Community List скачивает SRS из GitHub Releases:

```text
https://github.com/itdoginfo/allow-domains/releases/latest/download/<list>.srs
```

Сначала выполняется обычный `curl` с жёсткими timeout. Если он не прошёл и секция `main` работает в VPN-режиме, выполняется одна повторная попытка через текущий `podkop.main.interface` с `curl --interface`. Для совместимости с вариантами UCI-схемы проверяются как `podkop.main.connection_type`, так и `podkop.main.type`.

Если хотя бы один обязательный SRS получить не удалось, refresh немедленно прекращается. Частичный snapshot никогда не принимается.

## Проверки перед заменой LKG

Новый snapshot должен пройти все этапы:

```text
скачаны ВСЕ текущие Community SRS
        ↓
каждый SRS успешно decompile'ится установленным sing-box
        ↓
все правила объединяются
        ↓
compile → candidate lkg.srs → decompile
        ↓
canonical JSON до/после совпадает байт-в-байт
        ↓
строится candidate lkg-subnets.lst
        ↓
копируется candidate cache.db из работающего sing-box
        ↓
offline cold-start test с намеренно мёртвым download path
        ↓
только после полного успеха — запись на flash
```

Для cache test создаётся отдельный тестовый sing-box. Все текущие Community rule-set помечаются как remote, но их download detour направляется в заведомо мёртвый SOCKS `127.0.0.1:9`.

Если cache содержит всё необходимое, тестовый sing-box стартует. Если хотя бы одного обязательного remote SRS в cache нет, тест падает и persistent LKG не заменяется.

Тестовый процесс живёт только до появления `sing-box started` и обычно завершается примерно через секунду; максимальный timeout — 10 секунд.

## Conditional CIDR

Обычный Local Subnet List Podkop умеет хранить только IP/CIDR и не может сохранить условия вроде `network` или `port_range`.

Поэтому `podkop-guard` экспортирует в `lkg-subnets.lst` только `ip_cidr` из правил, у которых нет дополнительных условий. Conditional CIDR пропускаются с warning, а не превращаются молча в более широкий маршрут.

Это важно, например, для текущего `discord.srs`.

## Почему не используется live cache на flash

Podkop/sing-box продолжает работать со штатным cache в `/tmp`. На flash сохраняется только периодический проверенный snapshot.

Так нет постоянных записей FakeIP/cache на flash и нет необходимости менять штатную конфигурацию sing-box.

## Требования

Проверено на:

- Cudy TR3000 v1;
- OpenWrt 24.10.5;
- Podkop 0.7.21;
- sing-box 1.12.22.

Нужны:

- Podkop;
- sing-box;
- `curl`;
- `jq`;
- стандартные BusyBox-утилиты, включая `nice`, `date` с поддержкой `-r`, `sort`, `cmp`, `logger`, `mktemp`.

Отдельная утилита `stat` не требуется.

Установщик рассчитан на OpenWrt с `opkg`.

## Установка

Через `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/SVTagan/podkop-guard/main/install.sh \
  -o /tmp/podkop-guard-install.sh && \
sh /tmp/podkop-guard-install.sh
```

Или через `uclient-fetch`:

```sh
uclient-fetch -q -O /tmp/podkop-guard-install.sh \
  https://raw.githubusercontent.com/SVTagan/podkop-guard/main/install.sh && \
sh /tmp/podkop-guard-install.sh
```

На первой установке сервис специально остаётся **STOPPED + DISABLED**. Сначала нужно построить и проверить LKG.

## Первая настройка

Убедитесь, что Podkop и sing-box сейчас нормально работают, затем:

```sh
podkop-guard refresh-test
```

Это выполняет полный download/compile/cache cold-start test, но ничего не меняет в `/etc/podkop-guard`.

Если тест прошёл:

```sh
podkop-guard refresh
```

После этого должен существовать:

```text
/etc/podkop-guard/lkg-subnets.lst
```

Один раз подключите его к секции `main` как обычный Local Subnet List:

```sh
if ! uci -q get podkop.main.local_subnet_lists 2>/dev/null \
  | tr ' ' '\n' \
  | grep -Fxq '/etc/podkop-guard/lkg-subnets.lst'; then
    cp -p /etc/config/podkop /etc/config/podkop.pre-podkop-guard
    uci add_list podkop.main.local_subnet_lists='/etc/podkop-guard/lkg-subnets.lst'
    uci commit podkop
fi
```

Затем один раз штатно reload Podkop:

```sh
/etc/init.d/podkop reload
```

Проверьте нужные сервисы и только после этого включайте guard:

```sh
/etc/init.d/podkop-guard enable
/etc/init.d/podkop-guard start
```

Запуск guard на уже работающей системе не перезапишет live cache: boot-restore увидит работающий sing-box и будет пропущен, а procd-worker начнёт обычный 300-секундный grace period.

## CLI

```text
podkop-guard status
podkop-guard verify-lkg
podkop-guard derive-subnets
podkop-guard refresh-test
podkop-guard refresh
podkop-guard cache-restore
podkop-guard boot-restore
podkop-guard version
```

`daemon` предназначен для procd и вручную обычно не нужен.

## LuCI Custom Commands (необязательно)

Если установлен `luci-app-commands`, можно добавить четыре безопасных кнопки для повседневной проверки:

```sh
uci set luci.podkop_guard_status='command'
uci set luci.podkop_guard_status.name='Podkop Guard: Status'
uci set luci.podkop_guard_status.command='/usr/bin/podkop-guard status'
uci set luci.podkop_guard_status.param='0'
uci set luci.podkop_guard_status.public='0'

uci set luci.podkop_guard_verify='command'
uci set luci.podkop_guard_verify.name='Podkop Guard: Verify LKG'
uci set luci.podkop_guard_verify.command='/usr/bin/podkop-guard verify-lkg'
uci set luci.podkop_guard_verify.param='0'
uci set luci.podkop_guard_verify.public='0'

uci set luci.podkop_guard_test='command'
uci set luci.podkop_guard_test.name='Podkop Guard: Refresh Test'
uci set luci.podkop_guard_test.command='/usr/bin/podkop-guard refresh-test'
uci set luci.podkop_guard_test.param='0'
uci set luci.podkop_guard_test.public='0'

uci set luci.podkop_guard_refresh='command'
uci set luci.podkop_guard_refresh.name='Podkop Guard: Refresh LKG'
uci set luci.podkop_guard_refresh.command='/usr/bin/podkop-guard refresh'
uci set luci.podkop_guard_refresh.param='0'
uci set luci.podkop_guard_refresh.public='0'

uci commit luci
```

`Refresh Test` выполняет полный pipeline без записи persistent LKG. `Refresh LKG` после успешной валидации действительно обновляет persistent snapshot. `param=0` запрещает произвольные дополнительные аргументы, `public=0` не разрешает запуск команды без авторизации в LuCI.

## Логи

Worker пишет события в системный log OpenWrt:

```sh
logread | grep podkop-guard
```

Отдельного постоянного лог-файла на flash нет.

## Нагрузка

В штатном режиме:

- один sleeping `ash`-процесс под procd;
- раз в час — дешёвая проверка возраста LKG;
- примерно раз в сутки — скачивание небольших SRS и несколько секунд валидации;
- тяжёлые операции имеют пониженный CPU priority (`nice -n 10`);
- запись на flash происходит только после полностью успешного refresh.

Если GitHub недоступен, используется один direct-запрос и максимум одна VPN-попытка на первый нескачавшийся обязательный файл; затем worker спит ещё час.

## Что podkop-guard намеренно НЕ делает

- не патчит Podkop;
- не меняет `community_lists`;
- не включает `download_lists_via_proxy`;
- не переключает VPN;
- не делает reload/restart Podkop во время refresh;
- не использует cron;
- не создаёт NORMAL/FALLBACK режимов;
- не держит live sing-box cache на flash;
- не поднимает локальный HTTP-сервер.

Podkop продолжает полностью владеть обычной маршрутизацией и штатным обновлением списков.

## Ограничения

Текущая реализация ориентирована на `podkop.main.community_lists`.

Если набор Community Lists изменён, пока текущему LKG меньше 24 часов, лучше выполнить `podkop-guard refresh` вручную, а не ждать следующего планового refresh.

VPN fallback для скачивания применяется только когда секция `main` определяется как VPN и задан `podkop.main.interface`.

Порядок `START=98 → Podkop START=99` проверен для Podkop 0.7.21. После крупных обновлений Podkop порядок init-сервисов следует проверить заново.

Проект не пытается гарантировать работу при повреждённом persistent LKG или при несовместимых изменениях формата cache/rule-set в будущих версиях sing-box.

## История изменений

См. [CHANGELOG.md](CHANGELOG.md).

## Лицензия

MIT — см. [LICENSE](LICENSE).
