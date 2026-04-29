#!/system/bin/sh

MODDIR=${0%/*}

release_lock_fallback() {
  _name=$1
  if [ -w /sys/power/wake_unlock ]; then
    echo "$_name" > /sys/power/wake_unlock 2>/dev/null
  fi
}

if [ -f "$MODDIR/script/common.sh" ]; then
  . "$MODDIR/script/common.sh"
  ensure_dirs
  log_msg "INFO" "uninstall cleanup started"

  if [ -f "$MODDIR/script/scheduler.sh" ]; then
    sh "$MODDIR/script/scheduler.sh" stop >/dev/null 2>&1
  fi

  release_wake_lock xiaoxiang_dispatch_wake_lock >/dev/null 2>&1
  release_wake_lock xiaoxiang_task_wake_lock >/dev/null 2>&1
  rm -f "$NATIVE_PID_FILE" "$SUPERVISOR_PID_FILE" "$SUPERVISOR_STOP_FILE"
  rmdir "$SUPERVISOR_LOCK_DIR" 2>/dev/null
  rmdir "$RUN_DIR" 2>/dev/null
  log_msg "INFO" "uninstall cleanup finished"
else
  if [ -f "$MODDIR/script/scheduler.sh" ]; then
    sh "$MODDIR/script/scheduler.sh" stop >/dev/null 2>&1
  fi
  release_lock_fallback xiaoxiang_dispatch_wake_lock
  release_lock_fallback xiaoxiang_task_wake_lock
  rm -f "$MODDIR/run/autofire_timed.pid" "$MODDIR/run/autofire_supervisor.pid" "$MODDIR/run/stop"
  rmdir "$MODDIR/run/supervisor.lock" 2>/dev/null
  rmdir "$MODDIR/run" 2>/dev/null
fi

exit 0
