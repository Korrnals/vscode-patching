#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="vscode-ollama-cloud-patch.service"
TIMER_NAME="vscode-ollama-cloud-patch.timer"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
TIMER_PATH="/etc/systemd/system/${TIMER_NAME}"
HELPER_PATH="/usr/local/sbin/vscode-ollama-cloud-patch.py"
SOURCE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vscode-ollama-cloud-patch.py"

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "[error] run as root (or with sudo)"
    exit 1
  fi
}

install_files() {
  install -m 0755 "${SOURCE_SCRIPT}" "${HELPER_PATH}"

  cat > "${SERVICE_PATH}" <<'UNIT'
[Unit]
Description=Patch VS Code Copilot Chat for Ollama Cloud apiKey support
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env python3 /usr/local/sbin/vscode-ollama-cloud-patch.py
User=root
Group=root
UNIT

  cat > "${TIMER_PATH}" <<'UNIT'
[Unit]
Description=Re-apply VS Code Ollama Cloud patch periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
Persistent=true
Unit=vscode-ollama-cloud-patch.service

[Install]
WantedBy=timers.target
UNIT
}

install_timer() {
  require_root
  install_files
  systemctl daemon-reload
  systemctl enable --now "${TIMER_NAME}"
  systemctl start "${SERVICE_NAME}"
  echo "[ok] installed and started ${SERVICE_NAME} + ${TIMER_NAME}"
  status
}

uninstall_timer() {
  require_root
  systemctl disable --now "${TIMER_NAME}" 2>/dev/null || true
  rm -f "${SERVICE_PATH}" "${TIMER_PATH}" "${HELPER_PATH}"
  systemctl daemon-reload
  echo "[ok] removed ${SERVICE_NAME}, ${TIMER_NAME}, and helper script"
}

status() {
  systemctl status "${SERVICE_NAME}" --no-pager || true
  systemctl status "${TIMER_NAME}" --no-pager || true
  systemctl list-timers "${TIMER_NAME}" --no-pager || true
}

case "${1:-install}" in
  install)
    install_timer
    ;;
  uninstall)
    uninstall_timer
    ;;
  status)
    status
    ;;
  *)
    echo "Usage: $0 [install|uninstall|status]"
    exit 2
    ;;
esac
