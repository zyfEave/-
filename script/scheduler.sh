#!/system/bin/sh

SCRIPT_DIR=$(cd "${0%/*}" 2>/dev/null && pwd)
. "$SCRIPT_DIR/common.sh"

ensure_dirs

if ! mkdir "$SCHEDULER_LOCK_DIR" 2>/dev/null; then
  if scheduler_is_running; then
    log_msg "INFO" "scheduler already running"
    exit 0
  fi

  rmdir "$SCHEDULER_LOCK_DIR" 2>/dev/null
  mkdir "$SCHEDULER_LOCK_DIR" 2>/dev/null || exit 1
fi

echo $$ > "$PID_FILE"

WAKE_LOCK_HELD=0
WAKE_LOCK_WARNED=0

ensure_scheduler_wake_lock() {
  if [ "$WAKE_LOCK_HELD" = "1" ]; then
    return
  fi

  if acquire_wake_lock; then
    WAKE_LOCK_HELD=1
    WAKE_LOCK_WARNED=0
    log_msg "INFO" "scheduler wake lock acquired; screen-off timing can continue"
  elif [ "$WAKE_LOCK_WARNED" != "1" ]; then
    WAKE_LOCK_WARNED=1
    log_msg "WARN" "scheduler wake lock unavailable; screen-off schedules may be delayed by deep sleep"
  fi
}

release_scheduler_wake_lock() {
  if [ "$WAKE_LOCK_HELD" = "1" ]; then
    if release_wake_lock; then
      log_msg "INFO" "scheduler wake lock released"
    else
      log_msg "WARN" "scheduler wake lock release failed"
    fi
  fi

  WAKE_LOCK_HELD=0
}

cleanup_scheduler() {
  release_scheduler_wake_lock
  rm -f "$PID_FILE"
  rmdir "$SCHEDULER_LOCK_DIR" 2>/dev/null
}
trap cleanup_scheduler EXIT INT TERM

log_msg "INFO" "scheduler started"

run_interval_schedule() {
  _now_epoch=$(date +%s)
  _last_epoch=$(read_state_value last_interval_epoch)
  case "$_last_epoch" in
    ''|*[!0-9]*)
      write_state_value last_interval_epoch "$_now_epoch"
      return
      ;;
  esac

  _period=$((INTERVAL_MINUTES * 60))
  _elapsed=$((_now_epoch - _last_epoch))

  if [ "$_elapsed" -ge "$_period" ]; then
    write_state_value last_interval_epoch "$_now_epoch"
    sh "$MODDIR/script/run_task.sh" scheduler-interval 0
  fi
}

prune_daily_runs() {
  _today=$1
  _runs_file="$STATE_DIR/daily_runs.txt"

  if [ -f "$_runs_file" ]; then
    grep "^$_today " "$_runs_file" > "$_runs_file.tmp" 2>/dev/null || true
    mv "$_runs_file.tmp" "$_runs_file"
  fi
}

daily_already_ran() {
  _key=$1
  _runs_file="$STATE_DIR/daily_runs.txt"
  [ -f "$_runs_file" ] && grep -qx "$_key" "$_runs_file" 2>/dev/null
}

mark_daily_ran() {
  _key=$1
  echo "$_key" >> "$STATE_DIR/daily_runs.txt"
}

run_daily_schedule() {
  _today=$(date +%F)
  _time_now=$(date +%H:%M)
  prune_daily_runs "$_today"

  for _time_item in $(echo "$DAILY_TIMES" | tr ',' ' '); do
    if [ "$_time_item" = "$_time_now" ]; then
      _key="$_today $_time_item"
      if ! daily_already_ran "$_key"; then
        mark_daily_ran "$_key"
        sh "$MODDIR/script/run_task.sh" "scheduler-daily-$_time_item" 0
      fi
    fi
  done
}

while ! is_module_disabled; do
  load_config

  if [ "$AUTO_ENABLED" = "1" ]; then
    ensure_scheduler_wake_lock
    case "$SCHEDULE_MODE" in
      daily) run_daily_schedule ;;
      *) run_interval_schedule ;;
    esac
  else
    release_scheduler_wake_lock
  fi

  sleep 60
done

log_msg "INFO" "scheduler stopped because module is disabled"
