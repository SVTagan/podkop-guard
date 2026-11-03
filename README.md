# podkop-guard

[English](README.en.md)

Небольшой helper для OpenWrt, который сохраняет для [Podkop](https://github.com/itdoginfo/podkop) проверенное **Last Known Good (LKG)** состояние Community Lists и помогает пережить неудачный cold start, когда GitHub/`raw.githubusercontent.com` недоступен.

Проект появился после реального сбоя: Podkop не смог получить часть списков, нужные IP-подсети не попали в `PodkopTable/podkop_subnets`, а после потери `/tmp` sing-box мог остаться без remote rule-set cache. В результате часть доменно-маршрутизируемых сервисов продолжала работать, а приложения, подключающиеся напрямую к IP, ломались.

`podkop-guard` не заменяет и не патчит Podkop. Он хранит отдельно проверенную страховочную копию и обновляет её только после полного набора проверок.

Это независимый проект, он не является частью Podkop и не связан с его разработчиками.

## Статус

Текущая стабильная версия: **0.2.4**.

> В экспериментальной ветке `feature/watchdog-observe-only` доступны `podkop-guard watchdog-check` (однократная read-only диагностика) и `podkop-guard watchdog-monitor [циклы] [интервал_сек]` (ограниченный монитор с RAM-счётчиками, по умолчанию 6 проверок раз в 20 с). Результат `CONFIRMED` — несколько последовательных локальных наблюдений, а не подтверждение причины сбоя Интернета. Команды ничего не перезапускают и не отключают. Дополнительно подготовлен **непрерывный observe-only** режим `watchdog-observe` с независимым procd-инстансом, который **выключен по умолчанию** и требует явного `podkop_guard.settings.watchdog_enabled=1`. Он выводит записи только при смене состояния, хранит счётчики в RAM. Испытания opt-in procd на реальном устройстве ещё не проведены. Это не релиз v0.3.0. Для ручных проверок используйте файл ветки из `/tmp`, **не** запускайте установщик и не включайте procd-инстанс на рабочем роутере.

Проверенные реальные конфигурации:

| Устройство | OpenWrt | Podkop | sing-box | Community Lists | Проверено |
| --- | --- | --- | --- | ---: | --- |
| Cudy TR3000 v1 | 24.10.5 | 0.7.21 | 1.12.22 | 14 | полный `refresh-test`/`refresh`, Local Subnet LKG, offline cache validation, LuCI, reboot/cold start |
| Cudy TR3000 v1 | 24.10.4 | 0.7.22-r1 | 1.12.22-r1 | 14 | полный pipeline, VPN download fallback, исправление orphan-validator, два reboot |
| Xiaomi Redmi Router AX6000 (stock layout) | 24.10.5 | 0.7.21-r1 | 1.12.22-r1 | 21 | полный pipeline, cache restore, Local Subnet LKG, reboot и контролируемый WAN bounce |

Это подтверждение конкретных протестированных конфигураций, а не гарантия совместимости со всеми версиями OpenWrt, Podkop и sing-box. Содержимое upstream Community Lists меняется со временем, поэтому количество CIDR/SRS и размеры файлов не являются константами.

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

Init-сервис запускается с `START=98`, непосредственно перед Podkop (`START=99` на проверенных версиях), и восстанавливает cache в `/tmp` до запуска Podkop.

Если sing-box уже работает, boot restore ничего не перезаписывает.

### 2. Периодическое безопасное обновление LKG

После загрузки тот же сервис запускает лёгкий procd-worker:

- startup grace: 300 секунд;
- проверка состояния: раз в 1 час;
- успешное обновление LKG: не чаще раза в 24 часа;
- при неудаче старый LKG остаётся нетронутым, следующая попытка — через час.

Большую часть времени worker спит. Более тяжёлые `jq`/`sing-box` операции выполняются через `nice -n 10`.

## Что хранится

```text
/etc/podkop-guard/lkg.srs
/etc/podkop-guard/lkg-subnets.lst
/etc/podkop-guard/cache.db
```

- `lkg.srs` — объединённый проверенный binary SRS из текущих `podkop.main.community_lists`;
- `lkg-subnets.lst` — обычный Podkop Local Subnet List только с безусловными `ip_cidr`;
- `cache.db` — проверенный sing-box remote rule-set cache для cold start.

`cache.db` также используется как маркер времени последнего полностью успешного refresh. Возраст snapshot определяется штатным BusyBox `date -r FILE +%s`; отдельный timestamp-файл и `stat`/coreutils не нужны.

## Как обновляется LKG

При refresh `podkop-guard` читает текущий `podkop.main.community_lists` и для каждого Community List скачивает:

```text
https://github.com/itdoginfo/allow-domains/releases/latest/download/<list>.srs
```

Сначала выполняется обычный `curl` с жёсткими timeout. Если он не прошёл и секция `main` работает в VPN-режиме, выполняется одна повторная попытка через текущий `podkop.main.interface` с `curl --interface`. Для совместимости с вариантами UCI-схемы проверяются и `podkop.main.connection_type`, и `podkop.main.type`.

Если хотя бы один обязательный SRS получить не удалось, refresh немедленно прекращается. Частичный snapshot никогда не принимается.

Перед заменой persistent LKG должны пройти все этапы:

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

Для cache test создаётся отдельный тестовый sing-box. Все текущие Community rule-set помечаются как remote, а их download detour направляется в заведомо мёртвый SOCKS `127.0.0.1:9`. Persistent LKG заменяется только после успешного старта этого валидатора.

## Conditional CIDR

Обычный Local Subnet List Podkop умеет хранить только IP/CIDR и не может сохранить условия вроде `network` или `port_range`. Поэтому `podkop-guard` экспортирует только `ip_cidr` из правил без дополнительных условий. Conditional CIDR пропускаются с warning, а не превращаются молча в более широкий маршрут.

## Требования

Обязательные компоненты:

- Podkop;
- sing-box;
- `curl`;
- `jq`;
- OpenWrt с `opkg`;
- стандартные BusyBox-утилиты: `nice`, `date` с поддержкой `-r`, `sort`, `cmp`, `logger`, `mktemp`, `grep`, `tail`, `touch`, `sync`.

Если `curl` или `jq` отсутствуют, установщик пытается поставить их автоматически.

### LuCI

LuCI-интеграция является необязательной:

- если на роутере уже есть LuCI, установщик проверяет `luci-app-commands` и при необходимости пытается установить его;
- после этого создаются четыре именованные Custom Commands;
- ошибка установки `luci-app-commands` не ломает установку ядра guard;
- на headless OpenWrt LuCI-пакеты принудительно не устанавливаются;
- при удалении guard удаляются только его UCI-секции, сам `luci-app-commands` сохраняется.

## Установка

Для стабильной версии используйте installer из release tag. Он устанавливает worker/init из того же тега, поэтому установка воспроизводима и не зависит от будущих изменений `main`.

Через `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/SVTagan/podkop-guard/v0.2.4/install.sh \
  -o /tmp/podkop-guard-install.sh && \
sh /tmp/podkop-guard-install.sh
```

Или через `uclient-fetch`:

```sh
uclient-fetch -q -O /tmp/podkop-guard-install.sh \
  https://raw.githubusercontent.com/SVTagan/podkop-guard/v0.2.4/install.sh && \
sh /tmp/podkop-guard-install.sh
```

На первой установке сервис специально остаётся **STOPPED + DISABLED**. Сначала нужно построить и проверить LKG.

Для осознанного тестирования другой ветки/зеркала можно переопределить источник через `PODKOP_GUARD_BASE_URL`; обычным пользователям это не требуется.

## Первая настройка

Убедитесь, что Podkop и sing-box сейчас нормально работают, затем:

```sh
podkop-guard refresh-test
podkop-guard refresh
```

После этого один раз подключите созданный файл к секции `main` как обычный Local Subnet List:

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

## Обновление podkop-guard

Запуск installer более новой версии поверх существующей установки сохраняет persistent LKG и текущее состояние сервиса: если guard был включён/запущен, installer восстанавливает это состояние после замены worker/init.

После обновления полезно проверить:

```sh
podkop-guard version
podkop-guard status
podkop-guard verify-lkg
```

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

## LuCI Custom Commands

При обычной установке на роутер с LuCI автоматически создаются:

```text
Podkop Guard: Status       → /usr/bin/podkop-guard status
Podkop Guard: Verify LKG   → /usr/bin/podkop-guard verify-lkg
Podkop Guard: Refresh Test → /usr/bin/podkop-guard refresh-test
Podkop Guard: Refresh LKG  → /usr/bin/podkop-guard refresh
```

Секции имеют стабильные имена `podkop_guard_*`, повторная установка не создаёт дубликаты. Для всех команд задаются `param=0` и `public=0`; пользовательское `description`, если оно уже задано, сохраняется.

## Диагностика Podkop после cold start

Во время тестирования v0.2.4 на Redmi AX6000 встретилось состояние, которое **не показало повреждения LKG/cache guard**, но проявлялось после cold boot при включённом штатном мониторинге WAN-интерфейса Podkop.

Наблюдавшийся сценарий:

- `podkop.settings.enable_badwan_interface_monitoring='1'`;
- `podkop.settings.badwan_reload_delay='2000'`;
- после reboot Podkop и sing-box были запущены, Telegram CIDR присутствовали в `PodkopTable/podkop_subnets`, а persistent/runtime cache проходили проверки, но Telegram мог не работать;
- в одном неудачном состоянии sing-box логировал Telegram-соединения через `direct-out`; при отдельном reboot с увеличенной задержкой ранние попытки через правильный `main-out` показывали `network is unreachable`, пока `awg0` ещё не был готов;
- `podkop-guard refresh-test`, запущенный в сломанном состоянии, успешно прошёл offline cold-start validation текущего runtime cache;
- увеличение `badwan_reload_delay` до `20000` дало нормальный cold boot;
- после отключения `enable_badwan_interface_monitoring` cold boot также прошёл нормально;
- на этой конкретной конфигурации контролируемый `ifdown wan; sleep 10; ifup wan` восстановил и `wan`, и `awg0`, а Podkop продолжил работать без ручного reload.

Это наблюдение **не доказывает конкретную причину внутри Podkop**. Оно похоже по классу на открытый upstream issue [itdoginfo/podkop#360](https://github.com/itdoginfo/podkop/issues/360), где описана возможная гонка между ещё выполняющимся `podkop start` и `podkop reload`, вызванным событием `WAN up`. Мы не утверждаем, что наш случай на 100% является тем же дефектом.

Если после cold boot Podkop выглядит запущенным, но часть маршрутизируемых сервисов не работает, имеет смысл проверить:

```sh
uci -q get podkop.settings.enable_badwan_interface_monitoring
uci -q get podkop.settings.badwan_reload_delay
logread | grep -Ei 'podkop|sing-box' | tail -n 100
```

Практический вариант диагностики — сначала увеличить `badwan_reload_delay` и повторить тест. Отключать WAN monitoring стоит только если вы понимаете его назначение и отдельно проверили, что ваша конфигурация нормально переживает потерю/возврат WAN без этого trigger.

## Логи

```sh
logread | grep podkop-guard
```

Отдельного постоянного лог-файла на flash нет.

## Нагрузка

В штатном режиме:

- один sleeping `ash`-процесс под procd;
- раз в час — дешёвая проверка возраста LKG;
- примерно раз в сутки — скачивание SRS и несколько секунд валидации;
- тяжёлые операции имеют пониженный CPU priority (`nice -n 10`);
- запись на flash происходит только после полностью успешного refresh.

Если GitHub недоступен, используется один direct-запрос и максимум одна VPN-попытка на первый нескачавшийся обязательный файл; затем worker спит ещё час.

## Что podkop-guard намеренно НЕ делает

- не патчит Podkop;
- не меняет `community_lists`;
- не включает Podkop `download_lists_via_proxy`;
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

Порядок `START=98 → Podkop START=99` проверен на указанных выше версиях. После крупных обновлений Podkop порядок init-сервисов следует проверить заново.

Проект не пытается гарантировать работу при повреждённом persistent LKG или при несовместимых изменениях формата cache/rule-set в будущих версиях sing-box.

## История изменений

См. [CHANGELOG.md](CHANGELOG.md).

## Лицензия

Экспериментальная ветка watchdog использует GPLv3 для комбинированного кода — см. [LICENSE](LICENSE). Исходные MIT-уведомления сохранены в [LICENSE.MIT](LICENSE.MIT); сведения о заимствованном коде — в [THIRD_PARTY.md](THIRD_PARTY.md).
