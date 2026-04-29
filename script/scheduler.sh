#!/system/bin/sh

SCRIPT_DIR=$(cd "${0%/*}" 2>/dev/null && pwd)
. "$SCRIPT_DIR/common.sh"

CMD=${1:-start}

write_schedule_file() {
  ensure_dirs
  load_config
  : > "$SCHEDULE_FILE"

  if [ "$AUTO_ENABLED" != "1" ]; then
    log_msg "INFO" "自动定时未开启，不生成定时表"
    return 1
  fi

  case "$SCHEDULE_MODE" in
    daily)
      for _time_item in $(echo "$DAILY_TIMES" | tr ',' ' '); do
        echo "daily|$_time_item|scheduler-daily-$_time_item" >> "$SCHEDULE_FILE"
      done
      ;;
    *)
      echo "interval|$INTERVAL_MINUTES|scheduler-interval" >> "$SCHEDULE_FILE"
      ;;
  esac

  if [ ! -s "$SCHEDULE_FILE" ]; then
    log_msg "WARN" "定时表为空，调度器不会启动"
    return 1
  fi

  log_msg "INFO" "定时表已生成：$SCHEDULE_FILE"
  return 0
}

stop_scheduler_process() {
  ensure_dirs

  if scheduler_is_running; then
    _pid=$(sed -n '1p' "$PID_FILE" 2>/dev/null)
    kill "$_pid" 2>/dev/null
    sleep 1
    if kill -0 "$_pid" 2>/dev/null; then
      kill -9 "$_pid" 2>/dev/null
    fi
    log_msg "INFO" "定时器已停止：pid=$_pid"
  fi

  if [ "$(read_state_value scheduler_wake_lock)" = "1" ]; then
    if release_wake_lock; then
      log_msg "INFO" "定时器唤醒锁已释放"
    else
      log_msg "WARN" "定时器唤醒锁释放失败"
    fi
    rm -f "$STATE_DIR/scheduler_wake_lock"
  fi

  rm -f "$PID_FILE"
  rmdir "$SCHEDULER_LOCK_DIR" 2>/dev/null
}

start_native_scheduler() {
  if [ ! -f "$TIMER_BIN" ]; then
    return 1
  fi

  chmod 0755 "$TIMER_BIN" 2>/dev/null
  if [ ! -x "$TIMER_BIN" ]; then
    log_msg "WARN" "native定时器不可执行：$TIMER_BIN"
    return 1
  fi

  nohup "$TIMER_BIN" "$MODDIR" "$DATA_DIR" "$SCHEDULE_FILE" "$LOG_FILE" >/dev/null 2>&1 &
  _pid=$!
  echo "$_pid" > "$PID_FILE"
  sleep 1
  if ! kill -0 "$_pid" 2>/dev/null; then
    rm -f "$PID_FILE"
    log_msg "WARN" "native定时器启动后立即退出，切换到shell兜底：$TIMER_BIN"
    return 1
  fi

  if acquire_wake_lock; then
    write_state_value scheduler_wake_lock 1
    log_msg "INFO" "native定时器已持有唤醒锁，息屏定时将按稳定优先运行"
  else
    log_msg "WARN" "native定时器唤醒锁不可用，息屏深睡时仍可能延迟"
  fi

  log_msg "INFO" "native低开销定时器已启动：pid=$_pid"
  return 0
}

start_fallback_scheduler() {
  nohup sh "$MODDIR/script/scheduler.sh" fallback-loop >/dev/null 2>&1 &
  _pid=$!
  echo "$_pid" > "$PID_FILE"
  log_msg "WARN" "已启用shell兜底定时：pid=$_pid"
  return 0
}

start_scheduler() {
  ensure_dirs

  if is_module_disabled; then
    log_msg "INFO" "模块已停用，定时器不会启动"
    return 0
  fi

  load_config
  if [ "$AUTO_ENABLED" != "1" ]; then
    log_msg "INFO" "自动定时未开启，定时器不会启动"
    return 0
  fi

  if scheduler_is_running; then
    log_msg "INFO" "定时器已在运行"
    return 0
  fi

  if ! mkdir "$SCHEDULER_LOCK_DIR" 2>/dev/null; then
    if scheduler_is_running; then
      log_msg "INFO" "定时器已在运行"
      return 0
    fi
    rmdir "$SCHEDULER_LOCK_DIR" 2>/dev/null
    if ! mkdir "$SCHEDULER_LOCK_DIR" 2>/dev/null; then
      log_msg "WARN" "定时器启动锁被占用，跳过本次启动"
      return 0
    fi
  fi

  if scheduler_is_running; then
    log_msg "INFO" "定时器已在运行"
    rmdir "$SCHEDULER_LOCK_DIR" 2>/dev/null
    return 0
  fi

  rm -f "$STATE_DIR/scheduler_wake_lock"

  if ! write_schedule_file; then
    rmdir "$SCHEDULER_LOCK_DIR" 2>/dev/null
    return 0
  fi

  if start_native_scheduler; then
    return 0
  fi

  start_fallback_scheduler
}

reload_scheduler_process() {
  stop_scheduler_process
  start_scheduler
}

run_interval_fallback() {
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

run_daily_fallback() {
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

fallback_loop() {
  log_msg "WARN" "shell兜底定时循环已启动，建议编译并放入bin/autofire_timed以降低开销"
  write_state_value last_interval_epoch "$(date +%s)"

  WAKE_LOCK_HELD=0
  WAKE_LOCK_WARNED=0

  while ! is_module_disabled; do
    load_config

    if [ "$AUTO_ENABLED" != "1" ]; then
      log_msg "INFO" "自动定时已关闭，shell兜底定时退出"
      break
    fi

    if [ "$WAKE_LOCK_HELD" != "1" ]; then
      if acquire_wake_lock; then
        WAKE_LOCK_HELD=1
        write_state_value scheduler_wake_lock 1
        log_msg "INFO" "shell兜底定时已持有唤醒锁"
      elif [ "$WAKE_LOCK_WARNED" != "1" ]; then
        WAKE_LOCK_WARNED=1
        log_msg "WARN" "唤醒锁不可用，息屏深睡时定时可能延迟"
      fi
    fi

    case "$SCHEDULE_MODE" in
      daily) run_daily_fallback ;;
      *) run_interval_fallback ;;
    esac

    sleep 60
  done

  if [ "$WAKE_LOCK_HELD" = "1" ]; then
    release_wake_lock >/dev/null 2>&1
    rm -f "$STATE_DIR/scheduler_wake_lock"
    log_msg "INFO" "shell兜底定时已释放唤醒锁"
  fi

  rm -f "$PID_FILE"
  rmdir "$SCHEDULER_LOCK_DIR" 2>/dev/null
}

case "$CMD" in
  start)
    start_scheduler
    ;;
  stop)
    stop_scheduler_process
    ;;
  reload|restart)
    reload_scheduler_process
    ;;
  status)
    if scheduler_is_running; then
      echo "running $(sed -n '1p' "$PID_FILE" 2>/dev/null)"
    else
      echo "stopped"
    fi
    ;;
  fallback-loop)
    fallback_loop
    ;;
  *)
    echo "usage: $0 start|stop|reload|restart|status"
    exit 1
    ;;
esac
