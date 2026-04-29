#!/system/bin/sh

SCRIPT_DIR=$(cd "${0%/*}" 2>/dev/null && pwd)
. "$SCRIPT_DIR/common.sh"

SOURCE=${1:-manual}
DELAY_SECONDS=${2:-0}

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
  rmdir "$RUN_LOCK_DIR" 2>/dev/null
}
trap cleanup_run_lock EXIT INT TERM

turn_screen_off_logged() {
  _reason=$1
  log_msg "INFO" "请求息屏：$_reason"
  if sleep_device; then
    log_msg "INFO" "息屏命令成功：$_reason"
  else
    log_msg "WARN" "息屏命令失败：$_reason"
  fi
}

wake_screen_logged() {
  _reason=$1
  log_msg "INFO" "请求亮屏：$_reason"
  if wake_device; then
    log_msg "INFO" "亮屏命令成功：$_reason"
  else
    log_msg "WARN" "亮屏命令失败：$_reason"
  fi
}

home_logged() {
  _label=$1
  _reason=$2
  log_msg "INFO" "$_label 请求回到桌面：$_reason"
  if home_device; then
    log_msg "INFO" "$_label 回到桌面成功：$_reason"
  else
    log_msg "WARN" "$_label 回到桌面失败：$_reason"
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

TARGET_COUNT=0
SUCCESS_COUNT=0
FAIL_COUNT=0

restart_package() {
  _label=$1
  _pkg=$2
  TARGET_COUNT=$((TARGET_COUNT + 1))

  log_msg "INFO" "$_label 操作开始：$_pkg"

  if ! pm path "$_pkg" >/dev/null 2>&1; then
    log_msg "WARN" "$_label 未安装，跳过杀死/启动/回桌面：$_pkg"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return
  fi

  home_logged "$_label" "强制停止前关闭前台"
  sleep 1

  log_msg "INFO" "$_label 请求杀死进程：am force-stop $_pkg"
  if am force-stop "$_pkg" >/dev/null 2>&1; then
    log_msg "INFO" "$_label 杀死进程成功：$_pkg"
  else
    log_msg "ERROR" "$_label 杀死进程失败：$_pkg"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return
  fi

  sleep 1

  log_msg "INFO" "$_label 请求启动应用：monkey launcher $_pkg"
  if monkey -p "$_pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
    log_msg "INFO" "$_label 启动命令成功：$_pkg"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    log_msg "ERROR" "$_label 启动命令失败：$_pkg"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return
  fi

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
