SHELL := /usr/bin/env bash
# Recipe lines run with -c; SIGPIPE from early-closed pipes is non-fatal
# so `make help | head` doesn't break.
.SHELLFLAGS := -c
.DEFAULT_GOAL := help

PATCH_SCRIPT := scripts/vscode-ollama-cloud-patch.py
INSTALLER    := scripts/install-vscode-ollama-cloud-patch-systemd.sh
MODE ?= auto

.PHONY: help help-all patch install status uninstall \
        svc-enable svc-disable svc-start svc-stop svc-restart svc-status

# help targets are documentation; never let SIGPIPE from `| head`/`| less`
# be reported as a recipe failure.
help help-all: IGNORE = 1

help: ## Show command reference
	@if [[ -t 1 && -z "$${NO_COLOR:-}" ]]; then \
		C_TITLE=$$'\033[1;36m'; C_HEAD=$$'\033[1;33m'; C_STEP=$$'\033[1;32m'; C_BOLD=$$'\033[1m'; C_DIM=$$'\033[2m'; C_RESET=$$'\033[0m'; \
	else \
		C_TITLE=""; C_HEAD=""; C_STEP=""; C_BOLD=""; C_DIM=""; C_RESET=""; \
	fi; \
	printf "\n%sVS Code Copilot Ollama Cloud apiKey patch%s\n" "$$C_TITLE" "$$C_RESET"; \
	printf "%sMODE=auto: system -> user -> shell-hook (выбирается рабочий backend)%s\n\n" "$$C_DIM" "$$C_RESET"; \
	printf "%sЧто запускать:%s\n" "$$C_HEAD" "$$C_RESET"; \
	printf "  %s1) Применить сейчас:%s  make patch\n" "$$C_STEP" "$$C_RESET"; \
	printf "  %s2) Автоприменение:%s    make install\n" "$$C_STEP" "$$C_RESET"; \
	printf "  %s3) Проверить статус:%s  make status\n" "$$C_STEP" "$$C_RESET"; \
	printf "  %s4) Удалить:%s          make uninstall\n\n" "$$C_STEP" "$$C_RESET"; \
	printf "%sОсновные команды:%s\n" "$$C_HEAD" "$$C_RESET"; \
	printf "  %spatch%s       Применить патч сейчас (работает всегда)\n" "$$C_BOLD" "$$C_RESET"; \
	printf "  %sinstall%s     Настроить автоприменение (systemd timer или shell-hook)\n" "$$C_BOLD" "$$C_RESET"; \
	printf "  %sstatus%s      Показать: применён ли патч + активный backend\n" "$$C_BOLD" "$$C_RESET"; \
	printf "  %suninstall%s   Удалить units, helper и shell-hook\n\n" "$$C_BOLD" "$$C_RESET"; \
	printf "%sУправление systemd-сервисом:%s\n" "$$C_HEAD" "$$C_RESET"; \
	printf "  %ssvc-enable%s    Включить и запустить timer\n" "$$C_BOLD" "$$C_RESET"; \
	printf "  %ssvc-disable%s   Выключить и остановить timer\n" "$$C_BOLD" "$$C_RESET"; \
	printf "  %ssvc-start%s     Запустить oneshot-service сейчас\n" "$$C_BOLD" "$$C_RESET"; \
	printf "  %ssvc-stop%s      Остановить timer и service\n" "$$C_BOLD" "$$C_RESET"; \
	printf "  %ssvc-restart%s   Перезапустить timer + service\n" "$$C_BOLD" "$$C_RESET"; \
	printf "  %ssvc-status%s    systemctl is-enabled/status/list-timers для service + timer (scope по MODE)\n" "$$C_BOLD" "$$C_RESET"; \
	printf "  %sВсе принимают%s MODE=auto|system|user|shell\n\n" "$$C_DIM" "$$C_RESET"; \
	printf "Полный список: %smake help-all%s\n\n" "$$C_BOLD" "$$C_RESET"

help-all: ## Show full command reference
	@if [[ -t 1 && -z "$${NO_COLOR:-}" ]]; then \
		C_TITLE=$$'\033[1;36m'; C_HEAD=$$'\033[1;33m'; C_DIM=$$'\033[2m'; C_BOLD=$$'\033[1m'; C_RESET=$$'\033[0m'; \
	else \
		C_TITLE=""; C_HEAD=""; C_DIM=""; C_BOLD=""; C_RESET=""; \
	fi; \
	printf "\n%sПолный список команд%s\n\n" "$$C_TITLE" "$$C_RESET"; \
	printf "%sБазовые:%s\n" "$$C_HEAD" "$$C_RESET"; \
	printf "  make patch\n"; \
	printf "  make install [MODE=auto|system|user|shell]\n"; \
	printf "  make status [MODE=auto|system|user|shell]\n"; \
	printf "  make uninstall\n\n"; \
	printf "%sУправление systemd-сервисом:%s\n" "$$C_HEAD" "$$C_RESET"; \
	printf "  %smake svc-enable%s    [MODE=...]  # enable+start timer\n" "$$C_BOLD" "$$C_RESET"; \
	printf "  %smake svc-disable%s   [MODE=...]  # disable+stop timer\n" "$$C_BOLD" "$$C_RESET"; \
	printf "  %smake svc-start%s     [MODE=...]  # запустить service сейчас (oneshot)\n" "$$C_BOLD" "$$C_RESET"; \
	printf "  %smake svc-stop%s      [MODE=...]  # остановить timer + service\n" "$$C_BOLD" "$$C_RESET"; \
	printf "  %smake svc-restart%s   [MODE=...]  # перезапустить timer + service\n" "$$C_BOLD" "$$C_RESET"; \
	printf "  %smake svc-status%s    [MODE=...]  # is-enabled + status + list-timers (service+timer)\n" "$$C_BOLD" "$$C_RESET"; \
	printf "%sПримечание:%s команды svc-* работают с backend'ами system/user.\n" "$$C_DIM" "$$C_RESET"; \
	printf "В backend=shell (distrobox без systemd) svc-start/svc-restart перенакатывают\n"; \
	printf "патч напрямую, остальные — no-op. Для принудительного scope: MODE=system|user.\n\n"; \
	printf "%sBackends:%s system (root+systemd), user (user systemd), shell (~/.bashrc hook).\n" "$$C_DIM" "$$C_RESET"; \
	printf "%sauto выбирает первый рабочий. В distrobox без systemd используется shell.%s\n\n" "$$C_DIM" "$$C_RESET"

patch: ## Apply Ollama apiKey patch once (idempotent)
	@python3 $(PATCH_SCRIPT)

install: ## Install service + timer (or shell hook), MODE=auto|system|user|shell
	@bash $(INSTALLER) install $(MODE)

status: ## Show patch state + persistence backend, MODE=auto|system|user|shell
	@bash $(INSTALLER) status $(MODE)

uninstall: ## Remove units, helper and shell hook from all scopes
	@bash $(INSTALLER) uninstall

svc-enable: ## Enable and start the timer, MODE=auto|system|user|shell
	@bash $(INSTALLER) enable $(MODE)

svc-disable: ## Disable and stop the timer, MODE=auto|system|user|shell
	@bash $(INSTALLER) disable $(MODE)

svc-start: ## Run the oneshot service now, MODE=auto|system|user|shell
	@bash $(INSTALLER) start $(MODE)

svc-stop: ## Stop the timer and service, MODE=auto|system|user|shell
	@bash $(INSTALLER) stop $(MODE)

svc-restart: ## Restart the timer and rerun the service, MODE=auto|system|user|shell
	@bash $(INSTALLER) restart $(MODE)

svc-status: ## systemctl is-enabled/status/list-timers for service+timer, MODE=auto|system|user|shell
	@bash $(INSTALLER) svc-status $(MODE)
