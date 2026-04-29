#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OUT="$ROOT_DIR/bin/autofire_timed"

if [ -n "${ANDROID_NDK_HOME:-}" ]; then
  NDK="$ANDROID_NDK_HOME"
elif [ -n "${ANDROID_NDK_ROOT:-}" ]; then
  NDK="$ANDROID_NDK_ROOT"
else
  echo "ANDROID_NDK_HOME or ANDROID_NDK_ROOT is required" >&2
  exit 1
fi

HOST_TAG=${HOST_TAG:-linux-x86_64}
CLANG="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin/aarch64-linux-android23-clang"

if [ ! -x "$CLANG" ]; then
  echo "clang not found: $CLANG" >&2
  echo "Set HOST_TAG to your NDK host tag, for example windows-x86_64 or darwin-x86_64" >&2
  exit 1
fi

mkdir -p "$ROOT_DIR/bin"
"$CLANG" -Os -Wall -Wextra -Werror -fPIE -pie "$SCRIPT_DIR/autofire_timed.c" -o "$OUT"
chmod 0755 "$OUT"
echo "built $OUT"
