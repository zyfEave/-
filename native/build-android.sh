#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

if [ -n "${ANDROID_NDK_HOME:-}" ]; then
  NDK="$ANDROID_NDK_HOME"
elif [ -n "${ANDROID_NDK_ROOT:-}" ]; then
  NDK="$ANDROID_NDK_ROOT"
else
  echo "ANDROID_NDK_HOME or ANDROID_NDK_ROOT is required" >&2
  exit 1
fi

mkdir -p "$ROOT_DIR/bin"
HOST_TAG=${HOST_TAG:-linux-x86_64}
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"
ABIS=${ABIS:-"arm64-v8a armeabi-v7a"}

build_one() {
  _abi=$1
  case "$_abi" in
    arm64-v8a)
      _clang="$TOOLCHAIN/aarch64-linux-android23-clang"
      _out="$ROOT_DIR/bin/autofire_timed"
      ;;
    armeabi-v7a)
      _clang="$TOOLCHAIN/armv7a-linux-androideabi23-clang"
      _out="$ROOT_DIR/bin/autofire_timed_armeabi-v7a"
      ;;
    *)
      echo "unsupported ABI: $_abi" >&2
      return 1
      ;;
  esac

  if [ ! -x "$_clang" ]; then
    echo "clang not found: $_clang" >&2
    echo "Set HOST_TAG to your NDK host tag, for example windows-x86_64 or darwin-x86_64" >&2
    return 1
  fi

  "$_clang" -Os -Wall -Wextra -Werror -fPIE -pie "$SCRIPT_DIR/autofire_timed.c" -llog -o "$_out"
  chmod 0755 "$_out"
  echo "built $_abi $_out"
}

for _abi in $ABIS; do
  build_one "$_abi"
done

echo "verify on device with: bin/autofire_timed --version"
