#!/system/bin/sh
# Sau boot_completed + 30s: bật lại hết core, powersave, max = 1/2 xung cao nhất, khoá bằng stub

MODDIR=${0%/*}
. "$MODDIR/lib.sh"

until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 1
done
sleep 30

# 1) Gỡ stub cũ (cụm còn lại) để có thể ghi sysfs thật
for P in $(list_policies); do
  unlock_file "$P/scaling_governor"
  unlock_file "$P/scaling_min_freq"
  unlock_file "$P/scaling_max_freq"
done

# 2) Bật lại toàn bộ core
for O in $CPUDIR/cpu[0-9]*/online; do
  [ -f "$O" ] && echo 1 > "$O" 2>/dev/null
done
sleep 3   # chờ cpufreq policy của core vừa bật xuất hiện

# 3) Áp cấu hình cuối cùng + khoá bằng stub
for P in $(list_policies); do
  CMAX=$(cat "$P/cpuinfo_max_freq")
  MINF=$(cat "$P/cpuinfo_min_freq")
  HALF=$((CMAX / 2))

  # Mức xung có sẵn lớn nhất mà <= 1/2 xung max
  TARGET=$HALF
  if [ -f "$P/scaling_available_frequencies" ]; then
    T=$(tr ' ' '\n' < "$P/scaling_available_frequencies" | awk -v h="$HALF" '$1+0>0 && $1+0<=h && $1+0>m {m=$1+0} END{print m+0}')
    [ "$T" -gt 0 ] 2>/dev/null && TARGET=$T
  fi
  [ "$TARGET" -lt "$MINF" ] && TARGET=$MINF

  # Thứ tự: min thấp nhất -> max -> governor (lock_file tự ghi sysfs rồi mount stub)
  lock_file "$P/scaling_min_freq" "$MINF"
  lock_file "$P/scaling_max_freq" "$TARGET"
  lock_file "$P/scaling_governor" powersave
done

rm -rf "$STATE"
