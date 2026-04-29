#!/system/bin/sh

SCRIPT_DIR=$(cd "${0%/*}" 2>/dev/null && pwd)
. "$SCRIPT_DIR/common.sh"

print_config_json() {
  load_config

  _last_run=$(json_escape "$(read_state_value last_run)")
  _last_result=$(json_escape "$(read_state_value last_result)")
  _last_source=$(json_escape "$(read_state_value last_source)")
  _daily_times=$(json_escape "$DAILY_TIMES")
  _schedule_mode=$(json_escape "$SCHEDULE_MODE")
  _log_path=$(json_escape "$LOG_FILE")

  printf '{'
  printf '"enable_wechat":%s,' "$(json_bool "$ENABLE_WECHAT")"
  printf '"enable_douyin":%s,' "$(json_bool "$ENABLE_DOUYIN")"
  printf '"auto_enabled":%s,' "$(json_bool "$AUTO_ENABLED")"
  printf '"schedule_mode":"%s",' "$_schedule_mode"
  printf '"interval_minutes":%s,' "$INTERVAL_MINUTES"
  printf '"daily_times":"%s",' "$_daily_times"
  printf '"app_settle_seconds":%s,' "$APP_SETTLE_SECONDS"
  printf '"last_run":"%s",' "$_last_run"
  printf '"last_result":"%s",' "$_last_result"
  printf '"last_source":"%s",' "$_last_source"
  printf '"log_path":"%s"' "$_log_path"
  printf '}\n'
}

apply_scheduler_after_config_change() {
  if [ "$AUTO_ENABLED" = "1" ]; then
    if reload_scheduler; then
      log_msg "INFO" "配置已保存，定时器已重新加载"
    else
      log_msg "WARN" "配置已保存，但定时器重新加载失败"
    fi
  else
    if stop_scheduler; then
      log_msg "INFO" "配置已保存，自动定时已关闭并停止定时器"
    else
      log_msg "WARN" "配置已保存，但停止定时器失败"
    fi
  fi
}

save_config_from_args() {
  load_config

  while [ $# -gt 0 ]; do
    case "$1" in
      enable_wechat=*) ENABLE_WECHAT=${1#*=} ;;
      enable_douyin=*) ENABLE_DOUYIN=${1#*=} ;;
      auto_enabled=*) AUTO_ENABLED=${1#*=} ;;
      schedule_mode=*) SCHEDULE_MODE=${1#*=} ;;
      interval_minutes=*) INTERVAL_MINUTES=${1#*=} ;;
      daily_times=*) DAILY_TIMES=${1#*=} ;;
      app_settle_seconds=*) APP_SETTLE_SECONDS=${1#*=} ;;
    esac
    shift
  done

  write_config
  apply_scheduler_after_config_change
  print_config_json
}

print_log() {
  ensure_dirs
  _lines=$1
  case "$_lines" in
    ''|*[!0-9]*) _lines=160 ;;
  esac

  if [ -f "$LOG_FILE" ]; then
    tail -n "$_lines" "$LOG_FILE"
  fi
}

clear_log() {
  ensure_dirs
  : > "$LOG_FILE"
}

print_doctor_json() {
  ensure_dirs

  _log_writable=0
  if touch "$LOG_FILE" 2>/dev/null; then
    _log_writable=1
  fi

  _scheduler_running=0
  _scheduler_pid=$(sed -n '1p' "$NATIVE_PID_FILE" 2>/dev/null)
  case "$_scheduler_pid" in
    ''|*[!0-9]*) _scheduler_pid="" ;;
  esac
  if scheduler_is_running; then
    _scheduler_running=1
  fi

  _supervisor_running=0
  _supervisor_pid=$(sed -n '1p' "$SUPERVISOR_PID_FILE" 2>/dev/null)
  case "$_supervisor_pid" in
    ''|*[!0-9]*) _supervisor_pid="" ;;
  esac
  if supervisor_is_running; then
    _supervisor_running=1
  fi

  _native_running=$_scheduler_running
  _native_pid=$_scheduler_pid
  _timer_exists=0
  _timer_executable=0
  [ -f "$TIMER_BIN" ] && _timer_exists=1
  [ -x "$TIMER_BIN" ] && _timer_executable=1

  _timer_version_output=""
  if [ "$_timer_executable" = "1" ]; then
    _timer_version_output=$("$TIMER_BIN" --version 2>&1 | tr '\n' ' ')
  fi

  _timer_version=$(read_state_value native_version)
  case "$_timer_version_output" in
    *version=*) _timer_version=$(printf '%s' "$_timer_version_output" | sed 's/.*version=\([^ ]*\).*/\1/') ;;
  esac
  _timer_arch=""
  case "$_timer_version_output" in
    *arch=*) _timer_arch=$(printf '%s' "$_timer_version_output" | sed 's/.*arch=\([^ ]*\).*/\1/') ;;
  esac

  _module_path=$(json_escape "$MODDIR")
  _data_path=$(json_escape "$DATA_DIR")
  _config_path=$(json_escape "$CONFIG_FILE")
  _log_path=$(json_escape "$LOG_FILE")
  _state_path=$(json_escape "$STATE_DIR")
  _schedule_path=$(json_escape "$SCHEDULE_FILE")
  _timer_path=$(json_escape "$TIMER_BIN")
  _scheduler_pid_json=$(json_escape "$_scheduler_pid")
  _supervisor_pid_json=$(json_escape "$_supervisor_pid")
  _native_pid_json=$(json_escape "$_native_pid")
  _script_path=$(json_escape "$SCRIPT_DIR/config.sh")
  _id_output=$(json_escape "$(id 2>&1 | tr '\n' ' ')")
  _sh_path=$(json_escape "$(command -v sh 2>&1 | tr '\n' ' ')")
  _selected_clock=$(json_escape "$(read_state_value selected_clock)")
  _wake_capable=$(read_state_value wake_capable)
  _suspend_aware=$(read_state_value suspend_aware)
  _active_workers=$(read_state_value active_workers)
  _pending_workers=$(read_state_value ready_workers)
  _last_drift_ms=$(read_state_value last_drift_ms)
  _last_worker_exit=$(json_escape "$(read_state_value last_worker_exit)")
  _native_version=$(json_escape "$(read_state_value native_version)")
  _timer_version_json=$(json_escape "$_timer_version")
  _timer_arch_json=$(json_escape "$_timer_arch")
  _wake_lock_held=0
  if [ "$(read_state_value scheduler_wake_lock)" = "1" ] || [ "$(read_state_value task_wake_lock)" = "1" ]; then
    _wake_lock_held=1
  fi
  case "$_active_workers" in ''|*[!0-9]*) _active_workers=0 ;; esac
  case "$_pending_workers" in ''|*[!0-9]*) _pending_workers=0 ;; esac
  case "$_last_drift_ms" in ''|*[!0-9-]*) _last_drift_ms=0 ;; esac

  printf '{'
  printf '"module_path":"%s",' "$_module_path"
  printf '"data_path":"%s",' "$_data_path"
  printf '"config_path":"%s",' "$_config_path"
  printf '"log_path":"%s",' "$_log_path"
  printf '"state_path":"%s",' "$_state_path"
  printf '"schedule_path":"%s",' "$_schedule_path"
  printf '"timer_path":"%s",' "$_timer_path"
  printf '"script_path":"%s",' "$_script_path"
  printf '"script_exists":%s,' "$(json_bool "$([ -f "$SCRIPT_DIR/config.sh" ] && echo 1 || echo 0)")"
  printf '"config_exists":%s,' "$(json_bool "$([ -f "$CONFIG_FILE" ] && echo 1 || echo 0)")"
  printf '"log_writable":%s,' "$(json_bool "$_log_writable")"
  printf '"timer_exists":%s,' "$(json_bool "$_timer_exists")"
  printf '"timer_executable":%s,' "$(json_bool "$_timer_executable")"
  printf '"scheduler_running":%s,' "$(json_bool "$_scheduler_running")"
  printf '"native_running":%s,' "$(json_bool "$_native_running")"
  printf '"supervisor_running":%s,' "$(json_bool "$_supervisor_running")"
  printf '"scheduler_pid":"%s",' "$_scheduler_pid_json"
  printf '"native_pid":"%s",' "$_native_pid_json"
  printf '"supervisor_pid":"%s",' "$_supervisor_pid_json"
  printf '"native_version":"%s",' "$_native_version"
  printf '"timer_version":"%s",' "$_timer_version_json"
  printf '"timer_arch":"%s",' "$_timer_arch_json"
  printf '"selected_clock":"%s",' "$_selected_clock"
  printf '"wake_capable":%s,' "$(json_bool "$_wake_capable")"
  printf '"suspend_aware":%s,' "$(json_bool "$_suspend_aware")"
  printf '"active_workers":%s,' "$_active_workers"
  printf '"pending_workers":%s,' "$_pending_workers"
  printf '"last_drift_ms":%s,' "$_last_drift_ms"
  printf '"last_worker_exit":"%s",' "$_last_worker_exit"
  printf '"wake_lock_held":%s,' "$(json_bool "$_wake_lock_held")"
  printf '"id":"%s",' "$_id_output"
  printf '"sh":"%s"' "$_sh_path"
  printf '}\n'
}

case "$1" in
  get-json)
    print_config_json
    ;;
  save)
    shift
    save_config_from_args "$@"
    ;;
  log)
    print_log "$2"
    ;;
  clear-log)
    clear_log
    ;;
  doctor)
    print_doctor_json
    ;;
  defaults)
    write_default_config
    apply_scheduler_after_config_change
    log_msg "INFO" "配置已恢复默认"
    print_config_json
    ;;
  *)
    echo "usage: $0 get-json|save|log|clear-log|doctor|defaults"
    exit 1
    ;;
esac
