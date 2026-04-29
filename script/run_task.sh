#!/system/bin/sh

SCRIPT_DIR=$(cd "${0%/*}" 2>/dev/null && pwd)
. "$SCRIPT_DIR/common.sh"

SOURCE=${1:-manual}
DELAY_SECONDS=${2:-0}

case "$DELAY_SECONDS" in
  ''|*[!0-9]*) DELAY_SECONDS=0 ;;
esac

ensure_dirs
load_config

if is_module_disabled; then
  log_msg "INFO" "task skipped from $SOURCE because module is disabled"
  exit 0
fi

if ! mkdir "$RUN_LOCK_DIR" 2>/dev/null; then
  log_msg "WARN" "task skipped from $SOURCE because another run is active"
  exit 2
fi

cleanup_run_lock() {
  rmdir "$RUN_LOCK_DIR" 2>/dev/null
}
trap cleanup_run_lock EXIT INT TERM

turn_screen_off_logged() {
  _reason=$1
  log_msg "INFO" "screen off requested: $_reason"
  if sleep_device; then
    log_msg "INFO" "screen off command succeeded: $_reason"
  else
    log_msg "WARN" "screen off command failed: $_reason"
  fi
}

wake_screen_logged() {
  _reason=$1
  log_msg "INFO" "screen wake requested: $_reason"
  if wake_device; then
    log_msg "INFO" "screen wake command succeeded: $_reason"
  else
    log_msg "WARN" "screen wake command failed: $_reason"
  fi
}

home_logged() {
  _label=$1
  _reason=$2
  log_msg "INFO" "$_label close/return-home requested: $_reason"
  if home_device; then
    log_msg "INFO" "$_label close/return-home succeeded: $_reason"
  else
    log_msg "WARN" "$_label close/return-home failed: $_reason"
  fi
}

if [ "$DELAY_SECONDS" -gt 0 ]; then
  log_msg "INFO" "action task requested; waiting ${DELAY_SECONDS}s after screen off"
  turn_screen_off_logged "action-delay"
  sleep "$DELAY_SECONDS"
fi

log_msg "INFO" "task started from $SOURCE"
write_state_value last_source "$SOURCE"
write_state_value last_run "$(date +"%Y-%m-%d %H:%M:%S")"

wake_screen_logged "before-app-restart"
sleep 2

TARGET_COUNT=0
SUCCESS_COUNT=0
FAIL_COUNT=0

restart_package() {
  _label=$1
  _pkg=$2
  TARGET_COUNT=$((TARGET_COUNT + 1))

  log_msg "INFO" "$_label operation started ($_pkg)"

  if ! pm path "$_pkg" >/dev/null 2>&1; then
    log_msg "WARN" "$_label package not installed; skip kill/start/close ($_pkg)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return
  fi

  home_logged "$_label" "close foreground before force-stop"
  sleep 1

  log_msg "INFO" "$_label kill requested: am force-stop $_pkg"
  if am force-stop "$_pkg" >/dev/null 2>&1; then
    log_msg "INFO" "$_label kill succeeded: $_pkg"
  else
    log_msg "ERROR" "$_label kill failed: $_pkg"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return
  fi

  sleep 1

  log_msg "INFO" "$_label launch requested: monkey launcher intent $_pkg"
  if monkey -p "$_pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
    log_msg "INFO" "$_label launch command succeeded: $_pkg"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    log_msg "ERROR" "$_label launch command failed: $_pkg"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return
  fi

  _settle_seconds=$APP_SETTLE_SECONDS
  if [ "$_pkg" = "$DOUYIN_PKG" ] && [ "$SOURCE" = "action" ]; then
    _settle_seconds=60
    log_msg "INFO" "$_label action mode: keep Douyin foreground for 60s before returning home"
  fi

  log_msg "INFO" "$_label waiting ${_settle_seconds}s after launch"
  sleep "$_settle_seconds"

  home_logged "$_label" "close app to launcher after launch"
  sleep 1

  if [ "$_pkg" = "$DOUYIN_PKG" ]; then
    log_msg "INFO" "$_label final launcher return requested after Douyin launch"
    home_logged "$_label" "ensure phone main screen after Douyin"
    sleep 1
  fi

  log_msg "INFO" "$_label operation finished ($_pkg)"
}

if [ "$ENABLE_WECHAT" = "1" ]; then
  restart_package "WeChat" "$WECHAT_PKG"
else
  log_msg "INFO" "WeChat disabled by config; skip"
fi

if [ "$ENABLE_DOUYIN" = "1" ]; then
  restart_package "Douyin" "$DOUYIN_PKG"
else
  log_msg "INFO" "Douyin disabled by config; skip"
fi

home_logged "System" "final return to launcher"
sleep 1
turn_screen_off_logged "task-finished"

if [ "$TARGET_COUNT" -eq 0 ]; then
  RESULT="no enabled apps"
  log_msg "WARN" "task finished with no enabled apps"
elif [ "$FAIL_COUNT" -eq 0 ]; then
  RESULT="success: $SUCCESS_COUNT app(s)"
  log_msg "INFO" "task finished successfully; $SUCCESS_COUNT app(s) restarted"
else
  RESULT="partial: success=$SUCCESS_COUNT fail=$FAIL_COUNT"
  log_msg "WARN" "task finished with failures; success=$SUCCESS_COUNT fail=$FAIL_COUNT"
fi

write_state_value last_result "$RESULT"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
fi

exit 1
