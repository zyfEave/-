#!/system/bin/sh

MODDIR=${0%/*}

if [ -f "$MODDIR/script/common.sh" ]; then
  . "$MODDIR/script/common.sh"
else
  exit 1
fi

ensure_dirs

if is_module_disabled; then
  log_msg "INFO" "module is disabled; service will not start"
  exit 0
fi

log_msg "INFO" "service starting"

while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
  sleep 5
done

sleep 10

if is_module_disabled; then
  log_msg "INFO" "module became disabled before scheduler start"
  exit 0
fi

if start_scheduler_if_needed; then
  log_msg "INFO" "scheduler launch requested"
else
  log_msg "ERROR" "scheduler launch failed"
fi
