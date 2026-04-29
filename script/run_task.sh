#!/system/bin/sh

SCRIPT_DIR=$(cd "${0%/*}" 2>/dev/null && pwd)
. "$SCRIPT_DIR/common.sh"

SOURCE=${1:-manual}
DELAY_SECONDS=${2:-0}
COMMAND_TIMEOUT_SECONDS=${COMMAND_TIMEOUT_SECONDS:-12}
BOOT_WAIT_SECONDS=${BOOT_WAIT_SECONDS:-120}
SCREEN_OFF_BOOT_GRACE_SECONDS=${SCREEN_OFF_BOOT_GRACE_SECONDS:-300}

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

TASK_LOCK_MAX_SECONDS=${TASK_LOCK_MAX_SECONDS:-180}
TASK_WAKE_LOCK_NAME=${TASK_WAKE_LOCK_NAME:-xiaoxiang_task_wake_lock}
TASK_WAKE_LOCK_TIMEOUT_NS=${TASK_WAKE_LOCK_TIMEOUT_NS:-120000000000}

cleanup_stale_run_lock() {
  rm -f "$RUN_LOCK_DIR/pid" "$RUN_LOCK_DIR/started" "$RUN_LOCK_DIR/source" "$RUN_LOCK_DIR/task" "$RUN_LOCK_DIR/label" "$RUN_LOCK_DIR/cmdline"
  rmdir "$RUN_LOCK_DIR" 2>/dev/null
}

write_run_lock_metadata() {
  echo "$$" > "$RUN_LOCK_DIR/pid"
  date +%s > "$RUN_LOCK_DIR/started"
  echo "$SOURCE" > "$RUN_LOCK_DIR/source"
  echo "$SOURCE" > "$RUN_LOCK_DIR/task"
  echo "$SOURCE_LABEL" > "$RUN_LOCK_DIR/label"
  tr '\000' ' ' < "/proc/$$/cmdline" > "$RUN_LOCK_DIR/cmdline" 2>/dev/null || echo "run_task.sh $SOURCE" > "$RUN_LOCK_DIR/cmdline"
}

acquire_run_lock() {
  if mkdir "$RUN_LOCK_DIR" 2>/dev/null; then
    write_run_lock_metadata
    return 0
  fi

  _owner_pid=$(sed -n '1p' "$RUN_LOCK_DIR/pid" 2>/dev/null)
  _started=$(sed -n '1p' "$RUN_LOCK_DIR/started" 2>/dev/null)
  _lock_cmdline=$(sed -n '1p' "$RUN_LOCK_DIR/cmdline" 2>/dev/null)
  _now=$(date +%s)
  case "$_started" in
    ''|*[!0-9]*) _age=-1 ;;
    *) _age=$((_now - _started)) ;;
  esac

  case "$_owner_pid" in
    ''|*[!0-9]*)
      log_msg "WARN" "任务锁异常，清理stale lock：来源=$SOURCE_LABEL，reason=invalid_owner"
      cleanup_stale_run_lock
      ;;
    *)
      if ! kill -0 "$_owner_pid" 2>/dev/null; then
        log_msg "WARN" "任务锁stale，清理后继续：来源=$SOURCE_LABEL，owner=$_owner_pid，ageSeconds=$_age"
        cleanup_stale_run_lock
      else
        _owner_cmdline=$(tr '\000' ' ' < "/proc/$_owner_pid/cmdline" 2>/dev/null)
        case "$_owner_cmdline" in
          *run_task.sh*) ;;
          *)
            log_msg "WARN" "任务锁stale，清理后继续：来源=$SOURCE_LABEL，owner=$_owner_pid，reason=cmdline_mismatch，lockCmdline=$_lock_cmdline，procCmdline=$_owner_cmdline"
            cleanup_stale_run_lock
            ;;
        esac
      fi

      if [ ! -d "$RUN_LOCK_DIR" ]; then
        :
      elif [ "$_age" -gt "$TASK_LOCK_MAX_SECONDS" ]; then
        log_msg "WARN" "任务跳过：已有任务仍在运行且超过期望时长，来源=$SOURCE_LABEL，owner=$_owner_pid，ageSeconds=$_age，maxSeconds=$TASK_LOCK_MAX_SECONDS，reason=already_running_timeout_exceeded"
        return 1
      else
        log_msg "WARN" "任务跳过：已有任务正在运行，来源=$SOURCE_LABEL，owner=$_owner_pid，ageSeconds=$_age，reason=already_running"
        return 1
      fi
      ;;
  esac

  if mkdir "$RUN_LOCK_DIR" 2>/dev/null; then
    write_run_lock_metadata
    return 0
  fi

  log_msg "WARN" "任务跳过：任务锁获取失败，来源=$SOURCE_LABEL"
  return 1
}

if ! acquire_run_lock; then
  exit 2
fi

TASK_WAKE_LOCK_HELD=0
TASK_WAKE_LOCK_STARTED=0

acquire_task_wake_lock() {
  if acquire_wake_lock "$TASK_WAKE_LOCK_NAME" "$TASK_WAKE_LOCK_TIMEOUT_NS"; then
    TASK_WAKE_LOCK_HELD=1
    TASK_WAKE_LOCK_STARTED=$(date +%s)
    write_state_value task_wake_lock 1
    log_msg "INFO" "任务唤醒锁已获取：来源=$SOURCE_LABEL，name=$TASK_WAKE_LOCK_NAME，timeoutNs=$TASK_WAKE_LOCK_TIMEOUT_NS"
  else
    log_msg "WARN" "任务唤醒锁不可用或获取失败，息屏深睡时任务执行可能被系统延迟：来源=$SOURCE_LABEL，name=$TASK_WAKE_LOCK_NAME"
  fi
}

release_task_wake_lock() {
  if [ "$TASK_WAKE_LOCK_HELD" = "1" ]; then
    _released_at=$(date +%s)
    _held_seconds=$((_released_at - TASK_WAKE_LOCK_STARTED))
    if release_wake_lock "$TASK_WAKE_LOCK_NAME"; then
      log_msg "INFO" "任务唤醒锁已释放：来源=$SOURCE_LABEL，name=$TASK_WAKE_LOCK_NAME，heldMs=$((_held_seconds * 1000))"
    else
      log_msg "WARN" "任务唤醒锁释放失败：来源=$SOURCE_LABEL，name=$TASK_WAKE_LOCK_NAME，heldMs=$((_held_seconds * 1000))"
    fi
    rm -f "$STATE_DIR/task_wake_lock"
    TASK_WAKE_LOCK_HELD=0
  fi
}

cleanup_run_lock() {
  rm -f "$STATE_DIR/cmd_timeout.$$"
  release_task_wake_lock
  rm -f "$RUN_LOCK_DIR/pid" "$RUN_LOCK_DIR/started" "$RUN_LOCK_DIR/source" "$RUN_LOCK_DIR/task" "$RUN_LOCK_DIR/label" "$RUN_LOCK_DIR/cmdline"
  rmdir "$RUN_LOCK_DIR" 2>/dev/null
}
trap cleanup_run_lock EXIT
trap 'cleanup_run_lock; exit 130' INT
trap 'cleanup_run_lock; exit 143' TERM
trap 'cleanup_run_lock; exit 129' HUP

record_boot_completed_epoch_if_needed() {
  _now=$(date +%s)
  _stored=$(read_state_value boot_completed_epoch)
  _should_write=0

  case "$_stored" in
    ''|*[!0-9]*) _should_write=1 ;;
  esac

  if [ "$_should_write" = "0" ] && [ -r /proc/uptime ]; then
    read _uptime _rest < /proc/uptime
    _uptime=${_uptime%.*}
    case "$_uptime" in
      ''|*[!0-9]*) ;;
      *)
        _boot_start=$((_now - _uptime))
        if [ "$_stored" -lt "$_boot_start" ]; then
          _should_write=1
        fi
        ;;
    esac
  fi

  if [ "$_should_write" = "1" ]; then
    echo "$_now" > "$STATE_DIR/boot_completed_epoch" 2>/dev/null
  fi
}

wait_boot_completed() {
  _waited=0
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    if [ "$_waited" -ge "$BOOT_WAIT_SECONDS" ]; then
      log_msg "WARN" "任务跳过：系统尚未完成开机，来源=$SOURCE_LABEL，waitedSeconds=$_waited，exitCode=75"
      write_state_value last_result "bootNotReady"
      exit 75
    fi
    sleep 5
    _waited=$((_waited + 5))
  done

  record_boot_completed_epoch_if_needed
}

wait_boot_completed
acquire_task_wake_lock

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

boot_age_seconds() {
  _now=$(date +%s)
  _boot_epoch=$(read_state_value boot_completed_epoch)
  case "$_boot_epoch" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$_now" -ge "$_boot_epoch" ]; then
        echo $((_now - _boot_epoch))
        return
      fi
      ;;
  esac

  if [ -r /proc/uptime ]; then
    read _uptime _rest < /proc/uptime
    _uptime=${_uptime%.*}
    case "$_uptime" in
      ''|*[!0-9]*) ;;
      *)
        echo "$_uptime"
        return
        ;;
    esac
  fi

  echo 0
}

screen_off_allowed() {
  _reason=$1
  _boot_age=$(boot_age_seconds)
  case "$_boot_age" in
    ''|*[!0-9]*) _boot_age=0 ;;
  esac

  if [ "$_boot_age" -lt "$SCREEN_OFF_BOOT_GRACE_SECONDS" ]; then
    log_msg "WARN" "跳过息屏：开机保护期内不执行息屏命令，reason=$_reason，bootAgeSeconds=$_boot_age，graceSeconds=$SCREEN_OFF_BOOT_GRACE_SECONDS"
    return 1
  fi

  return 0
}

turn_screen_off_logged() {
  _reason=$1
  if ! screen_off_allowed "$_reason"; then
    return
  fi

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
