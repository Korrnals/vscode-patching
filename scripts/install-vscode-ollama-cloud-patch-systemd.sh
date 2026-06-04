#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="vscode-ollama-cloud-patch.service"
TIMER_NAME="vscode-ollama-cloud-patch.timer"
SYSTEM_SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
SYSTEM_TIMER_PATH="/etc/systemd/system/${TIMER_NAME}"
SYSTEM_HELPER_PATH="/usr/local/sbin/vscode-ollama-cloud-patch.py"
ACTIVE_SYSTEM_HELPER_PATH="${SYSTEM_HELPER_PATH}"
TARGET_USER="${SUDO_USER:-${USER:-root}}"
USER_HOME=""
USER_UNIT_DIR=""
USER_SERVICE_PATH=""
USER_TIMER_PATH=""
USER_HELPER_DIR=""
USER_HELPER_PATH=""
SOURCE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vscode-ollama-cloud-patch.py"

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "[error] run as root (or with sudo)"
    exit 1
  fi
}

detect_scope() {
  local requested="${1:-auto}"

  case "${requested}" in
    system|user)
      echo "${requested}"
      return 0
      ;;
    auto)
      ;;
    *)
      echo "[error] invalid mode: ${requested}. use auto|system|user" >&2
      exit 2
      ;;
  esac

  # system scope is available only when systemd is PID 1 and bus is reachable.
  if [[ -d /run/systemd/system ]] && systemctl list-unit-files >/dev/null 2>&1 && [[ ${EUID} -eq 0 ]]; then
    echo "system"
    return 0
  fi

  # In containers/podman without PID1 systemd, always fallback to user scope.
  echo "user"
}

resolve_user_home() {
  local user_name="$1"
  local home
  home="$(getent passwd "${user_name}" | awk -F: '{print $6}')"
  if [[ -z "${home}" ]]; then
    echo "[error] cannot resolve home for user: ${user_name}" >&2
    exit 1
  fi
  echo "${home}"
}

set_user_paths() {
  USER_HOME="$(resolve_user_home "${TARGET_USER}")"
  USER_UNIT_DIR="${USER_HOME}/.config/systemd/user"
  USER_SERVICE_PATH="${USER_UNIT_DIR}/${SERVICE_NAME}"
  USER_TIMER_PATH="${USER_UNIT_DIR}/${TIMER_NAME}"
  USER_HELPER_DIR="${USER_HOME}/.local/bin"
  USER_HELPER_PATH="${USER_HELPER_DIR}/vscode-ollama-cloud-patch.py"
}

run_as_target_user() {
  if [[ ${EUID} -eq 0 ]] && [[ "${TARGET_USER}" != "$(id -un)" ]]; then
    runuser -u "${TARGET_USER}" -- "$@"
  else
    "$@"
  fi
}

run_user_systemctl() {
  local uid runtime_dir
  uid="$(id -u "${TARGET_USER}")"
  runtime_dir="/run/user/${uid}"

  if [[ ${EUID} -eq 0 ]] && [[ "${TARGET_USER}" != "$(id -un)" ]]; then
    if [[ -d "${runtime_dir}" ]]; then
      runuser -u "${TARGET_USER}" -- env XDG_RUNTIME_DIR="${runtime_dir}" systemctl --user "$@"
    else
      runuser -u "${TARGET_USER}" -- systemctl --user "$@"
    fi
  else
    if [[ -d "${runtime_dir}" ]]; then
      XDG_RUNTIME_DIR="${runtime_dir}" systemctl --user "$@"
    else
      systemctl --user "$@"
    fi
  fi
}

system_scope_available() {
  [[ -d /run/systemd/system ]] && systemctl list-unit-files >/dev/null 2>&1
}

user_scope_available() {
  run_user_systemctl list-unit-files >/dev/null 2>&1
}

print_file_state() {
  local path
  for path in "$@"; do
    if [[ -e "${path}" ]]; then
      echo "[file] present: ${path}"
    else
      echo "[file] missing: ${path}"
    fi
  done
}

write_service_unit() {
  local service_path="$1"
  local helper_path="$2"

  cat > "${service_path}" <<UNIT
[Unit]
Description=Patch VS Code Copilot Chat for Ollama Cloud apiKey support
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env python3 ${helper_path}
UNIT
}

write_timer_unit() {
  local timer_path="$1"

  cat > "${timer_path}" <<'UNIT'
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

install_system_files() {
  require_root
  ACTIVE_SYSTEM_HELPER_PATH="${SYSTEM_HELPER_PATH}"
  if ! install -m 0755 "${SOURCE_SCRIPT}" "${SYSTEM_HELPER_PATH}"; then
    ACTIVE_SYSTEM_HELPER_PATH="${SOURCE_SCRIPT}"
    echo "[warn] cannot write ${SYSTEM_HELPER_PATH}; using source script path in unit: ${SOURCE_SCRIPT}" >&2
  fi
  write_service_unit "${SYSTEM_SERVICE_PATH}" "${ACTIVE_SYSTEM_HELPER_PATH}"
  write_timer_unit "${SYSTEM_TIMER_PATH}"
}

install_user_files() {
  set_user_paths
  run_as_target_user mkdir -p "${USER_HELPER_DIR}" "${USER_UNIT_DIR}"
  run_as_target_user install -m 0755 "${SOURCE_SCRIPT}" "${USER_HELPER_PATH}"
  run_as_target_user bash -lc "cat > '${USER_SERVICE_PATH}' <<'UNIT'
[Unit]
Description=Patch VS Code Copilot Chat for Ollama Cloud apiKey support
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env python3 ${USER_HELPER_PATH}
UNIT"
  run_as_target_user bash -lc "cat > '${USER_TIMER_PATH}' <<'UNIT'
[Unit]
Description=Re-apply VS Code Ollama Cloud patch periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
Persistent=true
Unit=vscode-ollama-cloud-patch.service

[Install]
WantedBy=timers.target
UNIT"
}

install_timer() {
  local mode="$(detect_scope "${1:-auto}")"
  local started="yes"

  if [[ "${mode}" == "system" ]]; then
    install_system_files
    if system_scope_available \
      && systemctl daemon-reload \
      && systemctl enable --now "${TIMER_NAME}" \
      && systemctl start "${SERVICE_NAME}"; then
      :
    else
      started="no"
      echo "[warn] system units installed, but could not start/enable via systemctl (system scope unavailable or inactive)" >&2
      echo "[hint] when systemd is running, apply manually: systemctl daemon-reload && systemctl enable --now ${TIMER_NAME}" >&2
    fi
  else
    install_user_files
    if run_user_systemctl daemon-reload \
      && run_user_systemctl enable --now "${TIMER_NAME}" \
      && run_user_systemctl start "${SERVICE_NAME}"; then
      :
    else
      started="no"
      echo "[warn] user units installed, but could not start/enable via systemctl --user" >&2
      echo "[hint] ensure user systemd session exists, then run: systemctl --user daemon-reload && systemctl --user enable --now ${TIMER_NAME}" >&2
    fi
  fi

  if [[ "${started}" == "yes" ]]; then
    echo "[ok] installed and started ${SERVICE_NAME} + ${TIMER_NAME} (scope=${mode})"
  else
    echo "[ok] installed ${SERVICE_NAME} + ${TIMER_NAME} (scope=${mode}, not started)"
  fi
  status "${mode}"
}

uninstall_timer() {
  local requested_mode="${1:-auto}"

  if [[ "${requested_mode}" == "auto" ]]; then
    systemctl disable --now "${TIMER_NAME}" 2>/dev/null || true
    run_user_systemctl disable --now "${TIMER_NAME}" 2>/dev/null || true
    if [[ ${EUID} -eq 0 ]]; then
      rm -f "${SYSTEM_SERVICE_PATH}" "${SYSTEM_TIMER_PATH}" "${SYSTEM_HELPER_PATH}"
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    set_user_paths
    rm -f "${USER_SERVICE_PATH}" "${USER_TIMER_PATH}" "${USER_HELPER_PATH}"
    run_user_systemctl daemon-reload >/dev/null 2>&1 || true
    echo "[ok] removed units/helper in both scopes where accessible"
    return 0
  fi

  local mode="$(detect_scope "${requested_mode}")"
  if [[ "${mode}" == "system" ]]; then
    require_root
    systemctl disable --now "${TIMER_NAME}" 2>/dev/null || true
    rm -f "${SYSTEM_SERVICE_PATH}" "${SYSTEM_TIMER_PATH}" "${SYSTEM_HELPER_PATH}"
    systemctl daemon-reload
  else
    set_user_paths
    run_user_systemctl disable --now "${TIMER_NAME}" 2>/dev/null || true
    rm -f "${USER_SERVICE_PATH}" "${USER_TIMER_PATH}" "${USER_HELPER_PATH}"
    run_user_systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  echo "[ok] removed ${SERVICE_NAME}, ${TIMER_NAME}, and helper script (scope=${mode})"
}

status() {
  local requested_mode="${1:-auto}"

  if [[ "${requested_mode}" == "auto" ]]; then
    echo "== system scope =="
    if system_scope_available; then
      systemctl status "${SERVICE_NAME}" --no-pager || true
      systemctl status "${TIMER_NAME}" --no-pager || true
      systemctl list-timers "${TIMER_NAME}" --no-pager || true
    else
      echo "[warn] system scope bus unavailable"
      print_file_state "${SYSTEM_SERVICE_PATH}" "${SYSTEM_TIMER_PATH}" "${SYSTEM_HELPER_PATH}"
    fi
    echo "== user scope =="
    set_user_paths
    if user_scope_available; then
      run_user_systemctl status "${SERVICE_NAME}" --no-pager || true
      run_user_systemctl status "${TIMER_NAME}" --no-pager || true
      run_user_systemctl list-timers "${TIMER_NAME}" --no-pager || true
    else
      echo "[warn] user scope bus unavailable"
      print_file_state "${USER_SERVICE_PATH}" "${USER_TIMER_PATH}" "${USER_HELPER_PATH}"
    fi
    return 0
  fi

  local mode="$(detect_scope "${requested_mode}")"
  if [[ "${mode}" == "system" ]]; then
    if system_scope_available; then
      systemctl status "${SERVICE_NAME}" --no-pager || true
      systemctl status "${TIMER_NAME}" --no-pager || true
      systemctl list-timers "${TIMER_NAME}" --no-pager || true
    else
      echo "[warn] system scope bus unavailable"
      print_file_state "${SYSTEM_SERVICE_PATH}" "${SYSTEM_TIMER_PATH}" "${SYSTEM_HELPER_PATH}"
    fi
  else
    set_user_paths
    if user_scope_available; then
      run_user_systemctl status "${SERVICE_NAME}" --no-pager || true
      run_user_systemctl status "${TIMER_NAME}" --no-pager || true
      run_user_systemctl list-timers "${TIMER_NAME}" --no-pager || true
    else
      echo "[warn] user scope bus unavailable"
      print_file_state "${USER_SERVICE_PATH}" "${USER_TIMER_PATH}" "${USER_HELPER_PATH}"
    fi
  fi
}

COMMAND="${1:-install}"
MODE="${2:-${MODE:-auto}}"

case "${COMMAND}" in
  install)
    install_timer "${MODE}"
    ;;
  uninstall)
    uninstall_timer "${MODE}"
    ;;
  status)
    status "${MODE}"
    ;;
  *)
    echo "Usage: $0 [install|uninstall|status] [auto|system|user]"
    echo "       or: MODE=auto|system|user $0 <command>"
    exit 2
    ;;
esac
