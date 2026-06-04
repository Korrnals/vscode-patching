SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

PATCH_SCRIPT := scripts/vscode-ollama-cloud-patch.py
INSTALLER    := scripts/install-vscode-ollama-cloud-patch-systemd.sh

.PHONY: help patch install status uninstall

help: ## Show command reference
	@printf "\nVS Code Copilot Ollama Cloud apiKey patch\n\n"
	@awk 'BEGIN {FS = ":.*##"; printf "Targets:\n"} /^[a-zA-Z0-9_.-]+:.*##/ {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf "\nExamples:\n"
	@printf "  make patch        # apply patch once (idempotent)\n"
	@printf "  sudo make install # install systemd service + timer\n"
	@printf "  make status       # show timer/service status\n"
	@printf "  sudo make uninstall\n\n"

patch: ## Apply Ollama apiKey patch once (idempotent)
	@python3 $(PATCH_SCRIPT)

install: ## Install systemd service + timer (requires root)
	@bash $(INSTALLER) install

status: ## Show systemd service + timer status
	@bash $(INSTALLER) status

uninstall: ## Remove systemd service + timer (requires root)
	@bash $(INSTALLER) uninstall
