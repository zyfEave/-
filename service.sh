#!/system/bin/sh

MODDIR=${0%/*}

if [ -f "$MODDIR/script/common.sh" ]; then
  . "$MODDIR/script/common.sh"
else
  exit 1
fi

ensure_dirs

if is_module_disabled; then
  log_msg "INFO" "module disabled, service will not start scheduler"
  exit 0
fi

log_msg "INFO" "service started, boot_completed wait is bounded"

_waited=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
  if [ "$_waited" -ge "$BOOT_GRACE_SECONDS" ]; then
    log_msg "WARN" "boot_completed not ready after bounded wait, starting scheduler anyway; run_task has boot guard waitedSeconds=$_waited"
    break
  fi
  sleep 5
  _waited=$((_waited + 5))
done

if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
  sleep 10
fi

if is_module_disabled; then
  log_msg "INFO" "module disabled during boot wait, scheduler will not start"
  exit 0
fi

load_config

if [ "$AUTO_ENABLED" != "1" ]; then
  log_msg "INFO" "auto schedule disabled, service will not start scheduler"
  exit 0
fi

if start_scheduler_if_needed; then
  log_msg "INFO" "scheduler start requested"
else
  log_msg "ERROR" "scheduler start request failed"
fi
