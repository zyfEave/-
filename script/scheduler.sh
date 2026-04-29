#!/system/bin/sh

SCRIPT_DIR=$(cd "${0%/*}" 2>/dev/null && pwd)
. "$SCRIPT_DIR/common.sh"

CMD=${1:-start}

write_schedule_file() {
  ensure_dirs
  load_config
  _tmp_schedule="$SCHEDULE_FILE.tmp.$$"
  rm -f "$_tmp_schedule"
  : > "$_tmp_schedule"

  if [ "$AUTO_ENABLED" != "1" ]; then
    log_msg "INFO" "自动定时未开启，不生成定时表"
    rm -f "$_tmp_schedule"
    return 1
  fi

  case "$SCHEDULE_MODE" in
    daily)
      for _time_item in $(echo "$DAILY_TIMES" | tr ',' ' '); do
        echo "daily|$_time_item|scheduler-daily-$_time_item" >> "$_tmp_schedule"
      done
      ;;
    *)
      echo "interval|$INTERVAL_MINUTES|scheduler-interval" >> "$_tmp_schedule"
      ;;
  esac

  if [ ! -s "$_tmp_schedule" ]; then
    log_msg "WARN" "定时表为空，调度器不会启动"
    rm -f "$_tmp_schedule"
    return 1
  fi

  if mv "$_tmp_schedule" "$SCHEDULE_FILE" 2>/dev/null; then
    log_msg "INFO" "定时表已原子生成：$SCHEDULE_FILE"
  else
    log_msg "ERROR" "定时表原子替换失败：$SCHEDULE_FILE"
    rm -f "$_tmp_schedule"
    return 1
  fi

  return 0
}

stop_scheduler_process() {
  ensure_dirs

  touch "$SUPERVISOR_STOP_FILE" 2>/dev/null

  if scheduler_is_running; then
    _pid=$(sed -n '1p' "$NATIVE_PID_FILE" 2>/dev/null)
    kill "$_pid" 2>/dev/null
    if ! wait_pid_gone "$_pid" 5; then
      kill -9 "$_pid" 2>/dev/null
      wait_pid_gone "$_pid" 3 >/dev/null 2>&1
    fi
    log_msg "INFO" "定时器已停止：pid=$_pid"
  fi

  if supervisor_is_running; then
    _supervisor_pid=$(sed -n '1p' "$SUPERVISOR_PID_FILE" 2>/dev/null)
    kill "$_supervisor_pid" 2>/dev/null
    if ! wait_pid_gone "$_supervisor_pid" 5; then
      kill -9 "$_supervisor_pid" 2>/dev/null
      wait_pid_gone "$_supervisor_pid" 3 >/dev/null 2>&1
    fi
    log_msg "INFO" "supervisor已停止：pid=$_supervisor_pid"
  fi

  if [ "$(read_state_value scheduler_wake_lock)" = "1" ]; then
    if release_wake_lock; then
      log_msg "INFO" "定时器唤醒锁已释放"
    else
      log_msg "WARN" "定时器唤醒锁释放失败"
    fi
    rm -f "$STATE_DIR/scheduler_wake_lock"
  fi

  release_wake_lock xiaoxiang_dispatch_wake_lock >/dev/null 2>&1
  release_wake_lock xiaoxiang_task_wake_lock >/dev/null 2>&1

  rm -f "$PID_FILE" "$NATIVE_PID_FILE" "$SUPERVISOR_PID_FILE" "$SUPERVISOR_STOP_FILE"
  rmdir "$SCHEDULER_LOCK_DIR" 2>/dev/null
  rmdir "$SUPERVISOR_LOCK_DIR" 2>/dev/null
}

start_supervisor() {
  if [ ! -f "$TIMER_BIN" ]; then
    return 1
  fi

  chmod 0755 "$TIMER_BIN" 2>/dev/null
  if [ ! -x "$TIMER_BIN" ]; then
    log_msg "WARN" "native定时器不可执行：$TIMER_BIN"
    return 1
  fi

  _timer_version=$("$TIMER_BIN" --version 2>&1)
  case "$_timer_version" in
    *timerfd_epoll_eventfd_heap*)
      log_msg "INFO" "native定时器版本验证通过：$_timer_version"
      ;;
    *)
      log_msg "ERROR" "native定时器版本验证失败，疑似旧二进制：$TIMER_BIN output=$_timer_version"
      return 1
      ;;
  esac

  if [ ! -f "$MODDIR/script/supervisor.sh" ]; then
    log_msg "ERROR" "supervisor脚本不存在：$MODDIR/script/supervisor.sh"
    return 1
  fi
  chmod 0755 "$MODDIR/script/supervisor.sh" 2>/dev/null

  if supervisor_is_running; then
    log_msg "INFO" "supervisor已在运行：pid=$(sed -n '1p' "$SUPERVISOR_PID_FILE" 2>/dev/null)"
    return 0
  fi

  rm -f "$SUPERVISOR_PID_FILE"
  rmdir "$SUPERVISOR_LOCK_DIR" 2>/dev/null

  rm -f "$SUPERVISOR_STOP_FILE"
  nohup sh "$MODDIR/script/supervisor.sh" >/dev/null 2>&1 &
  _pid=$!
  echo "$_pid" > "$SUPERVISOR_PID_FILE"
  sleep 1
  if ! kill -0 "$_pid" 2>/dev/null; then
    rm -f "$SUPERVISOR_PID_FILE"
    log_msg "ERROR" "supervisor启动后立即退出"
    return 1
  fi

  log_msg "INFO" "supervisor已启动：pid=$_pid；native空闲时不长期持有唤醒锁，任务执行时短暂申请"
  return 0
}

start_fallback_scheduler() {
  log_msg "ERROR" "native定时器不可用，已禁用shell sleep轮询兜底；请重新编译或恢复$TIMER_BIN"
  return 1
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

  if start_supervisor; then
    return 0
  fi

  start_fallback_scheduler
  return $?
}

reload_scheduler_process() {
  ensure_dirs
  load_config

  if [ "$AUTO_ENABLED" != "1" ]; then
    stop_scheduler_process
    return 0
  fi

  if scheduler_is_running; then
    log_msg "INFO" "开始热重载native定时器"
    if write_schedule_file; then
      _pid=$(sed -n '1p' "$NATIVE_PID_FILE" 2>/dev/null)
      if kill -HUP "$_pid" 2>/dev/null; then
        log_msg "INFO" "已通过SIGHUP通知native定时器热重载：pid=$_pid"
        return 0
      fi
      log_msg "WARN" "native定时器热重载信号发送失败，将重启调度器：pid=$_pid"
    else
      stop_scheduler_process
      return 0
    fi
  fi

  if supervisor_is_running; then
    log_msg "INFO" "native暂未运行但supervisor存在，等待supervisor拉起"
    return 0
  fi

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
  log_msg "ERROR" "shell sleep轮询兜底已禁用；请使用native timerfd/epoll调度器"
  rm -f "$PID_FILE"
  rmdir "$SCHEDULER_LOCK_DIR" 2>/dev/null
  return 1
}

case "$CMD" in
  start)
    start_scheduler
    ;;
  stop)
    stop_scheduler_process
    ;;
  reload)
    reload_scheduler_process
    ;;
  restart)
    stop_scheduler_process
    start_scheduler
    ;;
  status)
    if supervisor_is_running || scheduler_is_running; then
      echo "running supervisor=$(sed -n '1p' "$SUPERVISOR_PID_FILE" 2>/dev/null) supervisorState=$(read_state_value supervisor_state) native=$(sed -n '1p' "$NATIVE_PID_FILE" 2>/dev/null) active_workers=$(read_state_value active_workers) ready_workers=$(read_state_value ready_workers) workerPolicy=$(read_state_value worker_policy) selectedClock=$(read_state_value selected_clock) wakeCapable=$(read_state_value wake_capable) suspendAware=$(read_state_value suspend_aware) lastDriftMs=$(read_state_value last_drift_ms) lastWorkerExit=$(read_state_value last_worker_exit)"
    elif [ -f "$SUPERVISOR_STOP_FILE" ]; then
      echo "stopped stop_marker=1"
    else
      echo "stopped supervisorState=$(read_state_value supervisor_state)"
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
