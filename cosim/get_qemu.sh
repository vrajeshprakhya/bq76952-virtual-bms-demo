#!/usr/bin/env bash
# Fetch xPack QEMU Arm (portable, no sudo) into ~/qemu-arm.
set -eu
if [ -x "$HOME/qemu-arm/bin/qemu-system-arm" ]; then
  "$HOME/qemu-arm/bin/qemu-system-arm" --version | head -1
  echo "QEMU-DONE (already installed)"
  exit 0
fi
echo "=== xPack QEMU Arm: resolve latest ==="
url=$(curl -s https://api.github.com/repos/xpack-dev-tools/qemu-arm-xpack/releases/latest \
      | grep browser_download_url | grep linux-x64.tar.gz | grep -v sha | head -1 \
      | sed 's/.*"\(https[^"]*\)".*/\1/')
echo "qemu url: $url"
mkdir -p "$HOME/qemu-arm"
curl -sL "$url" | tar xz -C "$HOME/qemu-arm" --strip-components=1
"$HOME/qemu-arm/bin/qemu-system-arm" --version | head -1
echo "QEMU-DONE"
