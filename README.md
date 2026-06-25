# vscode-patch — VS Code Copilot Ollama Cloud apiKey persistent patch

Минимальный набор скриптов, который добавляет поле **`apiKey`** в манифест провайдера `ollama` расширения Copilot Chat для VS Code. Без этого поля Ollama Cloud отдает `401 Unauthorized`, а каждое обновление VS Code/Copilot вайпит правки в `package.json`.

Решение — идемпотентный патчер + автоматическое перенакатывание после обновлений. Бэкенд персистентности выбирается автоматически под окружение: системный systemd-timer, пользовательский systemd-timer или shell-hook (для контейнеров/distrobox без работающего systemd).

---

## Что делает

В файлах `package.json` расширения Copilot Chat:

- ищет провайдер с `"vendor": "ollama"` в `contributes.languageModelChatProviders`;
- добавляет/обновляет поле `apiKey` в `configuration.properties`:

```json
"apiKey": {
  "type": "string",
  "secret": true,
  "description": "API key for Ollama Cloud (https://ollama.com). Leave empty for local Ollama.",
  "title": "API Key"
}
```

- сохраняет backup рядом как `package.json.bak` (один раз);
- ничего не делает повторно, если уже пропатчено.

### Целевые пути

Скрипт обходит фиксированный список + glob-паттерны для VS Code Remote/Server:

- `/usr/share/code/resources/app/extensions/github.copilot-chat/package.json`
- `/usr/share/code/resources/app/extensions/copilot/package.json`
- `/usr/share/code-insiders/.../package.json`
- `~/.vscode-server/extensions/github.copilot-chat-*/package.json`
- `~/.vscode-server/extensions/copilot-*/package.json`
- `/root/.vscode-server/cli/servers/*/server/extensions/{copilot,github.copilot-chat}/package.json`

Несуществующие пути молча пропускаются.

---

## Использование

### Быстрый выбор команды

Если не хотите разбираться в деталях:

1. `make patch` — применить патч прямо сейчас (работает всегда)
2. `make install` — настроить автоприменение (timer или shell-hook — выберется само)
3. `make status` — проверить: применён ли патч + какой backend активен
4. `make uninstall` — удалить всё

Полный список: `make help-all`.

### Разовый патч

```bash
make patch
```

Если целевые `package.json` принадлежат root (системная установка VS Code),
применяйте через `sudo`:

```bash
sudo make patch
```

### Постоянный фикс

```bash
make install
```

`install` выбирает **backend персистентности** автоматически и сразу применяет
патч. Если доступен passwordless `sudo`, системные файлы патчатся через него.

Доступные backend'ы (выбирается первый рабочий):

- **`system`** — root + работающий системный systemd → service+timer в `/etc/systemd/system`.
- **`user`** — работающий пользовательский systemd (`--user`) → service+timer в `~/.config/systemd/user`.
- **`shell`** — systemd недоступен (контейнер/distrobox) → hook в `~/.bashrc`, перенакат патча на старте shell.

Режим можно задать явно через `MODE`; если выбранный backend недоступен,
происходит автоматический fallback к следующему рабочему:

```bash
make install MODE=auto    # по умолчанию: system -> user -> shell
make install MODE=system  # если нет root/systemd -> user -> shell
make install MODE=user    # если user systemd offline -> shell
make install MODE=shell   # всегда shell-hook
```

Расписание systemd-timer (для backend `system`/`user`):

- `OnBootSec=2min` — через 2 минуты после загрузки
- `OnUnitActiveSec=30min` — далее каждые 30 минут
- `Persistent=true` — догонит пропущенный запуск

> В distrobox и подобных контейнерах systemd обычно в состоянии `offline`
> (отвечает на запросы, но не запускает юниты). Инструмент честно это
> определяет и переключается на shell-hook — никаких "тихих" зависших
> таймеров. Команды никогда не падают из-за недоступной шины systemd.

### Проверка

```bash
make status
```

`status` показывает: применён ли патч к каждому целевому файлу, какие backend'ы
доступны и какие файлы установлены. Только проверку патча (без systemd-деталей)
можно получить напрямую:

```bash
python3 scripts/vscode-ollama-cloud-patch.py --check
```

### Управление systemd-сервисом (svc-*)

Команды управления выделены в префикс `svc-`, чтобы не путаться с базовыми
(`install`/`status`/`uninstall`/`patch`).

```bash
make svc-status MODE=user     # systemctl is-enabled/status/list-timers для service + timer
make svc-enable MODE=user     # включить и запустить timer
make svc-disable MODE=user    # выключить и остановить timer
make svc-start MODE=user      # запустить oneshot-service немедленно
make svc-stop MODE=user       # остановить timer и service
make svc-restart MODE=user    # перезапустить timer и повторно запустить service
```

`make svc-status` — прямой вызов `systemctl is-enabled`, `list-unit-files`,
`list-timers --all` и `status` для `vscode-ollama-cloud-patch.service` и
`vscode-ollama-cloud-patch.timer` — то же самое, как если бы вы запустили эти
команды руками. `make status` показывает сводный отчёт (патч + backend'ы +
файлы) — это другая команда.

Применимы для backend'ов `system`/`user` (при работающем systemd).
В режиме `shell` (distrobox без systemd) `svc-start`/`svc-restart` перенакатывают
патч напрямую, остальные — no-op с понятным сообщением. Для принудительного
scope передавайте `MODE=system` или `MODE=user`.

### Удаление

```bash
make uninstall
```

`uninstall` — best-effort очистка по всем backend'ам сразу (system units, user
units, helper, shell-hook). Никогда не падает, даже если systemd недоступен.

---

## Структура

```text
vscode-patch/
├── Makefile
├── README.md
└── scripts/
    ├── vscode-ollama-cloud-patch.py            # сам патчер (idempotent)
    └── install-vscode-ollama-cloud-patch-systemd.sh  # установщик service+timer
```

---

## Откат

1. `make uninstall` — снимет timer/service/hook по всем backend'ам и удалит helper.
2. Восстановить исходный `package.json` из соседнего `.bak`:

```bash
sudo mv /path/to/package.json.bak /path/to/package.json
```
