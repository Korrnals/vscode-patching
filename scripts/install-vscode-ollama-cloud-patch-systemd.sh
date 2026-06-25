#!/usr/bin/env bash
#
# Installer for the VS Code Copilot "Ollama Cloud apiKey" patch.
#
# Persistence strategy (auto-selected, honest about the environment):
#   * system : root + a running system systemd  -> system service+timer
#   * user   : a running user systemd manager    -> user service+timer
#   * shell  : no usable systemd (e.g. distrobox) -> ~/.bashrc hook (re-apply on shell start)
#
# The patch itself is always applied immediately on install, so the value is
# delivered even when no persistence backend is available. No command ever
# hard-fails because of an unreachable systemd bus.
#
set -euo pipefail

SERVICE_NAME="vscode-ollama-cloud-patch.service"
TIMER_NAME="vscode-ollama-cloud-patch.timer"
# Basename without .service/.timer -- used for transient unit naming
SERVICE_BASENAME="vscode-ollama-cloud-patch"

SYSTEM_SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
SYSTEM_TIMER_PATH="/etc/systemd/system/${TIMER_NAME}"
SYSTEM_HELPER_PATH="/usr/local/sbin/vscode-ollama-cloud-patch.py"

# When invoked through sudo, target the *invoking* user for user-scoped
# artifacts (shell hook, user units) instead of root.
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  TARGET_USER="${SUDO_USER}"
  USER_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
else
  TARGET_USER="$(id -un)"
  USER_HOME="${HOME}"
fi
TARGET_UID="$(id -u "${TARGET_USER}" 2>/dev/null || id -u)"
USER_UNIT_DIR="${USER_HOME}/.config/systemd/user"
USER_SERVICE_PATH="${USER_UNIT_DIR}/${SERVICE_NAME}"
USER_TIMER_PATH="${USER_UNIT_DIR}/${TIMER_NAME}"
USER_HELPER_DIR="${USER_HOME}/.local/bin"
USER_HELPER_PATH="${USER_HELPER_DIR}/vscode-ollama-cloud-patch.py"

HOOK_FILE="${USER_HOME}/.bashrc"
HOOK_BEGIN="# >>> vscode-ollama-cloud-patch hook >>>"
HOOK_END="# <<< vscode-ollama-cloud-patch hook <<<"

SOURCE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vscode-ollama-cloud-patch.py"

# ---------------------------------------------------------------------------
# small logging helpers
# ---------------------------------------------------------------------------
log_ok()   { echo "[ok] $*"; }
log_warn() { echo "[warn] $*" >&2; }
log_info() { echo "[info] $*"; }
log_err()  { echo "[error] $*" >&2; }

# ---------------------------------------------------------------------------
# systemd reachability detection (honest: "responds" != "runs units")
# ---------------------------------------------------------------------------

# Run systemctl --user with the correct runtime dir for the current user.
sc_user() {
  local runtime_dir="/run/user/${TARGET_UID}"
  if [[ -d "${runtime_dir}" ]]; then
    env XDG_RUNTIME_DIR="${runtime_dir}" systemctl --user "$@"
  else
    systemctl --user "$@"
  fi
}

# A systemd manager is "usable" when it can read and start units.
#
# `is-system-running` returns "offline" in many containers (distrobox) where
# systemd is in fact running (it answers list-units, can start units, etc.).
# So we probe with `list-unit-files` and treat exit 0 as "usable" instead.
#
# Refs:
#   * is-system-running=offline but list-units works  -> container
#   * is-system-running=offline and list-units fails  -> truly offline
system_systemd_usable() {
  [[ ${EUID} -eq 0 ]] || return 1
  [[ -d /run/systemd/system ]] || return 1
  systemctl list-unit-files >/dev/null 2>&1
}

user_systemd_usable() {
  local runtime_dir="/run/user/${TARGET_UID}"
  if [[ -d "${runtime_dir}" ]]; then
    env XDG_RUNTIME_DIR="${runtime_dir}" systemctl --user list-unit-files >/dev/null 2>&1
  else
    systemctl --user list-unit-files >/dev/null 2>&1
  fi
}

# Decide the persistence backend: system | user | shell
detect_backend() {
  local requested="${1:-auto}"
  case "${requested}" in
    system)
      if system_systemd_usable; then echo "system"; return 0; fi
      log_warn "MODE=system requested, but no usable system systemd (need root + running manager); falling back"
      if user_systemd_usable; then echo "user"; else echo "shell"; fi
      ;;
    user)
      if user_systemd_usable; then echo "user"; return 0; fi
      log_warn "MODE=user requested, but the user systemd manager is not usable; falling back to shell hook"
      echo "shell"
      ;;
    shell)
      echo "shell"
      ;;
    auto)
      if system_systemd_usable; then echo "system"
      elif user_systemd_usable; then echo "user"
      else echo "shell"; fi
      ;;
    *)
      log_err "invalid mode: ${requested}. use auto|system|user|shell"
      exit 2
      ;;
  esac
}

# ---------------------------------------------------------------------------
# transient unit helpers (workaround for distrobox / non-linger user managers)
# ---------------------------------------------------------------------------
# In many containers (distrobox without `loginctl enable-linger`) the user
# systemd manager is in state "offline" and refuses `enable --now` with
# "Cannot start unit with --now when systemd is not running", even though
# `list-unit-files` works and the manager answers dbus calls.
#
# In this state, `systemd-run --user --on-active=...` is the only path that
# produces a unit that actually shows up in `systemctl status` /
# `list-timers`. We use it as a fallback for the user backend so the user
# can see real, live output from `make svc-status` instead of a void.

# Fix ownership of user-home artifacts when this ran under sudo.
chown_to_target() {
  if [[ ${EUID} -eq 0 && "${TARGET_USER}" != "root" ]]; then
    chown "${TARGET_USER}" "$@" 2>/dev/null || true
  fi
}

# transient_unit_active <name>  -> exit 0 if a transient unit with this name exists
transient_unit_active() {
  local name="$1"
  systemctl --user list-units --all "${name}.service" "${name}.timer" 2>/dev/null \
    | awk '$1 ~ /^'"${name}"'\.(service|timer)$/ { if ($3 == "active" || $3 == "waiting" || $3 == "inactive") found=1 }
           END { exit (found ? 0 : 1) }'
}

# systemd_run_user <args...>  -- run systemd-run --user with correct XDG_RUNTIME_DIR
systemd_run_user() {
  local runtime_dir="/run/user/${TARGET_UID}"
  if [[ -d "${runtime_dir}" ]]; then
    env XDG_RUNTIME_DIR="${runtime_dir}" systemd-run --user "$@"
  else
    systemd-run --user "$@"
  fi
}

# start_transient_timer  -> create a transient timer+service that runs the helper
#                            every 30m starting in 2m, with the helper as ExecStart.
# Idempotent: if a transient unit with the same name already exists, this is a no-op.
start_transient_timer() {
  if transient_unit_active "${SERVICE_BASENAME}"; then
    log_info "transient unit ${SERVICE_BASENAME}.{service,timer} already active"
    return 0
  fi

  # Install the helper so the transient unit can call it.
  mkdir -p "${USER_HELPER_DIR}"
  install -m 0755 "${SOURCE_SCRIPT}" "${USER_HELPER_PATH}" 2>/dev/null || true
  chown_to_target "${USER_HELPER_DIR}" "${USER_HELPER_PATH}"

  if systemd_run_user --on-active=2m --on-unit-active=30m \
        --unit="${SERVICE_BASENAME}.service" \
        --description="Patch VS Code Copilot Chat for Ollama Cloud apiKey (transient)" \
        /usr/bin/env python3 "${USER_HELPER_PATH}" >/dev/null 2>&1; then
    log_ok "started transient timer ${SERVICE_BASENAME}.timer (every 30m, via systemd-run)"
    return 0
  fi

  log_warn "systemd-run --user could not create a transient timer"
  return 1
}

stop_transient_timer() {
  if ! transient_unit_active "${SERVICE_BASENAME}"; then
    return 0
  fi
  # Stopping the timer is enough — it triggers the service.
  # Transient services created by systemd-run often report "not loaded"
  # to systemctl stop even though list-units shows them.
  if sc_user stop "${SERVICE_BASENAME}.timer" 2>/dev/null; then
    log_ok "stopped transient timer ${SERVICE_BASENAME}.timer"
  else
    log_warn "could not stop transient timer (will auto-expire)"
  fi
}

write_service_unit() {
  local path="$1" helper="$2"
  cat > "${path}" <<UNIT
[Unit]
Description=Patch VS Code Copilot Chat for Ollama Cloud apiKey support
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env python3 ${helper}
UNIT
}

write_timer_unit() {
  local path="$1"
  cat > "${path}" <<'UNIT'
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

# ---------------------------------------------------------------------------
# patch helpers
# ---------------------------------------------------------------------------
# The Python helper is self-elevating: if it encounters a root-owned target
# it can't write, it re-execs itself under `sudo -n` (when passwordless sudo
# is available). This lets systemd-run --user invoke the helper directly
# without the installer needing to pre-elevate.
#
# We keep run_patch_now as a wrapper for the install flow (the user expects
# "make install" to print a live status of what was patched) and so that
# direct calls also work when run as root.
run_patch_now() {
  python3 "${SOURCE_SCRIPT}" || true
}

# ---------------------------------------------------------------------------
# shell-hook backend (works without systemd)
# ---------------------------------------------------------------------------
hook_installed() {
  [[ -f "${HOOK_FILE}" ]] && grep -qF "${HOOK_BEGIN}" "${HOOK_FILE}" 2>/dev/null
}

install_shell_hook() {
  mkdir -p "${USER_HELPER_DIR}"
  install -m 0755 "${SOURCE_SCRIPT}" "${USER_HELPER_PATH}"
  chown_to_target "${USER_HELPER_DIR}" "${USER_HELPER_PATH}"

  remove_shell_hook quiet

  {
    echo "${HOOK_BEGIN}"
    echo "# Re-applies the Ollama Cloud apiKey patch on shell start (idempotent)."
    echo "if [ -f \"\$HOME/.local/bin/vscode-ollama-cloud-patch.py\" ] && command -v python3 >/dev/null 2>&1; then"
    echo "  if sudo -n true >/dev/null 2>&1; then"
    echo "    sudo -n python3 \"\$HOME/.local/bin/vscode-ollama-cloud-patch.py\" >/dev/null 2>&1 || true"
    echo "  else"
    echo "    python3 \"\$HOME/.local/bin/vscode-ollama-cloud-patch.py\" >/dev/null 2>&1 || true"
    echo "  fi"
    echo "fi"
    echo "${HOOK_END}"
  } >> "${HOOK_FILE}"

  log_ok "installed shell hook into ${HOOK_FILE} (re-applies patch on new shells)"
  log_info "helper: ${USER_HELPER_PATH}"
}

# remove_shell_hook [quiet]
remove_shell_hook() {
  local quiet="${1:-}"
  [[ -f "${HOOK_FILE}" ]] || return 0
  hook_installed || return 0

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/bashrc.XXXXXX")"
  sed "/${HOOK_BEGIN}/,/${HOOK_END}/d" "${HOOK_FILE}" > "${tmp}" && mv "${tmp}" "${HOOK_FILE}"
  [[ "${quiet}" == "quiet" ]] || log_ok "removed shell hook from ${HOOK_FILE}"
}

# ---------------------------------------------------------------------------
# install / uninstall
# ---------------------------------------------------------------------------
install_system() {
  local helper="${SYSTEM_HELPER_PATH}"
  if ! install -m 0755 "${SOURCE_SCRIPT}" "${SYSTEM_HELPER_PATH}" 2>/dev/null; then
    helper="${SOURCE_SCRIPT}"
    log_warn "cannot write ${SYSTEM_HELPER_PATH}; using source path in unit: ${helper}"
  fi
  write_service_unit "${SYSTEM_SERVICE_PATH}" "${helper}"
  write_timer_unit "${SYSTEM_TIMER_PATH}"
  systemctl daemon-reload || true
  if systemctl enable --now "${TIMER_NAME}" >/dev/null 2>&1; then
    log_ok "enabled ${TIMER_NAME} (scope=system)"
  else
    log_warn "units written but could not enable timer (scope=system)"
  fi
  systemctl start "${SERVICE_NAME}" >/dev/null 2>&1 || true
}

install_user() {
  # Write persistent unit files (always -- they document the intent and work
  # on systems where user systemd is fully alive).
  mkdir -p "${USER_HELPER_DIR}" "${USER_UNIT_DIR}"
  install -m 0755 "${SOURCE_SCRIPT}" "${USER_HELPER_PATH}"
  write_service_unit "${USER_SERVICE_PATH}" "${USER_HELPER_PATH}"
  write_timer_unit "${USER_TIMER_PATH}"
  chown_to_target "${USER_HELPER_DIR}" "${USER_HELPER_DIR}" "${USER_HELPER_PATH}" \
                       "${USER_UNIT_DIR}" "${USER_SERVICE_PATH}" "${USER_TIMER_PATH}"
  sc_user daemon-reload || true

  # Try the canonical path first (works on normal systems).
  if sc_user enable --now "${TIMER_NAME}" >/dev/null 2>&1; then
    # Verify the unit is actually loaded in the running manager, not just
    # symlinked. In some environments (e.g. distrobox without linger) the
    # user manager accepts `enable` (creating a symlink) but refuses to
    # actually load units, leaving `systemctl status` reporting
    # "could not be found". Probe with `is-active` and fall through to the
    # transient path if needed.
    if sc_user is-active "${TIMER_NAME}" >/dev/null 2>&1; then
      sc_user start "${SERVICE_NAME}" >/dev/null 2>&1 || true
      log_ok "enabled and started ${TIMER_NAME} (persistent, scope=user)"
      return 0
    fi
    log_warn "persistent timer enabled but not active (user manager not loading units); trying transient fallback"
  else
    log_warn "persistent enable/start not possible in this user manager state; trying transient fallback"
  fi

  # Persistent enable didn't fully work. Fall back to a transient timer that
  # systemd-run can create in this state. This produces a unit that status
  # / list-timers can actually see.
  if start_transient_timer; then
    return 0
  fi

  log_warn "units written to ${USER_UNIT_DIR} but neither persistent nor transient activation worked"
}

do_install() {
  local backend
  backend="$(detect_backend "${1:-auto}")"

  case "${backend}" in
    system) install_system ;;
    user)   install_user ;;
    shell)
      log_info "no usable systemd detected — using shell-hook persistence"
      install_shell_hook
      ;;
  esac

  echo
  log_info "applying patch now:"
  run_patch_now
  echo
  log_ok "install complete (backend=${backend})"
  echo
  do_status "${1:-auto}"
}

do_uninstall() {
  # Best-effort cleanup across every backend; never fails.
  if [[ ${EUID} -eq 0 ]] && [[ -d /run/systemd/system ]]; then
    systemctl disable --now "${TIMER_NAME}" >/dev/null 2>&1 || true
  fi
  rm -f "${SYSTEM_SERVICE_PATH}" "${SYSTEM_TIMER_PATH}" "${SYSTEM_HELPER_PATH}" 2>/dev/null || true
  if [[ ${EUID} -eq 0 ]] && [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  sc_user disable --now "${TIMER_NAME}" >/dev/null 2>&1 || true
  rm -f "${USER_SERVICE_PATH}" "${USER_TIMER_PATH}" "${USER_HELPER_PATH}" 2>/dev/null || true
  sc_user daemon-reload >/dev/null 2>&1 || true

  remove_shell_hook

  log_ok "removed units, helper and shell hook from all accessible scopes"
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
file_state() {
  local p
  for p in "$@"; do
    if [[ -e "${p}" ]]; then echo "  present: ${p}"; else echo "  missing: ${p}"; fi
  done
}

# do_status: full environment report (patch state, backends, files).
# This is what `make status` shows.
do_status() {
  echo "== patch state =="
  python3 "${SOURCE_SCRIPT}" --check || true

  echo
  echo "== persistence backends =="

  if system_systemd_usable; then
    echo "[system] usable"
  else
    echo "[system] not usable (need root + running system systemd)"
  fi

  if user_systemd_usable; then
    echo "[user] usable"
  else
    local st="unreachable"
    st="$(sc_user is-system-running 2>/dev/null)" || true
    [[ -n "${st}" ]] || st="unreachable"
    echo "[user] not usable (systemctl --user is-system-running=${st})"
  fi

  if hook_installed; then
    echo "[shell] hook installed in ${HOOK_FILE}"
  else
    echo "[shell] no hook installed"
  fi

  echo
  echo "== installed files =="
  file_state "${USER_HELPER_PATH}" "${USER_SERVICE_PATH}" "${USER_TIMER_PATH}"
}

# do_svc_status: show the live systemd state for the active unit.
# Displays exactly what `systemctl status` / `list-timers` show — no
# duplication, no noise. If a transient unit is active it is shown;
# otherwise the persistent unit is shown; otherwise a clear "not running"
# message.
do_svc_status() {
  local requested_mode="${1:-auto}" backend
  backend="$(detect_backend "${requested_mode}")"

  case "${backend}" in
    system)
      if ! system_systemd_usable; then
        log_warn "system systemd is not usable; nothing to show for scope=system"
        return 0
      fi
      echo "== systemctl status ${SERVICE_NAME} (scope=system) =="
      systemctl status "${SERVICE_NAME}" --no-pager 2>&1 || true
      echo
      echo "== systemctl status ${TIMER_NAME} (scope=system) =="
      systemctl status "${TIMER_NAME}" --no-pager 2>&1 || true
      echo
      echo "== systemctl list-timers --all ${TIMER_NAME} (scope=system) =="
      systemctl list-timers --all "${TIMER_NAME}" --no-pager 2>&1 || true
      ;;
    user)
      # Decide which unit name is actually live.
      local svc="${SERVICE_NAME}" tmr="${TIMER_NAME}"
      if transient_unit_active "${SERVICE_BASENAME}"; then
        svc="${SERVICE_BASENAME}.service"
        tmr="${SERVICE_BASENAME}.timer"
      fi

      echo "== systemctl --user status ${svc} (scope=user) =="
      sc_user status "${svc}" --no-pager 2>&1 || true
      echo
      echo "== systemctl --user status ${tmr} (scope=user) =="
      sc_user status "${tmr}" --no-pager 2>&1 || true
      echo
      echo "== systemctl --user list-timers --all ${tmr} (scope=user) =="
      sc_user list-timers --all "${tmr}" --no-pager 2>&1 || true
      ;;
    shell)
      log_info "backend=shell — no systemd units to query"
      log_info "shell hook ${HOOK_FILE}: $(hook_installed && echo installed || echo not installed)"
      log_info "helper ${USER_HELPER_PATH}: $([[ -x ${USER_HELPER_PATH} ]] && echo executable || echo missing)"
      return 0
      ;;
  esac
}

# ---------------------------------------------------------------------------
# service control (systemd backends only; shell backend has no live unit)
# ---------------------------------------------------------------------------
service_control() {
  local action="$1" backend
  backend="$(detect_backend "${2:-auto}")"

  if [[ "${backend}" == "shell" ]]; then
    case "${action}" in
      start|restart)
        log_info "no systemd backend; applying patch directly"
        run_patch_now
        ;;
      *)
        log_info "no systemd backend active; '${action}' is a no-op (shell hook re-applies on new shells)"
        ;;
    esac
    return 0
  fi

  local runner=(systemctl)
  [[ "${backend}" == "user" ]] && runner=(sc_user)

  case "${action}" in
    enable)
      # Try persistent path first; on failure try transient.
      "${runner[@]}" daemon-reload >/dev/null 2>&1 || true
      if "${runner[@]}" enable --now "${TIMER_NAME}" >/dev/null 2>&1 \
         && "${runner[@]}" is-active "${TIMER_NAME}" >/dev/null 2>&1; then
        log_ok "enabled and started ${TIMER_NAME} (persistent, scope=${backend})"
      elif [[ "${backend}" == "user" ]] && start_transient_timer; then
        : # start_transient_timer logs the success
      else
        log_warn "failed to enable ${TIMER_NAME} (scope=${backend})"
      fi
      ;;
    disable)
      # Stop transient first (so its restart doesn't resurrect things),
      # then disable persistent.
      if [[ "${backend}" == "user" ]]; then
        stop_transient_timer
      fi
      if "${runner[@]}" disable --now "${TIMER_NAME}" >/dev/null 2>&1; then
        log_ok "disabled ${TIMER_NAME} (persistent, scope=${backend})"
      else
        log_warn "failed to disable ${TIMER_NAME} (scope=${backend})"
      fi
      ;;
    start)
      # Try the live service; for transient, also kick a one-shot run.
      if "${runner[@]}" start "${SERVICE_NAME}" >/dev/null 2>&1; then
        log_ok "started ${SERVICE_NAME} (persistent, scope=${backend})"
      elif [[ "${backend}" == "user" ]] && transient_unit_active "${SERVICE_BASENAME}"; then
        if systemd_run_user --quiet start "${SERVICE_BASENAME}.service" 2>/dev/null; then
          log_ok "started ${SERVICE_BASENAME}.service (transient, scope=user)"
        else
          log_warn "failed to start transient ${SERVICE_BASENAME}.service"
        fi
      else
        log_warn "failed to start ${SERVICE_NAME} (scope=${backend}); applying patch directly as fallback"
        run_patch_now
      fi
      ;;
    stop)
      if [[ "${backend}" == "user" ]]; then
        stop_transient_timer
      fi
      if "${runner[@]}" stop "${TIMER_NAME}" "${SERVICE_NAME}" >/dev/null 2>&1; then
        log_ok "stopped units (persistent, scope=${backend})"
      else
        log_warn "failed to stop units (scope=${backend})"
      fi
      ;;
    restart)
      "${runner[@]}" restart "${TIMER_NAME}" >/dev/null 2>&1 || true
      if "${runner[@]}" start "${SERVICE_NAME}" >/dev/null 2>&1; then
        log_ok "restarted timer and re-ran service (persistent, scope=${backend})"
      elif [[ "${backend}" == "user" ]] && transient_unit_active "${SERVICE_BASENAME}"; then
        if systemd_run_user --quiet start "${SERVICE_BASENAME}.service" 2>/dev/null; then
          log_ok "re-ran ${SERVICE_BASENAME}.service (transient, scope=user)"
        else
          log_warn "failed to restart transient service (scope=user)"
        fi
      else
        log_warn "failed to restart units (scope=${backend}); applying patch directly as fallback"
        run_patch_now
      fi
      ;;
    *)
      log_err "unsupported action: ${action}"
      return 2
      ;;
  esac
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
COMMAND="${1:-install}"
MODE="${2:-${MODE:-auto}}"

case "${COMMAND}" in
  install)              do_install "${MODE}" ;;
  uninstall)            do_uninstall ;;
  status)               do_status "${MODE}" ;;
  svc-status)           do_svc_status "${MODE}" ;;
  enable)               service_control enable "${MODE}" ;;
  disable)              service_control disable "${MODE}" ;;
  start)                service_control start "${MODE}" ;;
  stop)                 service_control stop "${MODE}" ;;
  restart)              service_control restart "${MODE}" ;;
  *)
    echo "Usage: $0 [install|uninstall|status|svc-status|enable|disable|start|stop|restart] [auto|system|user|shell]"
    echo "       or: MODE=auto|system|user|shell $0 <command>"
    exit 2
    ;;
esac
