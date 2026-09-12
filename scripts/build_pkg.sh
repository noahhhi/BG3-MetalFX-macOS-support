#!/bin/bash
# 构建 BG3-MetalFX-arm64.pkg：编译 → 组装 payload → pkgbuild。
# 在仓库根目录运行：scripts/build_pkg.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$REPO/dist"
PAYLOAD="$DIST/payload/tmp/bg3metalfx-payload"
PKGSCRIPTS="$DIST/pkgscripts"

echo "[1/4] 编译"
cmake -S "$REPO/src" -B "$REPO/src/build" -DCMAKE_OSX_ARCHITECTURES=arm64 >/dev/null
cmake --build "$REPO/src/build" --target bg3mf_probe bg3mf_steam_launcher >/dev/null

echo "[2/4] payload"
rm -rf "$DIST/payload" "$PKGSCRIPTS"
mkdir -p "$PAYLOAD/mod" "$PKGSCRIPTS"
cp "$REPO/src/build/libbg3mf_probe.dylib" "$PAYLOAD/"
cp "$REPO/src/build/bg3mf_steam_launcher" "$PAYLOAD/"
cp "$REPO/scripts/uninstall.sh" "$PAYLOAD/"
cp -R "$REPO/mod/BG3MetalFX" "$PAYLOAD/mod/"
cp "$REPO/scripts/postinstall" "$PKGSCRIPTS/"
chmod 755 "$PKGSCRIPTS/postinstall"

echo "[3/4] pkgbuild"
mkdir -p "$DIST"
pkgbuild --root "$DIST/payload" \
  --scripts "$PKGSCRIPTS" \
  --identifier io.github.noahhhi.bg3metalfx \
  --version 1.0.0 \
  --ownership recommended \
  "$DIST/BG3-MetalFX-arm64.pkg"

echo "[4/4] 校验"
pkgutil --check-signature "$DIST/BG3-MetalFX-arm64.pkg" || true
ls -la "$DIST/BG3-MetalFX-arm64.pkg"
echo "OK: $DIST/BG3-MetalFX-arm64.pkg"
