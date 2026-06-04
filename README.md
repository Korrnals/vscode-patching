# vscode-patch — VS Code Copilot Ollama Cloud apiKey persistent patch

Минимальный набор скриптов, который добавляет поле **`apiKey`** в манифест провайдера `ollama` расширения Copilot Chat для VS Code. Без этого поля Ollama Cloud отдает `401 Unauthorized`, а каждое обновление VS Code/Copilot вайпит правки в `package.json`.

Решение — идемпотентный патчер + systemd timer, который перенакатывает патч после обновлений.

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

### Разовый патч

```bash
make patch
```

### Постоянный фикс (systemd timer)

```bash
sudo make install
```

Установит:

- `/usr/local/sbin/vscode-ollama-cloud-patch.py`
- `/etc/systemd/system/vscode-ollama-cloud-patch.service`
- `/etc/systemd/system/vscode-ollama-cloud-patch.timer`

Расписание timer:

- `OnBootSec=2min` — через 2 минуты после загрузки
- `OnUnitActiveSec=30min` — далее каждые 30 минут
- `Persistent=true` — догонит пропущенный запуск

### Проверка

```bash
make status
```

### Удаление

```bash
sudo make uninstall
```

---

## Структура

```
vscode-patch/
├── Makefile
├── README.md
└── scripts/
    ├── vscode-ollama-cloud-patch.py            # сам патчер (idempotent)
    └── install-vscode-ollama-cloud-patch-systemd.sh  # установщик service+timer
```

---

## Откат

1. `sudo make uninstall` — снимет timer/service и удалит helper.
2. Восстановить исходный `package.json` из соседнего `.bak`:

```bash
sudo mv /path/to/package.json.bak /path/to/package.json
```
