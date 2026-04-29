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

if [ "$DELAY_SECONDS" -gt 0 ]; then
  log_msg "INFO" "action task requested; turning screen off and waiting ${DELAY_SECONDS}s"
  sleep_device
  sleep "$DELAY_SECONDS"
fi

log_msg "INFO" "task started from $SOURCE"
write_state_value last_source "$SOURCE"
write_state_value last_run "$(date +"%Y-%m-%d %H:%M:%S")"

wake_device
sleep 2

TARGET_COUNT=0
SUCCESS_COUNT=0
FAIL_COUNT=0

restart_package() {
  _label=$1
  _pkg=$2
  TARGET_COUNT=$((TARGET_COUNT + 1))

  log_msg "INFO" "processing $_label ($_pkg)"

  if ! pm path "$_pkg" >/dev/null 2>&1; then
    log_msg "WARN" "$_label is not installed; skipped"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return
  fi

  if am force-stop "$_pkg" >/dev/null 2>&1; then
    log_msg "INFO" "$_label force-stopped"
  else
    log_msg "ERROR" "$_label force-stop failed"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return
  fi

  sleep 1

  if monkey -p "$_pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
    log_msg "INFO" "$_label launch intent sent"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    log_msg "ERROR" "$_label launch failed"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  sleep "$APP_SETTLE_SECONDS"
  home_device
  sleep 1
}

if [ "$ENABLE_WECHAT" = "1" ]; then
  restart_package "WeChat" "$WECHAT_PKG"
fi

if [ "$ENABLE_DOUYIN" = "1" ]; then
  restart_package "Douyin" "$DOUYIN_PKG"
fi

home_device
sleep 1
sleep_device

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
