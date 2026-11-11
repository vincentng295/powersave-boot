#!/system/bin/sh
# Magisk late_start service (không chặn boot): saveboot tự chờ boot_completed + 30 giây.
MODDIR=${0%/*}
"$MODDIR/saveboot" --second-stage
