#!/bin/bash
set -euo pipefail
export COPYFILE_DISABLE=1
REPO="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=1.0.2
DIST="$REPO/dist"
WORK=$(mktemp -d "$REPO/.pkg-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
cmake -S "$REPO/src" -B "$REPO/src/build" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_BUILD_TYPE=Release
cmake --build "$REPO/src/build" --target bg3mf_probe bg3mf_steam_launcher bg3mf_installer
PKGSCRIPTS="$WORK/scripts"
PORTABLE="$WORK/BG3-MetalFX-arm64"
mkdir -p "$PKGSCRIPTS/mod" "$PORTABLE" "$DIST"
for NAME in libbg3mf_probe.dylib bg3mf_steam_launcher bg3mf_installer; do
  cp "$REPO/src/build/$NAME" "$PKGSCRIPTS/"
done
python3 "$REPO/scripts/build_mod.py" "$REPO/mod/BG3MetalFX" "$PKGSCRIPTS/mod/BG3MetalFX.pak"
cp "$REPO/scripts/uninstall.sh" "$PKGSCRIPTS/"
cp -R "$PKGSCRIPTS/." "$PORTABLE/"
cp "$REPO/scripts/install.sh" "$PORTABLE/"
printf '#!/bin/bash\ncd "$(dirname "$0")"\nexec ./install.sh\n' > "$PORTABLE/Install BG3 MetalFX.command"
chmod 755 "$PORTABLE/"*.sh "$PORTABLE/Install BG3 MetalFX.command" "$PKGSCRIPTS/uninstall.sh"
cp "$REPO/README.md" "$REPO/README.zh-CN.md" "$REPO/LICENSE" "$PORTABLE/"
cp -R "$REPO/docs" "$PORTABLE/"
cp "$REPO/scripts/postinstall" "$PKGSCRIPTS/postinstall"
chmod 755 "$PKGSCRIPTS/postinstall"
pkgbuild --nopayload --scripts "$PKGSCRIPTS" --identifier io.github.noahhhi.bg3metalfx --version "$VERSION" "$WORK/component.pkg"
cat > "$WORK/requirements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>arch</key><array><string>arm64</string></array><key>os</key><array><string>13.0</string></array></dict></plist>
PLIST
productbuild --package "$WORK/component.pkg" --product "$WORK/requirements.plist" "$DIST/BG3-MetalFX-arm64.pkg"
/usr/bin/ditto -c -k --norsrc --keepParent "$PORTABLE" "$DIST/BG3-MetalFX-arm64.zip"
cp "$REPO/scripts/uninstall.sh" "$DIST/uninstall.sh"
(cd "$DIST" && shasum -a 256 BG3-MetalFX-arm64.pkg BG3-MetalFX-arm64.zip uninstall.sh > SHA256SUMS.txt)
echo "BG3 MetalFX $VERSION built: $DIST"
