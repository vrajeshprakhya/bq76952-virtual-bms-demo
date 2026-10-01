#!/usr/bin/env bash
# Fetch Renode (portable, no sudo) and the xPack ARM GCC toolchain.
set -u
cd "$HOME"

echo "=== Renode: resolve latest portable ==="
RURL=$(curl -sfL https://api.github.com/repos/renode/renode/releases/latest \
  | grep -oE '"browser_download_url": *"[^"]*linux-portable\.tar\.gz"' \
  | grep -v dotnet | head -1 | cut -d'"' -f4)
echo "renode url: ${RURL:-NONE}"
if [ -n "${RURL:-}" ] && [ ! -d "$HOME/renode-portable" ]; then
  curl -sfL -o renode-portable.tar.gz "$RURL"
  mkdir -p renode-portable
  tar xzf renode-portable.tar.gz -C renode-portable --strip-components=1
  rm renode-portable.tar.gz
fi
"$HOME/renode-portable/renode" --version 2>/dev/null | head -2 || echo "renode NOT READY"

echo "=== xPack arm-none-eabi-gcc: resolve latest ==="
GURL=$(curl -sfL https://api.github.com/repos/xpack-dev-tools/arm-none-eabi-gcc-xpack/releases/latest \
  | grep -oE '"browser_download_url": *"[^"]*linux-x64\.tar\.gz"' \
  | head -1 | cut -d'"' -f4)
echo "gcc url: ${GURL:-NONE}"
if [ -n "${GURL:-}" ] && [ ! -d "$HOME/arm-gcc" ]; then
  curl -sfL -o arm-gcc.tar.gz "$GURL"
  mkdir -p arm-gcc
  tar xzf arm-gcc.tar.gz -C arm-gcc --strip-components=1
  rm arm-gcc.tar.gz
fi
"$HOME/arm-gcc/bin/arm-none-eabi-gcc" --version 2>/dev/null | head -1 || echo "arm-gcc NOT READY"
echo TOOLS-DONE
