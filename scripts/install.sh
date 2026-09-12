#!/bin/bash
# 免 PKG 手动安装（当前用户，无需 root）：与 postinstall 等效。
# 用法：bash install.sh（在解压后的发布目录中运行）
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
USER_HOME="$HOME"
DEST="$USER_HOME/Library/Application Support/BG3MetalFX"
GAME_DATA="$USER_HOME/Documents/Larian Studios/Baldur's Gate 3"
MODS_DIR="$GAME_DATA/Mods"
MOD_UUID="f3a7c1e2-9b4d-4e5a-8c6f-1d2e3f4a5b6c"

echo "[1/4] 核心文件 -> $DEST"
mkdir -p "$DEST/runs"
cp "$HERE/libbg3mf_probe.dylib" "$DEST/"
cp "$HERE/bg3mf_steam_launcher" "$DEST/"
chmod 755 "$DEST/bg3mf_steam_launcher"
cp "$HERE/uninstall.sh" "$DEST/"
chmod 755 "$DEST/uninstall.sh"
printf 'BG3MF_TEMPORAL=1\nBG3MF_SCALE_PATCH=1\n' > "$DEST/runs/launch_env"

echo "[2/4] 本地化 mod"
mkdir -p "$MODS_DIR"
rm -rf "$MODS_DIR/BG3MetalFX"
cp -R "$HERE/mod/BG3MetalFX" "$MODS_DIR/"

echo "[3/4] modsettings.lsx"
MS="$GAME_DATA/PlayerProfiles/Public/modsettings.lsx"
if [ -f "$MS" ] && ! grep -q "$MOD_UUID" "$MS"; then
  cp "$MS" "$MS.bg3metalfx.bak"
  awk -v uuid="$MOD_UUID" '
    /^[[:space:]]*<node id="Mods">$/ {
      print "                <node id=\"ModOrder\">";
      print "                    <children>";
      print "                        <node id=\"Module\">";
      print "                            <attribute id=\"UUID\" type=\"guid\" value=\"" uuid "\"/>";
      print "                        </node>";
      print "                    </children>";
      print "                </node>";
      inmods=1
    }
    /^[[:space:]]*<\/children>$/ && inmods && !sd {
      print "                        <node id=\"ModuleShortDesc\">";
      print "                            <attribute id=\"Folder\" type=\"LSString\" value=\"BG3MetalFX\"/>";
      print "                            <attribute id=\"MD5\" type=\"LSString\" value=\"\"/>";
      print "                            <attribute id=\"Name\" type=\"LSString\" value=\"BG3MetalFX\"/>";
      print "                            <attribute id=\"PublishHandle\" type=\"uint64\" value=\"0\"/>";
      print "                            <attribute id=\"UUID\" type=\"guid\" value=\"" uuid "\"/>";
      print "                            <attribute id=\"Version64\" type=\"int64\" value=\"36028797018963968\"/>";
      print "                        </node>";
      sd=1; inmods=0
    }
    { print }
  ' "$MS.bg3metalfx.bak" > "$MS"
  echo "  registered"
else
  echo "  already registered or file missing"
fi

echo "[4/4] Steam 启动选项"
LAUNCHER="$DEST/bg3mf_steam_launcher"
for VDF in "$USER_HOME/Library/Application Support/Steam/userdata"/*/config/localconfig.vdf; do
  [ -f "$VDF" ] || continue
  grep -q 'bg3mf_steam_launcher' "$VDF" && { echo "  already set"; continue; }
  cp "$VDF" "$VDF.bg3metalfx.bak"
  awk -v launcher="\"$LAUNCHER\" %command%" '
    { if (!done && $0 ~ /"1086940"/) seen=1
      if (seen && $0 ~ /{/) { print; print "\t\"LaunchOptions\"\t\t\"" launcher "\""; done=1; seen=0; next }
      if (done && $0 ~ /"LaunchOptions"/) next
      print }
  ' "$VDF.bg3metalfx.bak" > "$VDF.tmp"
  if grep -q 'bg3mf_steam_launcher' "$VDF.tmp"; then mv "$VDF.tmp" "$VDF"; echo "  set: $VDF"
  else mv "$VDF.bg3metalfx.bak" "$VDF"; rm -f "$VDF.tmp"; echo "  no app block, skipped: $VDF"; fi
done

echo "完成。若 Steam 正在运行请重启后从 Steam 启动游戏。"
