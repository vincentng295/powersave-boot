#!/system/bin/sh
# Sau khi boot: BẬT hết core, giữ powersave, giới hạn xung max = 1/2 xung cao nhất của từng cụm

MODDIR=${0%/*}
STATE=/dev/cpu_boot_powersave
CPUDIR=/sys/devices/system/cpu

until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 1
done
sleep 5   # chờ hệ thống ổn định

# 1) Bật lại toàn bộ core
for O in $CPUDIR/cpu[0-9]*/online; do
  [ -f "$O" ] && echo 1 > "$O" 2>/dev/null
done
sleep 2   # chờ cpufreq policy của các core vừa bật xuất hiện

apply() {
  POLICIES=$(ls -d $CPUDIR/cpufreq/policy* 2>/dev/null)
  [ -z "$POLICIES" ] && POLICIES=$(ls -d $CPUDIR/cpu[0-9]*/cpufreq 2>/dev/null)

  for P in $POLICIES; do
    CMAX=$(cat "$P/cpuinfo_max_freq")
    MINF=$(cat "$P/cpuinfo_min_freq")
    HALF=$((CMAX / 2))

    # Chọn mức xung có sẵn lớn nhất mà <= 1/2 xung max
    TARGET=$HALF
    if [ -f "$P/scaling_available_frequencies" ]; then
      T=$(tr ' ' '\n' < "$P/scaling_available_frequencies" | awk -v h="$HALF" '$1+0>0 && $1+0<=h && $1+0>m {m=$1+0} END{print m+0}')
      [ "$T" -gt 0 ] 2>/dev/null && TARGET=$T
    fi
    [ "$TARGET" -lt "$MINF" ] && TARGET=$MINF

    chmod 644 "$P/scaling_governor" "$P/scaling_min_freq" "$P/scaling_max_freq" 2>/dev/null
    # Thứ tự: min xuống thấp nhất trước -> max -> governor
    echo "$MINF"      > "$P/scaling_min_freq"
    echo "$TARGET"    > "$P/scaling_max_freq"
    echo powersave    > "$P/scaling_governor"
  done
}

apply
rm -rf "$STATE"

# 2) Áp lại vài lần phòng khi HAL/thermal/vendor ghi đè
for i in 1 2 3; do
  sleep 30
  apply
done
