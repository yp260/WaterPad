#!/bin/bash
# 生成「未签名 IPA」。
# 用途：在没有 Apple 证书 / 没有 Mac 签名条件时，先编译出一个标准 .ipa，
#       再交给 Sideloadly / AltStore 用你自己的 Apple ID 重签安装。
# 注意：产物本身不能直接装进 iPhone，必须重签。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEME="WaterPad"
PROJECT="$ROOT/WaterPad.xcodeproj"
BUILD="$ROOT/build"
ARCHIVE="$BUILD/WaterPad.xcarchive"
OUT="$BUILD/WaterPad-unsigned.ipa"

if [ ! -d "$PROJECT" ]; then
  if command -v xcodegen >/dev/null 2>&1; then
    echo "未发现 .xcodeproj，使用 xcodegen 生成..."
    xcodegen generate
  else
    echo "错误：缺少 WaterPad.xcodeproj，且未安装 xcodegen。"
    echo "请执行：brew install xcodegen && xcodegen generate"
    exit 1
  fi
fi

rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "==> 编译未签名 archive（arm64 真机）"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$BUILD/DerivedData" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  clean archive

APP="$ARCHIVE/Products/Applications/$SCHEME.app"
if [ ! -d "$APP" ]; then
  echo "错误：未找到编译产物 $APP"
  echo "可用 xcodebuild -list -project \"$PROJECT\" 确认 scheme 名称。"
  exit 1
fi

echo "==> 打包 Payload 目录"
STAGE="$BUILD/ipa-stage"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
(cd "$STAGE" && zip -qry "$OUT" Payload)

echo ""
echo "完成：$OUT"
echo "这是未签名 IPA，不能直接安装。请用 Sideloadly / AltStore 以你自己的 Apple ID 重签。"
