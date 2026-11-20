#!/bin/bash
# 簽章 JaSub.app（含內嵌的 Sparkle.framework）。package.sh 與本機安裝共用。
#
# 用法：./sign_app.sh <JaSub.app 路徑> "<簽章身分>" [--timestamp]
#
# 不能用 `codesign --deep`：Sparkle 官方文件（Sandboxing → Code Signing）指出
# --deep 會把 app 的 entitlements 套到 Sparkle 的內嵌元件上，並蓋掉
# Downloader.xpc 自己的 entitlements。必須依官方順序逐一簽：
# Installer.xpc → Downloader.xpc（保留原 entitlements）→ Autoupdate →
# Updater.app → Sparkle.framework → 最後才簽 app 本身（帶 JaSub entitlements）。

set -e

APP="$1"
IDENTITY="$2"
EXTRA="${3:-}"
ENTITLEMENTS="$(cd "$(dirname "$0")" && pwd)/Resources/JaSub.entitlements"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

if [ -z "$APP" ] || [ -z "$IDENTITY" ]; then
    echo "用法：$0 <JaSub.app> \"<簽章身分>\" [--timestamp]"
    exit 1
fi

if [ -d "$SPARKLE" ]; then
    codesign -f -s "$IDENTITY" -o runtime $EXTRA "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
    codesign -f -s "$IDENTITY" -o runtime $EXTRA --preserve-metadata=entitlements \
        "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
    codesign -f -s "$IDENTITY" -o runtime $EXTRA "$SPARKLE/Versions/B/Autoupdate"
    codesign -f -s "$IDENTITY" -o runtime $EXTRA "$SPARKLE/Versions/B/Updater.app"
    codesign -f -s "$IDENTITY" -o runtime $EXTRA "$SPARKLE"
fi

codesign -f -s "$IDENTITY" -o runtime $EXTRA --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
