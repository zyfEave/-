#!/system/bin/sh

MODDIR=${0%/*}

if [ -f "$MODDIR/script/common.sh" ]; then
  . "$MODDIR/script/common.sh"
else
  exit 1
fi

ensure_dirs

if is_module_disabled; then
  log_msg "INFO" "模块已停用，service不启动调度器"
  exit 0
fi

BOOT_COMPLETED_MAX_WAIT_SECONDS=${BOOT_COMPLETED_MAX_WAIT_SECONDS:-600}
POST_BOOT_SCHEDULER_DELAY_SECONDS=${POST_BOOT_SCHEDULER_DELAY_SECONDS:-120}

log_msg "INFO" "service已启动，等待系统完成开机；maxWait=${BOOT_COMPLETED_MAX_WAIT_SECONDS}s"

_waited=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
  if [ "$_waited" -ge "$BOOT_COMPLETED_MAX_WAIT_SECONDS" ]; then
    log_msg "WARN" "系统未在限定时间内完成开机，service退出且不启动调度器，避免第一屏阶段触发任务；waitedSeconds=$_waited"
    exit 0
  fi
  sleep 5
  _waited=$((_waited + 5))
done

date +%s > "$STATE_DIR/boot_completed_epoch" 2>/dev/null
log_msg "INFO" "系统开机完成，进入调度器启动保护延迟：${POST_BOOT_SCHEDULER_DELAY_SECONDS}s"
sleep "$POST_BOOT_SCHEDULER_DELAY_SECONDS"

if [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; then
  log_msg "WARN" "保护延迟结束后系统开机状态异常，service退出且不启动调度器"
  exit 0
fi

if is_module_disabled; then
  log_msg "INFO" "模块在开机等待期间被停用，调度器不会启动"
  exit 0
fi

load_config

if [ "$AUTO_ENABLED" != "1" ]; then
  log_msg "INFO" "自动定时未开启，开机不启动调度器"
  exit 0
fi

if start_scheduler_if_needed; then
  log_msg "INFO" "已请求启动调度器"
else
  log_msg "ERROR" "调度器启动请求失败"
fi
