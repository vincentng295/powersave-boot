#!/system/bin/sh
# Hàm dùng chung cho post-fs-data.sh và service.sh

CPUDIR=/sys/devices/system/cpu
STATE=/dev/cpu_boot_powersave        # lưu danh sách core đã tắt (xoá sau khi bật lại)
STUB=/dev/cpu_boot_powersave_stub    # chứa file stub đang được bind mount, KHÔNG xoá

mkdir -p "$STATE" "$STUB"

list_policies() {
  P=$(ls -d $CPUDIR/cpufreq/policy* 2>/dev/null)
  [ -z "$P" ] && P=$(ls -d $CPUDIR/cpu[0-9]*/cpufreq 2>/dev/null)
  echo "$P"
}

# Gỡ stub (nếu có) để ghi được xuống sysfs thật
unlock_file() {
  umount -l "$1" 2>/dev/null
  umount -l "$1" 2>/dev/null
  umount -l "$1" 2>/dev/null
}

# Ghi giá trị vào sysfs thật rồi bind mount stub (chứa đúng giá trị đó) đè lên
# -> các tiến trình khác có ghi đè cũng chỉ ghi vào stub, không tác động kernel
lock_file() {
  F="$1"; V="$2"
  [ -e "$F" ] || return 1
  unlock_file "$F"
  chmod 644 "$F" 2>/dev/null
  echo "$V" > "$F"
  S="$STUB/$(echo "$F" | sed 's#/#_#g')"
  echo "$V" > "$S"
  chmod 444 "$S"
  chcon --reference="$F" "$S" 2>/dev/null
  mount --bind "$S" "$F"
}
