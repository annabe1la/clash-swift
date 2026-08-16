#!/bin/bash
#
# 打包 clash-swift 为 ad-hoc 签名的 .app + DMG（自用，免 Apple 开发者账号）。
#
# 用法：
#   Scripts/package.sh              # 出 .app + .dmg 到 dist/
#   BUNDLE_CORE=1 Scripts/package.sh  # 额外把本机托管的 mihomo 核心打进 app（自包含）
#
# 说明：ad-hoc 签名的 app 分发给别人会被 Gatekeeper 拦，右键“打开”可绕过；本机自用无碍。
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/clash-swift.xcodeproj"
SCHEME="clash-swift"
APP_NAME="Clash Swift"
DIST="$ROOT/dist"
DERIVED="$ROOT/.build-dist"
BUNDLE_CORE="${BUNDLE_CORE:-0}"
CORE_SRC="$HOME/Library/Application Support/clashbar/core/mihomo"

echo "==> 清理"
rm -rf "$DIST" "$DERIVED"
mkdir -p "$DIST"

echo "==> 构建 Release"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  build

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "构建产物缺失: $APP"; exit 1; }

cp -R "$APP" "$DIST/"
APP_OUT="$DIST/$APP_NAME.app"

if [ "$BUNDLE_CORE" = "1" ]; then
  if [ -x "$CORE_SRC" ]; then
    echo "==> 打入 mihomo 核心 (Resources/bin/mihomo)"
    mkdir -p "$APP_OUT/Contents/Resources/bin"
    cp "$CORE_SRC" "$APP_OUT/Contents/Resources/bin/mihomo"
    chmod 0755 "$APP_OUT/Contents/Resources/bin/mihomo"
  else
    echo "警告：未找到本机核心 $CORE_SRC，跳过打入核心"
  fi
fi

echo "==> ad-hoc 重签名"
codesign --force --deep --sign - "$APP_OUT"
codesign --verify --deep --strict "$APP_OUT" && echo "签名校验通过"

echo "==> 生成 DMG"
DMG="$DIST/$APP_NAME.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP_OUT" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo ""
echo "完成："
echo "  App: $APP_OUT"
echo "  DMG: $DMG"
echo ""
echo "提示：首次运行请把 app 拖到 /Applications，右键“打开”绕过 Gatekeeper。"
echo "     TUN / 系统代理会按需请求管理员授权（无需开发者账号）。"
