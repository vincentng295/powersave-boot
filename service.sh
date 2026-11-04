#!/system/bin/sh
# Chờ boot xong rồi trả CPU về bình thường

MODDIR=${0%/*}
STATE=/dev/cpu_boot_powersave

until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 1
done
sleep 5   # chờ hệ thống ổn định

POLICIES=$(ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null)
[ -z "$POLICIES" ] && POLICIES=$(ls -d /sys/devices/system/cpu/cpu[0-9]*/cpufreq 2>/dev/null)

for P in $POLICIES; do
  N=$(echo "$P" | sed 's#/sys/devices/system/cpu/##; s#/#_#g')

  if [ -f "$STATE/$N.gov" ]; then
    GOV=$(cat "$STATE/$N.gov"); MINF=$(cat "$STATE/$N.min"); MAXF=$(cat "$STATE/$N.max")
  else
    # Không có bản lưu -> đoán giá trị mặc định
    MINF=$(cat "$P/cpuinfo_min_freq"); MAXF=$(cat "$P/cpuinfo_max_freq")
    AVAIL=$(cat "$P/scaling_available_governors")
    GOV=""
    for G in walt schedutil sched interactive ondemand; do
      case " $AVAIL " in *" $G "*) GOV=$G; break;; esac
    done
    [ -z "$GOV" ] && GOV=$(echo "$AVAIL" | awk '{print $1}')
  fi

  # Thứ tự: nới max trước, rồi min, rồi governor
  echo "$MAXF" > "$P/scaling_max_freq"
  echo "$MINF" > "$P/scaling_min_freq"
  echo "$GOV"  > "$P/scaling_governor"
done

rm -rf "$STATE"
