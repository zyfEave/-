#!/system/bin/sh

SCRIPT_DIR=$(cd "${0%/*}" 2>/dev/null && pwd)
if [ -z "$SCRIPT_DIR" ]; then
  SCRIPT_DIR=${0%/*}
fi

case "$SCRIPT_DIR" in
  */script) MODDIR=${MODDIR:-${SCRIPT_DIR%/script}} ;;
  *) MODDIR=${MODDIR:-$SCRIPT_DIR} ;;
esac

MODULE_ID="autofire-app-restarter"
WAKE_LOCK_NAME="${WAKE_LOCK_NAME:-autofire_scheduler}"
BOOT_GRACE_SECONDS="${BOOT_GRACE_SECONDS:-180}"

set_data_paths() {
  DATA_DIR=$1
  CONFIG_DIR="$DATA_DIR/config"
  LOG_DIR="$DATA_DIR/logs"
  STATE_DIR="$DATA_DIR/state"
  CONFIG_FILE="$CONFIG_DIR/autofire.conf"
  LOG_FILE="$LOG_DIR/autofire.log"
  STATE_FILE="$STATE_DIR/scheduler.state"
  RUN_DIR="$MODDIR/run"
  PID_FILE="$RUN_DIR/autofire_timed.pid"
  NATIVE_PID_FILE="$RUN_DIR/autofire_timed.pid"
  SUPERVISOR_PID_FILE="$RUN_DIR/autofire_supervisor.pid"
  SUPERVISOR_LOCK_DIR="$RUN_DIR/supervisor.lock"
  SUPERVISOR_STOP_FILE="$RUN_DIR/stop"
  SCHEDULE_FILE="$STATE_DIR/autofire.schedule"
  RUN_LOCK_DIR="$STATE_DIR/run.lock"
  SCHEDULER_LOCK_DIR="$STATE_DIR/scheduler.lock"
}

set_data_paths "${AUTOFIRE_DATA_DIR:-/data/adb/$MODULE_ID}"
MODULE_DATA_FALLBACK="$MODDIR/.data"
LEGACY_CONFIG_FILE="$MODDIR/config/autofire.conf"
LEGACY_LOG_FILE="$MODDIR/logs/autofire.log"
LEGACY_STATE_DIR="$MODDIR/state"
TIMER_BIN="$MODDIR/bin/autofire_timed"

select_timer_bin() {
  _abilist=$(getprop ro.product.cpu.abilist 2>/dev/null)
  case ",$_abilist," in
    *",arm64-v8a,"*)
      TIMER_BIN="$MODDIR/bin/autofire_timed"
      ;;
    *",armeabi-v7a,"*|*",armeabi,"*)
      if [ -f "$MODDIR/bin/autofire_timed_armeabi-v7a" ]; then
        TIMER_BIN="$MODDIR/bin/autofire_timed_armeabi-v7a"
      else
        TIMER_BIN="$MODDIR/bin/autofire_timed"
      fi
      ;;
    *)
      TIMER_BIN="$MODDIR/bin/autofire_timed"
      ;;
  esac
}

select_timer_bin

WECHAT_PKG="com.tencent.mm"
DOUYIN_PKG="com.ss.android.ugc.aweme"

ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$STATE_DIR" "$RUN_DIR" 2>/dev/null

  if ! touch "$LOG_FILE" 2>/dev/null; then
    set_data_paths "$MODULE_DATA_FALLBACK"
    mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$STATE_DIR" "$RUN_DIR" 2>/dev/null
    touch "$LOG_FILE" 2>/dev/null
  fi

  if [ -d "$LEGACY_STATE_DIR" ]; then
    for _state_item in last_run last_result last_source last_interval_epoch daily_runs.txt; do
      if [ ! -f "$STATE_DIR/$_state_item" ] && [ -f "$LEGACY_STATE_DIR/$_state_item" ]; then
        cp "$LEGACY_STATE_DIR/$_state_item" "$STATE_DIR/$_state_item" 2>/dev/null
      fi
    done
  fi
}

is_module_disabled() {
  [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/.disable" ] || [ -f "$MODDIR/remove" ]
}

normalize_bool() {
  _value=$1
  _default=$2
  case "$_value" in
    1|true|TRUE|on|ON|yes|YES) echo 1 ;;
    0|false|FALSE|off|OFF|no|NO) echo 0 ;;
    *) echo "$_default" ;;
  esac
}

normalize_mode() {
  case "$1" in
    interval) echo "interval" ;;
    *) echo "daily" ;;
  esac
}

normalize_positive_int() {
  _value=$1
  _default=$2
  _min=$3
  _max=$4

  case "$_value" in
    ''|*[!0-9]*) echo "$_default"; return ;;
  esac

  if [ "$_value" -lt "$_min" ]; then
    echo "$_min"
  elif [ "$_value" -gt "$_max" ]; then
    echo "$_max"
  else
    echo "$_value"
  fi
}

strip_leading_zero() {
  _number=$(echo "$1" | sed 's/^0*//')
  [ -z "$_number" ] && _number=0
  echo "$_number"
}

normalize_daily_times() {
  _raw=$1
  _out=""

  for _item in $(echo "$_raw" | sed 's/[，,;；|[:space:]][，,;；|[:space:]]*/ /g'); do
    case "$_item" in
      [0-9]:[0-5][0-9])
        _hour="0${_item%:*}"
        _minute=${_item#*:}
        ;;
      [0-2][0-9]:[0-5][0-9])
        _hour=${_item%:*}
        _minute=${_item#*:}
        ;;
      *)
        continue
        ;;
    esac

    _hour_num=$(strip_leading_zero "$_hour")
    if [ "$_hour_num" -gt 23 ]; then
      continue
    fi

    _time="$_hour:$_minute"
    case ",$_out," in
      *,"$_time",*) ;;
      *)
        if [ -z "$_out" ]; then
          _out="$_time"
        else
          _out="$_out,$_time"
        fi
        ;;
    esac
  done

  if [ -z "$_out" ]; then
    echo "03:00"
  else
    echo "$_out"
  fi
}

sanitize_config() {
  ENABLE_WECHAT=$(normalize_bool "$ENABLE_WECHAT" 1)
  ENABLE_DOUYIN=$(normalize_bool "$ENABLE_DOUYIN" 1)
  AUTO_ENABLED=$(normalize_bool "$AUTO_ENABLED" 0)
  SCHEDULE_MODE=$(normalize_mode "$SCHEDULE_MODE")
  INTERVAL_MINUTES=$(normalize_positive_int "$INTERVAL_MINUTES" 60 1 1440)
  DAILY_TIMES=$(normalize_daily_times "$DAILY_TIMES")
  APP_SETTLE_SECONDS=$(normalize_positive_int "$APP_SETTLE_SECONDS" 8 2 60)
}

write_config() {
  ensure_dirs
  sanitize_config
  _tmp_config="$CONFIG_FILE.tmp.$$"
  cat > "$_tmp_config" <<EOF
ENABLE_WECHAT=$ENABLE_WECHAT
ENABLE_DOUYIN=$ENABLE_DOUYIN
AUTO_ENABLED=$AUTO_ENABLED
SCHEDULE_MODE=$SCHEDULE_MODE
INTERVAL_MINUTES=$INTERVAL_MINUTES
DAILY_TIMES=$DAILY_TIMES
APP_SETTLE_SECONDS=$APP_SETTLE_SECONDS
EOF
  mv "$_tmp_config" "$CONFIG_FILE"
}

write_default_config() {
  ENABLE_WECHAT=1
  ENABLE_DOUYIN=1
  AUTO_ENABLED=0
  SCHEDULE_MODE="daily"
  INTERVAL_MINUTES=60
  DAILY_TIMES="03:00"
  APP_SETTLE_SECONDS=8
  write_config
}

load_config() {
  ensure_dirs

  if [ ! -f "$CONFIG_FILE" ]; then
    write_default_config
  fi

  ENABLE_WECHAT=1
  ENABLE_DOUYIN=1
  AUTO_ENABLED=0
  SCHEDULE_MODE="daily"
  INTERVAL_MINUTES=60
  DAILY_TIMES="03:00"
  APP_SETTLE_SECONDS=8

  . "$CONFIG_FILE" 2>/dev/null
  sanitize_config
}

trim_log() {
  [ -f "$LOG_FILE" ] || return
  _byte_count=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')
  case "$_byte_count" in
    ''|*[!0-9]*) _byte_count=0 ;;
  esac
  if [ "$_byte_count" -gt 1048576 ]; then
    tail -n 3000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
    return
  fi

  _line_count=$(wc -l < "$LOG_FILE" 2>/dev/null | tr -d ' ')
  case "$_line_count" in
    ''|*[!0-9]*) return ;;
  esac

  if [ "$_line_count" -gt 5000 ]; then
    tail -n 3000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
  fi
}

log_msg() {
  ensure_dirs
  _level=$1
  shift
  _message=$*
  _time=$(date +"%Y-%m-%d %H:%M:%S")
  echo "$_time [$_level] $_message" >> "$LOG_FILE"
  trim_log
}

write_state_value() {
  ensure_dirs
  _key=$1
  shift
  echo "$*" > "$STATE_DIR/$_key"
}

read_state_value() {
  _key=$1
  if [ -f "$STATE_DIR/$_key" ]; then
    sed -n '1p' "$STATE_DIR/$_key"
  fi
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

json_bool() {
  if [ "$1" = "1" ]; then
    echo "true"
  else
    echo "false"
  fi
}

send_keyevent() {
  _name=$1
  _code=$2
  input keyevent "$_name" >/dev/null 2>&1 || input keyevent "$_code" >/dev/null 2>&1
}

wake_device() {
  send_keyevent KEYCODE_WAKEUP 224
}

sleep_device() {
  send_keyevent KEYCODE_SLEEP 223
}

home_device() {
  send_keyevent KEYCODE_HOME 3
}

acquire_wake_lock() {
  _wake_name=${1:-$WAKE_LOCK_NAME}
  _wake_timeout=${2:-}
  if [ -w /sys/power/wake_lock ]; then
    if [ -n "$_wake_timeout" ]; then
      echo "$_wake_name $_wake_timeout" > /sys/power/wake_lock 2>/dev/null
    else
      echo "$_wake_name" > /sys/power/wake_lock 2>/dev/null
    fi
    return $?
  fi

  return 1
}

release_wake_lock() {
  _wake_name=${1:-$WAKE_LOCK_NAME}
  if [ -w /sys/power/wake_unlock ]; then
    echo "$_wake_name" > /sys/power/wake_unlock 2>/dev/null
    return $?
  fi

  return 1
}

pid_exists() {
  _pid=$1
  case "$_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -d "/proc/$_pid" ] && kill -0 "$_pid" 2>/dev/null
}

pid_cmdline_contains() {
  _pid=$1
  _needle=$2
  pid_exists "$_pid" || return 1
  [ -r "/proc/$_pid/cmdline" ] || return 1
  _cmdline=$(tr '\000' ' ' < "/proc/$_pid/cmdline" 2>/dev/null)
  case "$_cmdline" in
    *"$_needle"*) return 0 ;;
  esac
  return 1
}

wait_pid_gone() {
  _pid=$1
  _limit=${2:-5}
  _waited=0
  while pid_exists "$_pid" && [ "$_waited" -lt "$_limit" ]; do
    sleep 1
    _waited=$((_waited + 1))
  done
  ! pid_exists "$_pid"
}

supervisor_is_running() {
  [ -f "$SUPERVISOR_PID_FILE" ] || return 1
  _supervisor_pid=$(sed -n '1p' "$SUPERVISOR_PID_FILE" 2>/dev/null)
  pid_cmdline_contains "$_supervisor_pid" "$MODDIR/script/supervisor.sh" || pid_cmdline_contains "$_supervisor_pid" "supervisor.sh"
}

scheduler_is_running() {
  [ -f "$NATIVE_PID_FILE" ] || return 1
  _scheduler_pid=$(sed -n '1p' "$NATIVE_PID_FILE" 2>/dev/null)
  pid_cmdline_contains "$_scheduler_pid" "$TIMER_BIN" || pid_cmdline_contains "$_scheduler_pid" "autofire_timed"
}

start_scheduler_if_needed() {
  ensure_dirs

  if [ ! -f "$MODDIR/script/scheduler.sh" ]; then
    return 1
  fi

  sh "$MODDIR/script/scheduler.sh" start
}

reload_scheduler() {
  ensure_dirs

  if [ ! -f "$MODDIR/script/scheduler.sh" ]; then
    return 1
  fi

  sh "$MODDIR/script/scheduler.sh" reload
}

stop_scheduler() {
  ensure_dirs

  if [ ! -f "$MODDIR/script/scheduler.sh" ]; then
    return 0
  fi

  sh "$MODDIR/script/scheduler.sh" stop
}
