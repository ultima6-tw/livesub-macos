#!/bin/bash
# JaSub 打包腳本：Release build + 簽章 + 公證（notarize）+ DMG
# 輸出：dist/JaSub-<version>.dmg
# 需要 keychain 中已安裝「Developer ID Application」憑證，
# 以及已用 `xcrun notarytool store-credentials "jasub-notarize" ...` 存好的認證設定檔

set -e

APP_NAME="JaSub"
PROJECT="JaSub.xcodeproj"
DERIVED="/tmp/jasub-build"
RELEASE_APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
DIST="./dist"
TMP_STAGE="/tmp/jasub-dmg-staging"
SIGN_IDENTITY="Developer ID Application: YenChang Lin (HK97UMBMF8)"
NOTARY_PROFILE="jasub-notarize"

# ─── 1. Release build ─────────────────────────────────────────────────────────

echo "▸ Building $APP_NAME (Release)..."

# iCloud 同步資料夾的檔案帶有 extended attributes，
# 直接啟用簽名時 codesign 會拒絕。
# 解法：build 時停用簽名（command line 覆寫），之後手動清 xattr + 簽名。
rm -rf "$DERIVED/Build/Products/Release"

BUILD_LOG=$(mktemp)
xcodebuild -project "$PROJECT" -scheme "$APP_NAME" -configuration Release \
           -derivedDataPath "$DERIVED" \
           CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
           build > "$BUILD_LOG" 2>&1
BUILD_EXIT=$?
grep -E "(error:|warning:|BUILD (SUCCEEDED|FAILED))" "$BUILD_LOG" | \
    grep -v appintentsmetadataprocessor || true
rm -f "$BUILD_LOG"

if [ $BUILD_EXIT -ne 0 ] || [ ! -d "$RELEASE_APP" ]; then
    echo "❌ Build failed (exit $BUILD_EXIT)"
    exit 1
fi

# 讀版號用未簽章的原始 build 輸出即可，不影響簽章。
VERSION=$(defaults read "$RELEASE_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "0.1.0")
TMP_DMG="/tmp/$APP_NAME-$VERSION.dmg"
DMG_PATH="$DIST/$APP_NAME-$VERSION.dmg"

# ─── 2. 組裝 DMG 內容並簽章 ───────────────────────────────────────────────────
# 重要：staging、簽章、建立 DMG、公證全部在 /tmp 進行，最後才把完成品複製回
# iCloud 同步的 dist/ ——iCloud 同步資料夾會重新附加 com.apple.FinderInfo，
# 簽在 iCloud 路徑下會被 codesign 拒絕（resource fork/Finder information not
# allowed）。另外 app bundle 只能複製「一次」，且必須在複製到最終位置（DMG
# staging 資料夾）之後才簽章，簽完就不能再複製——已簽章的 app bundle 只要再
# 被複製一次（不管用 cp -R 還是 ditto）就會讓 code signature 的
# resource-sealing 跟實際檔案對不上（codesign --verify 顯示 "code has no
# resources but signature indicates they must be present"），Apple notary
# 會直接判定 binary signature invalid，即使本機 codesign --verify 當下驗證
# 是乾淨的。

echo "▸ Staging DMG contents..."
rm -rf "$TMP_STAGE"
mkdir -p "$TMP_STAGE"
ditto "$RELEASE_APP" "$TMP_STAGE/$APP_NAME.app"
find "$TMP_STAGE/$APP_NAME.app" -exec xattr -c {} \; 2>/dev/null || true
xattr -d com.apple.FinderInfo "$TMP_STAGE/$APP_NAME.app" 2>/dev/null || true

echo "▸ Signing $APP_NAME ($SIGN_IDENTITY)..."
codesign -s "$SIGN_IDENTITY" --force --deep --options runtime --timestamp \
    --entitlements "$(pwd)/Resources/JaSub.entitlements" \
    "$TMP_STAGE/$APP_NAME.app"
codesign --verify --deep --strict --verbose=2 "$TMP_STAGE/$APP_NAME.app"

ln -sf /Applications "$TMP_STAGE/Applications"

# ─── 4. 建立壓縮 DMG ─────────────────────────────────────────────────────────

rm -f "$TMP_DMG"

echo "▸ Creating $TMP_DMG ..."
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$TMP_STAGE" \
    -ov -format UDZO \
    "$TMP_DMG" > /dev/null

rm -rf "$TMP_STAGE"

# ─── 4b. 驗證「實際裝進 DMG 裡的那份 app」簽章是否完整 ─────────────────────────
# 不能只驗證簽章當下那份副本：Apple DTS 工程師在論壇上強調過，打包過程
# (cp/ditto/hdiutil 等任何一步) 都可能讓 DMG 裡的 app 跟簽章時驗證過的不是
# 同一份，必須從最終產物重新掛載、抽出來驗證，才能代表 notarize 會看到的內容。
echo "▸ Verifying signature of the app actually inside the DMG..."
VERIFY_MNT=$(hdiutil attach "$TMP_DMG" -nobrowse -noautoopen -readonly | grep -o '/Volumes/.*' | tail -1)
codesign --verify --deep --strict --verbose=2 "$VERIFY_MNT/$APP_NAME.app"
VERIFY_EXIT=$?
hdiutil detach "$VERIFY_MNT" > /dev/null
if [ $VERIFY_EXIT -ne 0 ]; then
    echo "❌ App inside the DMG failed signature verification — aborting before notarization."
    exit 1
fi

# ─── 5. 簽章 DMG 本身 ────────────────────────────────────────────────────────

echo "▸ Signing $TMP_DMG ..."
codesign -s "$SIGN_IDENTITY" --force --timestamp "$TMP_DMG"

# ─── 6. 送公證（notarize）────────────────────────────────────────────────────

echo "▸ Submitting for notarization (this can take a few minutes)..."
xcrun notarytool submit "$TMP_DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "▸ Stapling notarization ticket..."
xcrun stapler staple "$TMP_DMG"

echo "▸ Verifying..."
spctl -a -t open --context context:primary-signature -v "$TMP_DMG"
xcrun stapler validate "$TMP_DMG"

# ─── 7. 複製完成品回 dist/ ────────────────────────────────────────────────────
# 單一 DMG 檔案（非 app bundle）複製沒有 resource-sealing 的問題，可以安全搬回
# iCloud 同步資料夾。

mkdir -p "$DIST"
rm -f "$DMG_PATH"
cp "$TMP_DMG" "$DMG_PATH"
rm -f "$TMP_DMG"

# ─── 完成 ────────────────────────────────────────────────────────────────────

SIZE=$(du -sh "$DMG_PATH" | cut -f1)
echo ""
echo "✅  $DMG_PATH  ($SIZE) — signed & notarized"
echo ""
echo "安裝方式："
echo "  1. 開啟 DMG → 將 JaSub.app 拖入 Applications → 退出 DMG"
echo "  2. 從 Applications 啟動（不要從 DMG 或專案資料夾直接啟動）"
echo ""
echo "⚠️  注意：直接從 DMG 或 build 資料夾啟動會讓 macOS 記錯路徑，"
echo "    導致系統音訊授權失效。請務必先拖進 Applications 再啟動。"
