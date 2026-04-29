#!/system/bin/sh

MODDIR=${0%/*}

echo "AutoFire: screen will turn off, task starts in 20 seconds."
sh "$MODDIR/script/run_task.sh" action 20
