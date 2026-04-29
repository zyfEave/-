#!/system/bin/sh

MODDIR=${0%/*}

if [ -f "$MODDIR/script/common.sh" ]; then
  . "$MODDIR/script/common.sh"
else
  exit 1
fi

ensure_dirs

if is_module_disabled; then
  log_msg "INFO" "模块已停用，service不启动"
  exit 0
fi

log_msg "INFO" "service已启动，等待系统开机完成"

while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
  sleep 5
done

sleep 10

if is_module_disabled; then
  log_msg "INFO" "模块在开机等待期间被停用，定时器不会启动"
  exit 0
fi

load_config

if [ "$AUTO_ENABLED" != "1" ]; then
  log_msg "INFO" "自动定时未开启，开机不启动定时器"
  exit 0
fi

if start_scheduler_if_needed; then
  log_msg "INFO" "已请求启动定时器"
else
  log_msg "ERROR" "定时器启动请求失败"
fi
