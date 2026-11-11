#!/system/bin/sh
# post-fs-data: powersave + xung thấp nhất, TẮT hết core, chỉ giữ lại 1 core yếu nhất

MODDIR=${0%/*}
. "$MODDIR/lib.sh"

POLICIES=$(list_policies)

# 1) Tìm cụm yếu nhất (xung max thấp nhất)
LOWMAX=999999999
WEAK=""
for P in $POLICIES; do
  CMAX=$(cat "$P/cpuinfo_max_freq")
  if [ "$CMAX" -lt "$LOWMAX" ]; then
    LOWMAX=$CMAX
    WEAK=$P
  fi
done

# Core được giữ lại = core đầu tiên của cụm yếu nhất
if [ -f "$WEAK/related_cpus" ]; then
  KEEP=$(cut -d' ' -f1 < "$WEAK/related_cpus")
else
  KEEP=$(echo "$WEAK" | sed "s#$CPUDIR/cpu##; s#/cpufreq##")
fi
[ -z "$KEEP" ] && KEEP=0

# 2) Ép powersave + xung thấp nhất cho mọi cụm (làm trước khi tắt core vì policy sẽ biến mất)
for P in $POLICIES; do
  MINF=$(cat "$P/cpuinfo_min_freq")
  chmod 644 "$P/scaling_governor" "$P/scaling_min_freq" "$P/scaling_max_freq" 2>/dev/null
  echo powersave > "$P/scaling_governor"
  echo "$MINF"   > "$P/scaling_min_freq"
  echo "$MINF"   > "$P/scaling_max_freq"
done

# 3) Tắt tất cả core trừ KEEP
: > "$STATE/offlined"
for O in $CPUDIR/cpu[0-9]*/online; do
  [ -f "$O" ] || continue
  C=$(echo "$O" | sed "s#$CPUDIR/cpu##; s#/online##")
  [ "$C" = "$KEEP" ] && continue
  echo 0 > "$O" 2>/dev/null && echo "$C" >> "$STATE/offlined"
done

# 4) Khoá governor/xung của cụm còn lại bằng stub để chống ghi đè lúc boot
KP=$CPUDIR/cpu$KEEP/cpufreq
[ -d "$KP" ] || KP=$WEAK
MINF=$(cat "$KP/cpuinfo_min_freq")
lock_file "$KP/scaling_governor" powersave
lock_file "$KP/scaling_min_freq" "$MINF"
lock_file "$KP/scaling_max_freq" "$MINF"
