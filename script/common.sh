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
CONFIG_DIR="$MODDIR/config"
LOG_DIR="$MODDIR/logs"
STATE_DIR="$MODDIR/state"
CONFIG_FILE="$CONFIG_DIR/autofire.conf"
LOG_FILE="$LOG_DIR/autofire.log"
STATE_FILE="$STATE_DIR/scheduler.state"
PID_FILE="$STATE_DIR/scheduler.pid"
RUN_LOCK_DIR="$STATE_DIR/run.lock"
SCHEDULER_LOCK_DIR="$STATE_DIR/scheduler.lock"

WECHAT_PKG="com.tencent.mm"
DOUYIN_PKG="com.ss.android.ugc.aweme"

ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$STATE_DIR"
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
    daily) echo "daily" ;;
    *) echo "interval" ;;
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
  cat > "$CONFIG_FILE" <<EOF
ENABLE_WECHAT=$ENABLE_WECHAT
ENABLE_DOUYIN=$ENABLE_DOUYIN
AUTO_ENABLED=$AUTO_ENABLED
SCHEDULE_MODE=$SCHEDULE_MODE
INTERVAL_MINUTES=$INTERVAL_MINUTES
DAILY_TIMES=$DAILY_TIMES
APP_SETTLE_SECONDS=$APP_SETTLE_SECONDS
EOF
}

write_default_config() {
  ENABLE_WECHAT=1
  ENABLE_DOUYIN=1
  AUTO_ENABLED=0
  SCHEDULE_MODE="interval"
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
  SCHEDULE_MODE="interval"
  INTERVAL_MINUTES=60
  DAILY_TIMES="03:00"
  APP_SETTLE_SECONDS=8

  . "$CONFIG_FILE" 2>/dev/null
  sanitize_config
}

trim_log() {
  [ -f "$LOG_FILE" ] || return
  _line_count=$(wc -l < "$LOG_FILE" 2>/dev/null | tr -d ' ')
  case "$_line_count" in
    ''|*[!0-9]*) return ;;
  esac

  if [ "$_line_count" -gt 800 ]; then
    tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
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
