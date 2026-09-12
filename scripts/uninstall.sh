#!/bin/bash
set -euo pipefail
HELPER="$HOME/Library/Application Support/BG3MetalFX/bg3mf_installer"
if [ ! -x "$HELPER" ]; then
  echo "BG3 MetalFX 1.0.1 is not installed / 未安装 BG3 MetalFX 1.0.1。" >&2
  exit 1
fi
exec "$HELPER" uninstall
