#!/system/bin/sh

MODDIR=${0%/*}

echo "AutoFire: task starts in 20 seconds; screen-off is skipped during boot grace."
sh "$MODDIR/script/run_task.sh" action 20
