#!/system/bin/sh
# Chạy ở giai đoạn post-fs-data: ép toàn bộ core về powersave + xung thấp nhất

MODDIR=${0%/*}
STATE=/dev/cpu_boot_powersave   # tmpfs, mất sau khi reboot
mkdir -p "$STATE"

# Ưu tiên policy theo cụm (cluster), fallback theo từng cpu
POLICIES=$(ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null)
[ -z "$POLICIES" ] && POLICIES=$(ls -d /sys/devices/system/cpu/cpu[0-9]*/cpufreq 2>/dev/null)

for P in $POLICIES; do
  N=$(echo "$P" | sed 's#/sys/devices/system/cpu/##; s#/#_#g')
  [ -f "$STATE/$N.gov" ] || {
    cat "$P/scaling_governor"    > "$STATE/$N.gov"
    cat "$P/scaling_min_freq"    > "$STATE/$N.min"
    cat "$P/scaling_max_freq"    > "$STATE/$N.max"
  }

  MINF=$(cat "$P/cpuinfo_min_freq")
  chmod 644 "$P/scaling_governor" "$P/scaling_min_freq" "$P/scaling_max_freq" 2>/dev/null

  echo powersave > "$P/scaling_governor"
  echo "$MINF"   > "$P/scaling_min_freq"
  echo "$MINF"   > "$P/scaling_max_freq"
done
