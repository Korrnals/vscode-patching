SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

PATCH_SCRIPT := scripts/vscode-ollama-cloud-patch.py
INSTALLER    := scripts/install-vscode-ollama-cloud-patch-systemd.sh
MODE ?= system

.PHONY: help patch install status uninstall

help: ## Show command reference
	@printf "\nVS Code Copilot Ollama Cloud apiKey patch\n\n"
	@awk 'BEGIN {FS = ":.*##"; printf "Targets:\n"} /^[a-zA-Z0-9_.-]+:.*##/ {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf "\nExamples:\n"
	@printf "  make patch        # apply patch once (idempotent)\n"
	@printf "  make install                  # install system service (uses sudo if needed)\n"
	@printf "  make install MODE=user        # force systemd --user (podman/container)\n"
	@printf "  sudo make install MODE=system # force system scope\n"
	@printf "  make status       # show timer/service status\n"
	@printf "  make uninstall MODE=user\n"
	@printf "  sudo make uninstall MODE=system\n\n"

patch: ## Apply Ollama apiKey patch once (idempotent)
	@python3 $(PATCH_SCRIPT)

install: ## Install service + timer, MODE=auto|system|user
	@if [[ "$(MODE)" == "system" ]] && [[ "$$(id -u)" -ne 0 ]]; then \
		sudo bash $(INSTALLER) install $(MODE); \
	else \
		bash $(INSTALLER) install $(MODE); \
	fi

status: ## Show service + timer status, MODE=auto|system|user
	@if [[ "$(MODE)" == "system" ]] && [[ "$$(id -u)" -ne 0 ]]; then \
		sudo bash $(INSTALLER) status $(MODE); \
	else \
		bash $(INSTALLER) status $(MODE); \
	fi

uninstall: ## Remove service + timer, MODE=auto|system|user
	@if [[ "$(MODE)" == "system" ]] && [[ "$$(id -u)" -ne 0 ]]; then \
		sudo bash $(INSTALLER) uninstall $(MODE); \
	else \
		bash $(INSTALLER) uninstall $(MODE); \
	fi
