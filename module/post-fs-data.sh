#!/system/bin/sh
# Magisk post-fs-data (chặn boot cho tới khi script xong): chạy nhanh, không sleep.
MODDIR=${0%/*}
"$MODDIR/saveboot" --first-stage
