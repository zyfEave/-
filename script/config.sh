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
  log_msg "INFO" "configuration saved"
  start_scheduler_after_config_save
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

start_scheduler_after_config_save() {
  if [ "$AUTO_ENABLED" = "1" ]; then
    if start_scheduler_if_needed; then
      log_msg "INFO" "scheduler launch checked after configuration save"
    else
      log_msg "WARN" "scheduler launch failed after configuration save"
    fi
  fi
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
  defaults)
    write_default_config
    start_scheduler_after_config_save
    log_msg "INFO" "configuration reset to defaults"
    print_config_json
    ;;
  *)
    echo "usage: $0 get-json|save|log|clear-log|defaults"
    exit 1
    ;;
esac
