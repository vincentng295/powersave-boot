#!/usr/bin/env bash
# Build Magisk module SaveBoot -> dist/saveboot-<version>.zip
#
#   ./build.sh                  build tất cả ABI rồi đóng zip
#   ABIS="arm64" ./build.sh     chỉ build arm64 (arm64 arm x64 x86)
#   API=26 ./build.sh           đổi Android API level tối thiểu (mặc định 23)
#   NDK=/path/to/ndk ./build.sh chỉ định NDK (hoặc ANDROID_NDK_HOME / ANDROID_NDK_ROOT)
#   ./build.sh --host-check     biên dịch bằng compiler trên máy (chỉ để kiểm tra cảnh báo)
#   ./build.sh --clean          xoá build/ và dist/
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC="$ROOT/src/saveboot.c"
MODULE="$ROOT/module"
BUILD="$ROOT/build"
DIST="$ROOT/dist"

API=${API:-23}
ABIS=${ABIS:-"arm64 arm x64 x86"}

die() { echo "build.sh: $*" >&2; exit 1; }

case "${1:-}" in
  --clean)
    rm -rf "$BUILD" "$DIST"
    echo "đã xoá build/ và dist/"
    exit 0
    ;;
  --host-check)
    mkdir -p "$BUILD/host"
    # HOST_CFLAGS cho phép trỏ CPU_SYSFS/STATE_DIR sang cây thư mục giả để test
    # shellcheck disable=SC2086
    "${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror ${HOST_CFLAGS:-} \
      -o "$BUILD/host/saveboot" "$SRC"
    echo "OK: $BUILD/host/saveboot"
    exit 0
    ;;
  -h|--help)
    sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  "") ;;
  *) die "tham số không hợp lệ: $1 (xem --help)" ;;
esac

# ------------------------------------------------------------------ tìm NDK
find_ndk() {
  local v base latest
  for v in "${NDK:-}" "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" "${ANDROID_NDK:-}"; do
    if [ -n "$v" ] && [ -d "$v/toolchains/llvm/prebuilt" ]; then
      echo "$v"; return 0
    fi
  done
  for base in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Android/Sdk" "$HOME/Library/Android/sdk"; do
    [ -n "$base" ] && [ -d "$base/ndk" ] || continue
    latest=$(ls -1 "$base/ndk" 2>/dev/null | sort -V | tail -n1)
    if [ -n "$latest" ] && [ -d "$base/ndk/$latest/toolchains/llvm/prebuilt" ]; then
      echo "$base/ndk/$latest"; return 0
    fi
  done
  return 1
}

NDK_DIR=$(find_ndk) || die "không tìm thấy Android NDK. Đặt NDK=/đường/dẫn/ndk (hoặc ANDROID_NDK_HOME) rồi chạy lại."
PREBUILT=$(ls -1 "$NDK_DIR/toolchains/llvm/prebuilt" | head -n1)
TC="$NDK_DIR/toolchains/llvm/prebuilt/$PREBUILT/bin"
[ -x "$TC/llvm-strip" ] || die "NDK thiếu llvm-strip: $TC"
echo "NDK: $NDK_DIR (API $API)"

triple_for() {
  case "$1" in
    arm64) echo aarch64-linux-android ;;
    arm)   echo armv7a-linux-androideabi ;;
    x64)   echo x86_64-linux-android ;;
    x86)   echo i686-linux-android ;;
    *)     return 1 ;;
  esac
}

# ------------------------------------------------------------------ biên dịch
rm -rf "$BUILD/stage" "$BUILD/abi"
mkdir -p "$BUILD/stage" "$BUILD/abi" "$DIST"

for abi in $ABIS; do
  triple=$(triple_for "$abi") || die "ABI không hỗ trợ: $abi (arm64 arm x64 x86)"
  cc="$TC/${triple}${API}-clang"
  [ -x "$cc" ] || die "không thấy compiler: $cc"
  out="$BUILD/abi/$abi"
  mkdir -p "$out"
  echo "== build $abi"
  "$cc" -std=gnu11 -Os -Wall -Wextra \
    -ffunction-sections -fdata-sections -Wl,--gc-sections \
    -static -o "$out/saveboot" "$SRC"
  "$TC/llvm-strip" "$out/saveboot"
done

# ------------------------------------------------------------------ đóng gói
cp -a "$MODULE/." "$BUILD/stage/"
chmod 0755 "$BUILD/stage/post-fs-data.sh" "$BUILD/stage/service.sh" \
           "$BUILD/stage/customize.sh" "$BUILD/stage/META-INF/com/google/android/update-binary"
for abi in $ABIS; do
  mkdir -p "$BUILD/stage/bin/$abi"
  cp "$BUILD/abi/$abi/saveboot" "$BUILD/stage/bin/$abi/saveboot"
  chmod 0755 "$BUILD/stage/bin/$abi/saveboot"
done

VERSION=$(sed -n 's/^version=//p' "$MODULE/module.prop" | head -n1)
ZIP="$DIST/saveboot-${VERSION:-dev}.zip"
rm -f "$ZIP"

if command -v zip >/dev/null 2>&1; then
  (cd "$BUILD/stage" && zip -r9 -X "$ZIP" . >/dev/null)
elif command -v python3 >/dev/null 2>&1; then
  python3 - "$BUILD/stage" "$ZIP" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    for d, _, files in os.walk(src):
        for f in sorted(files):
            p = os.path.join(d, f)
            z.write(p, os.path.relpath(p, src))
PY
else
  die "cần zip hoặc python3 để đóng gói"
fi

echo
echo "Xong: $ZIP"
