#!/system/bin/sh

SCRIPT_DIR=$(cd "${0%/*}" 2>/dev/null && pwd)
. "$SCRIPT_DIR/common.sh"

MAX_CRASHES=${SUPERVISOR_MAX_CRASHES:-5}
CRASH_WINDOW_SECONDS=${SUPERVISOR_CRASH_WINDOW_SECONDS:-600}
BACKOFF_INDEX=0
CRASH_COUNT=0
WINDOW_START=$(date +%s)
CURRENT_NATIVE_PID=""
LOCK_HELD=0

backoff_seconds() {
  case "$1" in
    0) echo 5 ;;
    1) echo 10 ;;
    2) echo 30 ;;
    3) echo 60 ;;
    *) echo 300 ;;
  esac
}

cleanup_supervisor() {
  if [ -n "$CURRENT_NATIVE_PID" ] && kill -0 "$CURRENT_NATIVE_PID" 2>/dev/null; then
    kill "$CURRENT_NATIVE_PID" 2>/dev/null
  fi
  if [ "$LOCK_HELD" = "1" ]; then
    rm -f "$SUPERVISOR_PID_FILE"
    rmdir "$SUPERVISOR_LOCK_DIR" 2>/dev/null
  fi
}

request_stop() {
  touch "$SUPERVISOR_STOP_FILE" 2>/dev/null
  cleanup_supervisor
  exit 0
}

trap cleanup_supervisor EXIT
trap request_stop INT TERM HUP

ensure_dirs

if ! mkdir "$SUPERVISOR_LOCK_DIR" 2>/dev/null; then
  if supervisor_is_running; then
    _existing_pid=$(sed -n '1p' "$SUPERVISOR_PID_FILE" 2>/dev/null)
    log_msg "INFO" "supervisor已在运行，跳过重复启动：pid=$_existing_pid"
    exit 0
  fi
  log_msg "WARN" "supervisor锁残留，清理stale lock"
  rm -f "$SUPERVISOR_PID_FILE"
  rmdir "$SUPERVISOR_LOCK_DIR" 2>/dev/null
  if ! mkdir "$SUPERVISOR_LOCK_DIR" 2>/dev/null; then
    log_msg "WARN" "supervisor锁被占用，无法启动"
    exit 1
  fi
fi
LOCK_HELD=1

echo "$$" > "$SUPERVISOR_PID_FILE"
rm -f "$SUPERVISOR_STOP_FILE"
write_state_value supervisor_state running
log_msg "INFO" "supervisor已进入守护循环：pid=$$"

while [ ! -f "$SUPERVISOR_STOP_FILE" ] && ! is_module_disabled; do
  if [ ! -x "$TIMER_BIN" ]; then
    write_state_value supervisor_state native_not_executable
    log_msg "ERROR" "native定时器不可执行，supervisor退出：$TIMER_BIN"
    break
  fi

  _timer_version=$("$TIMER_BIN" --version 2>&1)
  case "$_timer_version" in
    *timerfd_epoll_eventfd_heap*) ;;
    *)
      write_state_value supervisor_state old_or_invalid_binary
      log_msg "ERROR" "native定时器版本验证失败，supervisor不启动旧二进制：$TIMER_BIN output=$_timer_version"
      break
      ;;
  esac

  "$TIMER_BIN" "$MODDIR" "$DATA_DIR" "$SCHEDULE_FILE" "$LOG_FILE" &
  CURRENT_NATIVE_PID=$!
  echo "$CURRENT_NATIVE_PID" > "$NATIVE_PID_FILE"
  log_msg "INFO" "supervisor已启动native：pid=$CURRENT_NATIVE_PID"

  wait "$CURRENT_NATIVE_PID"
  _rc=$?
  rm -f "$NATIVE_PID_FILE"
  CURRENT_NATIVE_PID=""

  if [ -f "$SUPERVISOR_STOP_FILE" ] || is_module_disabled; then
    write_state_value supervisor_state stopped_by_marker
    log_msg "INFO" "supervisor收到停止标记，native退出码=$_rc，不再重启"
    break
  fi

  _now=$(date +%s)
  _window_elapsed=$((_now - WINDOW_START))
  if [ "$_window_elapsed" -gt "$CRASH_WINDOW_SECONDS" ]; then
    WINDOW_START=$_now
    CRASH_COUNT=0
    BACKOFF_INDEX=0
  fi

  CRASH_COUNT=$((CRASH_COUNT + 1))
  if [ "$CRASH_COUNT" -gt "$MAX_CRASHES" ]; then
    write_state_value supervisor_state crash_budget_exhausted
    log_msg "ERROR" "native短时间连续退出超过限制，停止重启：count=$CRASH_COUNT windowSeconds=$CRASH_WINDOW_SECONDS lastRc=$_rc"
    break
  fi

  _delay=$(backoff_seconds "$BACKOFF_INDEX")
  write_state_value supervisor_state "backoff_${_delay}s"
  if [ "$BACKOFF_INDEX" -lt 4 ]; then
    BACKOFF_INDEX=$((BACKOFF_INDEX + 1))
  fi

  if [ "$_rc" -gt 128 ]; then
    _sig=$((_rc - 128))
    log_msg "WARN" "native异常退出：rc=$_rc signal=$_sig，${_delay}秒后重启，crashCount=$CRASH_COUNT"
  else
    log_msg "WARN" "native退出：rc=$_rc，${_delay}秒后重启，crashCount=$CRASH_COUNT"
  fi

  sleep "$_delay"
done

rm -f "$NATIVE_PID_FILE" "$SUPERVISOR_PID_FILE"
rmdir "$SUPERVISOR_LOCK_DIR" 2>/dev/null
log_msg "INFO" "supervisor已退出"
