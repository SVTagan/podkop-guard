# История изменений

## 0.2.1 — 2026-08-27

Исправления совместимости после первого запуска v0.2 на реальном OpenWrt и завершение полной проверки на целевом роутере.

- Убрана зависимость от отдельной утилиты `stat`: на целевом Cudy TR3000/OpenWrt 24.10.5 её нет в базовой системе.
- Возраст LKG теперь определяется штатным BusyBox `date -r FILE +%s`, который проверен на целевом роутере.
- Установщик больше не требует `stat` и отдельно проверяет поддержку `date -r`.
- Определение VPN-режима для fallback-download теперь понимает как `podkop.main.connection_type`, так и `podkop.main.type`, чтобы не зависеть от варианта UCI-схемы Podkop.
- Offline cache test использует большой `update_interval`, чтобы проверять именно возможность холодного старта из cache, а не создавать лишний цикл background refresh.
- Добавлена защита от принятия пустого `lkg-subnets.lst` в текущем сценарии использования.
- `refresh-test` полностью пройден на Cudy TR3000 v1: все 14 Community SRS скачаны и проверены, объединённый LKG прошёл compile/decompile round-trip, получен список из 1161 безусловного CIDR, 8 conditional CIDR корректно пропущены.
- Полный `refresh-test` занял около 15 секунд; SHA-256 всех трёх persistent LKG-файлов до и после теста совпали, что подтвердило отсутствие записи в persistent state.
- Выполнена установка поверх экспериментального v0.1 без удаления существующего LKG; состояние сервиса и автозапуска сохранено.
- Выполнен настоящий reboot OpenWrt. В boot log подтверждён порядок: `podkop-guard` восстановил persistent `cache.db` в `/tmp` на `START=98`, после чего Podkop начал запуск на `START=99`.
- После reboot procd-daemon `podkop-guard` работает, sing-box runtime имеет состояние `ready`, Local Subnet LKG загружен в `PodkopTable/podkop_subnets`; Telegram, YouTube и Gemini работают.

## 0.2.0 — 2026-08-27

Первая полноценная версия с автоматическим обслуживанием Last Known Good.

- Добавлен лёгкий procd-worker с 300-секундным startup grace.
- Проверка необходимости refresh выполняется раз в час.
- Успешный LKG обновляется не чаще одного раза в 24 часа.
- Возраст последнего полностью успешного snapshot определяется по `mtime` persistent `cache.db`, без отдельного timestamp-файла.
- Community Lists читаются напрямую из `podkop.main.community_lists`.
- Каждый SRS скачивается из `allow-domains` GitHub Releases с жёсткими `curl` timeout.
- При неудачном direct download в VPN-режиме выполняется одна повторная попытка через текущий `podkop.main.interface` с `curl --interface`.
- Refresh прекращается на первом обязательном SRS, который не удалось получить; частичные snapshots не принимаются.
- Каждый candidate SRS проверяется через `sing-box rule-set decompile`.
- Объединённый `lkg.srs` проходит compile/decompile round-trip и canonical JSON compare.
- `lkg-subnets.lst` содержит только безусловные `ip_cidr`; CIDR из правил с `network`, `port_range` и другими условиями пропускаются с warning.
- Candidate `cache.db` проверяется отдельным offline sing-box с намеренно мёртвым SOCKS download detour `127.0.0.1:9`.
- Тестовый sing-box завершается сразу после `sing-box started`; максимальный timeout — 10 секунд.
- Более тяжёлые `jq`/`sing-box` операции запускаются через `nice -n 10`.
- Все промежуточные данные собираются в `/tmp`.
- На flash попадают только полностью проверенные candidates; временные файлы сначала создаются внутри `/etc/podkop-guard`, затем заменяют final-файлы через `mv`.
- `cache.db` коммитится последним и служит success marker всего refresh.
- Неизменившиеся `lkg.srs`/`lkg-subnets.lst` не переписываются.
- Неудачный refresh никогда не заменяет текущий persistent LKG.
- Добавлен `refresh-test`, выполняющий полный pipeline без записи persistent LKG.
- Добавлены `refresh`, `boot-restore` и `daemon`.
- Init-сервис переведён на procd: `START=98`, затем Podkop 0.7.21 стартует с `START=99`.
- Boot cache restore и periodic updater объединены в один сервис.
- Добавлены безопасные `install.sh` и `uninstall.sh`.
- Основной README переведён на русский; добавлен `README.en.md`.
- Добавлена MIT License.

## 0.1.0 — 2026-08-27

Экспериментальный прототип, собранный после реального отказа GitHub/list update.

- Создан persistent `lkg.srs` из 14 выбранных Community Lists.
- Подтверждён byte-identical compile/decompile round-trip canonical JSON.
- Из LKG получен `lkg-subnets.lst` с 1161 безусловным CIDR; 8 conditional Discord CIDR были намеренно пропущены.
- `lkg-subnets.lst` подключён в Podkop как Local Subnet List и проверен реальным reload.
- Сохранён persistent sing-box `cache.db`.
- A/B тест Telegram подтвердил: с cache и мёртвым remote download sing-box стартует; без cache — падает с FATAL initial rule-set error.
- Аналогичный offline test успешно пройден со всеми 14 remote Community SRS.
- Отдельный stale-cache test подтвердил, что просроченные cached rulesets продолжают использоваться при неудачном background refresh.
- Добавлен `START=98` boot restore cache перед Podkop.
- Выполнена контролируемая имитация cold boot: Podkop остановлен, `/tmp/sing-box/cache.db` удалён, persistent cache восстановлен, SHA-256 совпал, после запуска Podkop Telegram/YouTube/Gemini работали.
