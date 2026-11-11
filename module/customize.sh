#!/system/bin/sh
# Magisk đã giải nén zip vào $MODPATH trước khi source file này.
# Chọn binary đúng kiến trúc ($ARCH: arm, arm64, x86, x64) và bỏ các bản còn lại.

SRC="$MODPATH/bin/$ARCH/saveboot"

if [ ! -f "$SRC" ]; then
  abort "! Zip này không có binary cho kiến trúc: $ARCH"
fi

ui_print "- Kiến trúc: $ARCH"
mv "$SRC" "$MODPATH/saveboot"
rm -rf "$MODPATH/bin"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/saveboot" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
