#!/bin/bash
set -euo pipefail

# Build the hyotan iOS runtime: libish, libish_emu, libfakefs, libhyotan
# and the guest VDSO for one SDK. The host only compiles; guest programs run on
# the device inside the linked library.
#
#   hyotan/scripts/build-runtime.sh [iphonesimulator|iphoneos]
#
# Environment:
#   HYOTAN_BUILD_DIR  output root (default: <repo>/.build); per-SDK subdirs
#   HYOTAN_TOOLS_DIR  venv with meson/ninja/zig (default: $HYOTAN_BUILD_DIR/tools)
#   IPHONEOS_DEPLOYMENT_TARGET  minimum iOS version (default: 17.0)
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SDK_NAME="${1:-iphonesimulator}"
IOS_VERSION="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
BUILD_ROOT="${HYOTAN_BUILD_DIR:-$REPO_DIR/.build}"
TOOLS_DIR="${HYOTAN_TOOLS_DIR:-$BUILD_ROOT/tools}"
BUILD_DIR="$BUILD_ROOT/$SDK_NAME"
CHECKS_DIR="$REPO_DIR/hyotan/checks"

case "$SDK_NAME" in
  iphonesimulator) TARGET="arm64-apple-ios${IOS_VERSION}-simulator" ;;
  iphoneos) TARGET="arm64-apple-ios${IOS_VERSION}" ;;
  *) echo "Usage: $0 [iphonesimulator|iphoneos]" >&2; exit 2 ;;
esac

if [ ! -x "$TOOLS_DIR/bin/meson" ] || [ ! -x "$TOOLS_DIR/bin/ninja" ] ||
   ! "$TOOLS_DIR/bin/python" -c 'import ziglang' >/dev/null 2>&1; then
  python3 -m venv "$TOOLS_DIR"
  "$TOOLS_DIR/bin/python" -m pip install --disable-pip-version-check \
    meson==1.9.1 ninja==1.13.0 ziglang==0.14.1
fi
export PATH="$TOOLS_DIR/bin:$PATH"
export ZIG_GLOBAL_CACHE_DIR="$BUILD_ROOT/zig-cache"
export ZIG_LOCAL_CACHE_DIR="$BUILD_ROOT/zig-local-cache"
mkdir -p "$BUILD_DIR"

# Zig supplies a small, project-local ELF linker for the Linux guest VDSO and
# compiles the guest check programs. Apple clang builds all code that iOS runs.
ZIG_BIN="$("$TOOLS_DIR/bin/python" -c 'import pathlib, ziglang; print(pathlib.Path(ziglang.__file__).parent / "zig")')"
GUEST_CC="$BUILD_ROOT/guest-clang"
cat > "$GUEST_CC" <<WRAP
#!/bin/bash
exec "$ZIG_BIN" cc -fno-sanitize=all -fno-stack-protector "\$@"
WRAP
chmod +x "$GUEST_CC"
IOS_SDK="$(xcrun --sdk "$SDK_NAME" --show-sdk-path)"
IOS_CLANG="$(xcrun --sdk "$SDK_NAME" --find clang)"
IOS_AR="$(xcrun --sdk "$SDK_NAME" --find ar)"

CROSS_FILE="$BUILD_ROOT/cross-$SDK_NAME.ini"
cat > "$CROSS_FILE" <<CROSS
[binaries]
c = ['$IOS_CLANG', '-target', '$TARGET', '-isysroot', '$IOS_SDK']
objc = ['$IOS_CLANG', '-target', '$TARGET', '-isysroot', '$IOS_SDK']
ar = '$IOS_AR'
strip = 'strip'
pkg-config = 'false'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = []
c_link_args = ['-L$IOS_SDK/usr/lib']

[properties]
needs_exe_wrapper = true
sys_root = '$IOS_SDK'
CROSS

MESON_ARGS=(--cross-file "$CROSS_FILE" --buildtype release
  -Db_ndebug=true -Dguest_arch=arm64 -Dkernel=ish -Dengine=asbestos
  -Dlog_handler=nslog -Dhyotan=true -Dvdso_cc="$GUEST_CC")
if [ -f "$BUILD_DIR/build.ninja" ]; then
  # A build directory configured before an option existed rejects it on
  # reconfigure; wipe and reuse the same arguments in that case.
  meson setup --reconfigure "$BUILD_DIR" "$REPO_DIR" "${MESON_ARGS[@]}" ||
    meson setup --wipe "$BUILD_DIR" "$REPO_DIR" "${MESON_ARGS[@]}"
else
  meson setup "$BUILD_DIR" "$REPO_DIR" "${MESON_ARGS[@]}"
fi
ninja -C "$BUILD_DIR" libish.a libish_emu.a libfakefs.a hyotan/libhyotan.a vdso/arm64/libvdso.so.elf
cp "$BUILD_DIR/hyotan/libhyotan.a" "$BUILD_DIR/libhyotan.a"

for check in runtime-check runtime-lane-check runtime-exclusive-check runtime-vector-check; do
  "$ZIG_BIN" cc -target aarch64-linux-musl -static -O2 -fno-sanitize=all \
    "$CHECKS_DIR/$check.c" -o "$BUILD_DIR/$check"
done

for library in libish.a libish_emu.a libfakefs.a libhyotan.a; do
  xcrun lipo -info "$BUILD_DIR/$library"
done
file "$BUILD_DIR/vdso/arm64/libvdso.so.elf"
echo "Runtime artifacts: $BUILD_DIR"
