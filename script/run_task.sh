#!/system/bin/sh

SCRIPT_DIR=$(cd "${0%/*}" 2>/dev/null && pwd)
. "$SCRIPT_DIR/common.sh"

SOURCE=${1:-manual}
DELAY_SECONDS=${2:-0}
COMMAND_TIMEOUT_SECONDS=${COMMAND_TIMEOUT_SECONDS:-12}

case "$DELAY_SECONDS" in
  ''|*[!0-9]*) DELAY_SECONDS=0 ;;
esac

source_label() {
  case "$SOURCE" in
    action) echo "Action按钮" ;;
    scheduler-interval) echo "固定间隔定时" ;;
    scheduler-daily-*) echo "每天定点 ${SOURCE#scheduler-daily-}" ;;
    manual) echo "手动执行" ;;
    *) echo "$SOURCE" ;;
  esac
}

SOURCE_LABEL=$(source_label)

ensure_dirs
load_config

if is_module_disabled; then
  log_msg "INFO" "任务跳过：模块已停用，来源=$SOURCE_LABEL"
  exit 0
fi

if ! mkdir "$RUN_LOCK_DIR" 2>/dev/null; then
  log_msg "WARN" "任务跳过：已有任务正在运行，来源=$SOURCE_LABEL"
  exit 2
fi

cleanup_run_lock() {
  rm -f "$STATE_DIR/cmd_timeout.$$"
  rmdir "$RUN_LOCK_DIR" 2>/dev/null
}
trap cleanup_run_lock EXIT INT TERM

run_quiet_with_timeout() {
  _timeout=$1
  shift
  _timeout_file="$STATE_DIR/cmd_timeout.$$"
  rm -f "$_timeout_file"

  "$@" >/dev/null 2>&1 &
  _cmd_pid=$!

  (
    sleep "$_timeout"
    if kill -0 "$_cmd_pid" 2>/dev/null; then
      echo timeout > "$_timeout_file"
      kill "$_cmd_pid" 2>/dev/null
      sleep 1
      kill -9 "$_cmd_pid" 2>/dev/null
    fi
  ) &
  _watchdog_pid=$!

  wait "$_cmd_pid" 2>/dev/null
  _rc=$?
  kill "$_watchdog_pid" 2>/dev/null
  wait "$_watchdog_pid" 2>/dev/null

  if [ -f "$_timeout_file" ]; then
    rm -f "$_timeout_file"
    return 124
  fi

  rm -f "$_timeout_file"
  return "$_rc"
}

send_keyevent_timeout() {
  _name=$1
  _code=$2
  run_quiet_with_timeout 6 input keyevent "$_name" || run_quiet_with_timeout 6 input keyevent "$_code"
}

turn_screen_off_logged() {
  _reason=$1
  log_msg "INFO" "请求息屏：$_reason"
  if send_keyevent_timeout KEYCODE_SLEEP 223; then
    log_msg "INFO" "息屏命令成功：$_reason"
  else
    log_msg "WARN" "息屏命令失败或超时：$_reason"
  fi
}

wake_screen_logged() {
  _reason=$1
  log_msg "INFO" "请求亮屏：$_reason"
  if send_keyevent_timeout KEYCODE_WAKEUP 224; then
    log_msg "INFO" "亮屏命令成功：$_reason"
  else
    log_msg "WARN" "亮屏命令失败或超时：$_reason"
  fi
}

dismiss_keyguard_logged() {
  _reason=$1
  log_msg "INFO" "请求关闭非安全锁屏：$_reason"
  if run_quiet_with_timeout 6 wm dismiss-keyguard; then
    log_msg "INFO" "非安全锁屏关闭命令成功：$_reason"
  else
    log_msg "WARN" "非安全锁屏关闭失败或设备存在安全锁屏：$_reason"
  fi
  log_msg "INFO" "提示：如设备启用密码/指纹锁屏，系统可能阻止前台页面显示，但脚本会继续执行命令"
}

home_logged() {
  _label=$1
  _reason=$2
  log_msg "INFO" "$_label 请求回到桌面：$_reason"
  if send_keyevent_timeout KEYCODE_HOME 3; then
    log_msg "INFO" "$_label 回到桌面成功：$_reason"
  else
    log_msg "WARN" "$_label 回到桌面失败或超时：$_reason"
  fi
}

if [ "$DELAY_SECONDS" -gt 0 ]; then
  log_msg "INFO" "Action任务已触发：先息屏并等待${DELAY_SECONDS}秒"
  turn_screen_off_logged "Action延迟等待"
  sleep "$DELAY_SECONDS"
fi

log_msg "INFO" "任务开始：来源=$SOURCE_LABEL"
write_state_value last_source "$SOURCE_LABEL"
write_state_value last_run "$(date +"%Y-%m-%d %H:%M:%S")"

wake_screen_logged "重启应用前亮屏"
sleep 2
dismiss_keyguard_logged "重启应用前"
home_logged "系统" "任务开始前回到桌面，避免停留管理器前台"
sleep 1

TARGET_COUNT=0
SUCCESS_COUNT=0
FAIL_COUNT=0

restart_package() {
  _label=$1
  _pkg=$2
  TARGET_COUNT=$((TARGET_COUNT + 1))

  log_msg "INFO" "$_label 操作开始：$_pkg"
  log_msg "INFO" "$_label 检查安装状态：pm path $_pkg"
  run_quiet_with_timeout 8 pm path "$_pkg"
  _rc=$?
  case "$_rc" in
    0)
      log_msg "INFO" "$_label 安装状态正常：$_pkg"
      ;;
    124)
      log_msg "ERROR" "$_label 检查安装状态超时：$_pkg"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      return
      ;;
    *)
      log_msg "WARN" "$_label 未安装或无法读取安装状态，跳过杀死/启动/回桌面：$_pkg，返回码=$_rc"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      return
      ;;
  esac

  home_logged "$_label" "强制停止前关闭前台"
  sleep 1

  log_msg "INFO" "$_label 请求杀死进程：am force-stop $_pkg"
  run_quiet_with_timeout "$COMMAND_TIMEOUT_SECONDS" am force-stop "$_pkg"
  _rc=$?
  case "$_rc" in
    0)
      log_msg "INFO" "$_label 杀死进程成功：$_pkg"
      ;;
    124)
      log_msg "ERROR" "$_label 杀死进程超时：$_pkg"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      return
      ;;
    *)
      log_msg "ERROR" "$_label 杀死进程失败：$_pkg，返回码=$_rc"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      return
      ;;
  esac

  sleep 1

  log_msg "INFO" "$_label 请求启动应用：monkey launcher $_pkg"
  run_quiet_with_timeout 15 monkey -p "$_pkg" -c android.intent.category.LAUNCHER 1
  _rc=$?
  case "$_rc" in
    0)
      log_msg "INFO" "$_label 启动命令成功：$_pkg"
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
      ;;
    124)
      log_msg "ERROR" "$_label 启动命令超时：$_pkg"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      return
      ;;
    *)
      log_msg "ERROR" "$_label 启动命令失败：$_pkg，返回码=$_rc"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      return
      ;;
  esac

  _settle_seconds=$APP_SETTLE_SECONDS
  if [ "$_pkg" = "$DOUYIN_PKG" ] && [ "$SOURCE" = "action" ]; then
    _settle_seconds=60
    log_msg "INFO" "$_label Action模式：抖音前台停留60秒后回桌面"
  fi

  log_msg "INFO" "$_label 启动后等待${_settle_seconds}秒"
  sleep "$_settle_seconds"

  home_logged "$_label" "启动后放回后台"
  sleep 1

  if [ "$_pkg" = "$DOUYIN_PKG" ]; then
    log_msg "INFO" "$_label 再次确认回到手机主界面"
    home_logged "$_label" "确保抖音结束后停留主界面"
    sleep 1
  fi

  log_msg "INFO" "$_label 操作完成：$_pkg"
}

if [ "$ENABLE_WECHAT" = "1" ]; then
  restart_package "微信" "$WECHAT_PKG"
else
  log_msg "INFO" "微信已在配置中关闭，跳过"
fi

if [ "$ENABLE_DOUYIN" = "1" ]; then
  restart_package "抖音" "$DOUYIN_PKG"
else
  log_msg "INFO" "抖音已在配置中关闭，跳过"
fi

home_logged "系统" "任务结束前最终回到桌面"
sleep 1
turn_screen_off_logged "任务完成"

if [ "$TARGET_COUNT" -eq 0 ]; then
  RESULT="没有启用的应用"
  log_msg "WARN" "任务完成：没有启用的应用"
elif [ "$FAIL_COUNT" -eq 0 ]; then
  RESULT="成功：已重启${SUCCESS_COUNT}个应用"
  log_msg "INFO" "任务成功完成：已重启${SUCCESS_COUNT}个应用"
else
  RESULT="部分成功：成功${SUCCESS_COUNT}个，失败${FAIL_COUNT}个"
  log_msg "WARN" "任务完成但有失败：成功${SUCCESS_COUNT}个，失败${FAIL_COUNT}个"
fi

write_state_value last_result "$RESULT"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
fi

exit 1
