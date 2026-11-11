#!/system/bin/sh
# Giai đoạn post-fs-data: powersave + xung thấp nhất, và TẮT các core mạnh (cụm có xung tối đa cao nhất)

MODDIR=${0%/*}
STATE=/dev/cpu_boot_powersave   # tmpfs, mất sau khi reboot
mkdir -p "$STATE"

CPUDIR=/sys/devices/system/cpu

POLICIES=$(ls -d $CPUDIR/cpufreq/policy* 2>/dev/null)
[ -z "$POLICIES" ] && POLICIES=$(ls -d $CPUDIR/cpu[0-9]*/cpufreq 2>/dev/null)

# 1) Ép powersave + xung thấp nhất cho mọi cụm, đồng thời tìm xung max cao nhất
TOPMAX=0
LOWMAX=999999999
for P in $POLICIES; do
  N=$(echo "$P" | sed "s#$CPUDIR/##; s#/#_#g")
  [ -f "$STATE/$N.gov" ] || {
    cat "$P/scaling_governor" > "$STATE/$N.gov"
    cat "$P/scaling_min_freq" > "$STATE/$N.min"
    cat "$P/scaling_max_freq" > "$STATE/$N.max"
  }

  CMAX=$(cat "$P/cpuinfo_max_freq")
  [ "$CMAX" -gt "$TOPMAX" ] && TOPMAX=$CMAX
  [ "$CMAX" -lt "$LOWMAX" ] && LOWMAX=$CMAX

  MINF=$(cat "$P/cpuinfo_min_freq")
  chmod 644 "$P/scaling_governor" "$P/scaling_min_freq" "$P/scaling_max_freq" 2>/dev/null
  echo powersave > "$P/scaling_governor"
  echo "$MINF"   > "$P/scaling_min_freq"
  echo "$MINF"   > "$P/scaling_max_freq"
done

# 2) Tắt core mạnh: cụm nào có xung max cao hơn cụm yếu nhất thì offline
#    (nếu chip chỉ có 1 loại cụm thì không tắt gì, tránh tắt nhầm)
if [ "$TOPMAX" -gt "$LOWMAX" ]; then
  : > "$STATE/offlined"
  for P in $POLICIES; do
    CMAX=$(cat "$P/cpuinfo_max_freq")
    [ "$CMAX" -le "$LOWMAX" ] && continue

    if [ -f "$P/related_cpus" ]; then
      CPUS=$(cat "$P/related_cpus")
    else
      CPUS=$(echo "$P" | sed "s#$CPUDIR/cpu##; s#/cpufreq##")
    fi

    for C in $CPUS; do
      [ "$C" = "0" ] && continue            # không bao giờ tắt cpu0
      if [ -f "$CPUDIR/cpu$C/online" ]; then
        echo 0 > "$CPUDIR/cpu$C/online" && echo "$C" >> "$STATE/offlined"
      fi
    done
  done
fi
