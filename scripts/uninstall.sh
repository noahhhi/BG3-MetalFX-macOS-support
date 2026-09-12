#!/bin/bash
# BG3 MetalFX 卸载（当前用户运行，无需 root）：
# 移除 Steam 启动选项、本地化 mod 与 modsettings 注册、注入器目录。
set -u
USER_HOME="$HOME"
DEST="$USER_HOME/Library/Application Support/BG3MetalFX"
GAME_DATA="$USER_HOME/Documents/Larian Studios/Baldur's Gate 3"
MOD_UUID="f3a7c1e2-9b4d-4e5a-8c6f-1d2e3f4a5b6c"

echo "[1/4] Steam 启动选项"
for VDF in "$USER_HOME/Library/Application Support/Steam/userdata"/*/config/localconfig.vdf; do
  [ -f "$VDF" ] || continue
  if [ -f "$VDF.bg3metalfx.bak" ]; then
    mv "$VDF.bg3metalfx.bak" "$VDF"
    echo "  restored backup: $VDF"
  elif grep -q 'bg3mf_steam_launcher' "$VDF"; then
    grep -v 'bg3mf_steam_launcher' "$VDF" > "$VDF.tmp" && mv "$VDF.tmp" "$VDF"
    echo "  removed launch option: $VDF"
  fi
done

echo "[2/4] modsettings.lsx"
MS="$GAME_DATA/PlayerProfiles/Public/modsettings.lsx"
if [ -f "$MS.bg3metalfx.bak" ]; then
  mv "$MS.bg3metalfx.bak" "$MS"
  echo "  restored backup"
elif [ -f "$MS" ] && grep -q "$MOD_UUID" "$MS"; then
  # 无备份时的降级移除：删除含 UUID 的 Module/ModuleShortDesc 块
  awk -v uuid="$MOD_UUID" '
    /^[[:space:]]*<node id="(Module|ModuleShortDesc)">$/ { buf=$0; hold=1; next }
    hold { buf=buf "\n" $0; if ($0 ~ /<\/node>/) { if (buf !~ uuid) printf "%s\n", buf; hold=0 } next }
    { print }
  ' "$MS" > "$MS.tmp" && mv "$MS.tmp" "$MS"
  echo "  removed entries"
fi

echo "[3/4] mod 文件"
rm -rf "$GAME_DATA/Mods/BG3MetalFX"
echo "  removed Mods/BG3MetalFX"

echo "[4/4] 注入器"
rm -rf "$DEST"
echo "  removed $DEST"

echo "卸载完成。若 Steam 正在运行请重启 Steam。"
