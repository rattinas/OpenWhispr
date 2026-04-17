#!/bin/bash
# TalkIsCheap Release-Script
# Usage: ./scripts/release.sh 1.1.0 2
#   $1 = short version (z.B. 1.1.0)
#   $2 = build number (monoton steigend, z.B. 2, 3, 4, ...)

set -euo pipefail

VERSION="${1:-}"
BUILD="${2:-}"
MODE="${3:-full}"  # "full" = sign + notarize + deploy; "local" = sign + DMG only

if [ -z "$VERSION" ] || [ -z "$BUILD" ]; then
  echo "Usage: $0 <version> <build> [full|local]"
  echo "Example: $0 1.1.0 2         # full release (notarize + deploy)"
  echo "Example: $0 1.1.0 2 local   # local test DMG (no notary, no deploy)"
  exit 1
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WEBSITE_DIR="/Users/bene/Documents/Projekte/talkischeap-website"
APPLE_ID="benedikt.rapp@me.com"
TEAM_ID="QGR98LFQ5C"
SIGNING_IDENTITY="Developer ID Application: Benedikt Rapp (QGR98LFQ5C)"
ENTITLEMENTS="$PROJECT_DIR/TalkIsCheap.entitlements"

cd "$PROJECT_DIR"

echo "════════════════════════════════════════════════════"
echo "  Releasing TalkIsCheap $VERSION (build $BUILD)"
echo "════════════════════════════════════════════════════"

# 1. Build release binary
# Universal (arm64+x86_64) requires full Xcode. SwiftPM CLI only builds
# for the host arch. Apple Silicon covers ~95% of active macOS users;
# if Intel coverage becomes necessary, install Xcode and add:
#   swift build -c release --arch arm64 --arch x86_64
echo ""
echo "▶ [1/8] Building release binary (arm64)…"
swift build -c release

# Locate built binary (universal build lands in .build/apple/Products/Release)
BINARY_PATH=""
for candidate in \
  ".build/apple/Products/Release/TalkIsCheap" \
  ".build/release/TalkIsCheap" \
  ".build/arm64-apple-macosx/release/TalkIsCheap"; do
  if [ -f "$candidate" ]; then BINARY_PATH="$candidate"; break; fi
done
if [ -z "$BINARY_PATH" ]; then
  echo "❌ Built binary not found"; exit 1
fi
echo "   Binary: $BINARY_PATH ($(file -b "$BINARY_PATH"))"

# Locate universal Sparkle.framework (XCFramework slice contains both arches)
SPARKLE_FW_SRC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "$SPARKLE_FW_SRC" ]; then
  echo "❌ Sparkle.framework not found at $SPARKLE_FW_SRC"; exit 1
fi

# 2. Assemble .app bundle in /tmp (outside iCloud-synced dir)
echo "▶ [2/8] Assembling .app bundle…"
BUILD_DIR="/tmp/talkischeap-release-$VERSION"
rm -rf "$BUILD_DIR"
APP_DIR="$BUILD_DIR/TalkIsCheap.app"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/TalkIsCheap"
chmod +x "$APP_DIR/Contents/MacOS/TalkIsCheap"

# SwiftPM sets rpath to @loader_path (= MacOS/). Add the standard macOS
# framework search path so the binary finds Sparkle.framework in Frameworks/.
# Must happen BEFORE codesign — changing rpath invalidates the signature.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$APP_DIR/Contents/MacOS/TalkIsCheap" 2>/dev/null || true
cp Resources/*.png "$APP_DIR/Contents/Resources/" 2>/dev/null || true
cp Resources/*.icns "$APP_DIR/Contents/Resources/" 2>/dev/null || true
cp dist/TalkIsCheap.app/Contents/Info.plist "$APP_DIR/Contents/Info.plist"

# Inject version + build into Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP_DIR/Contents/Info.plist"

# Copy Sparkle.framework preserving symlinks (-R, not -L)
cp -R "$SPARKLE_FW_SRC" "$APP_DIR/Contents/Frameworks/"

xattr -cr "$APP_DIR"

# 3. Code-sign (inside-out: XPC services → Updater.app → framework binaries → framework → app)
echo "▶ [3/8] Code-signing (inside-out)…"
SPARKLE_FW="$APP_DIR/Contents/Frameworks/Sparkle.framework"

sign() {
  codesign --force --timestamp --options runtime \
    --sign "$SIGNING_IDENTITY" "$@"
}

# XPC services (no entitlements — Sparkle's own sandbox profiles apply)
sign "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"

# Sparkle auxiliary binaries & Updater.app
sign "$SPARKLE_FW/Versions/B/Autoupdate"
sign "$SPARKLE_FW/Versions/B/Updater.app"

# Sparkle main binary + framework shell
sign "$SPARKLE_FW/Versions/B/Sparkle"
sign "$SPARKLE_FW"

# Main app (with entitlements)
codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGNING_IDENTITY" \
  "$APP_DIR"

# Verify signature
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
spctl --assess --verbose=4 --type execute "$APP_DIR" || true

# 4. Build DMG with drag-to-Applications UX
echo "▶ [4/8] Creating DMG (fancy layout)…"
DMG_PATH="$BUILD_DIR/TalkIsCheap-$VERSION.dmg"

# Regenerate background if source missing (idempotent)
BG_IMAGE="$PROJECT_DIR/Resources/dmg-background.png"
if [ ! -f "$BG_IMAGE" ]; then
  swift "$PROJECT_DIR/scripts/generate-dmg-background.swift" "$BG_IMAGE"
fi

# create-dmg wants a staging folder with only the items to include
DMG_STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$DMG_STAGE"; mkdir -p "$DMG_STAGE"
cp -R "$APP_DIR" "$DMG_STAGE/"

# Single-action install UX: app icon centered, "Double-click to install" in
# background image. No Applications drop-link — the app's LetsMove flow
# handles the copy + relaunch from /Applications after the user double-clicks.
create-dmg \
  --volname "TalkIsCheap" \
  --background "$BG_IMAGE" \
  --window-pos 200 120 \
  --window-size 480 400 \
  --icon-size 112 \
  --text-size 12 \
  --icon "TalkIsCheap.app" 240 150 \
  --hide-extension "TalkIsCheap.app" \
  --no-internet-enable \
  "$DMG_PATH" \
  "$DMG_STAGE"

codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"

# Local mode: stop here — skip notarize/staple/deploy so the user can iterate fast
if [ "$MODE" = "local" ]; then
  echo ""
  echo "════════════════════════════════════════════════════"
  echo "  🧪 Local test build (NOT notarized)"
  echo "════════════════════════════════════════════════════"
  echo "  DMG: $DMG_PATH"
  echo "  Open with: open \"$DMG_PATH\""
  echo ""
  echo "  Gatekeeper will warn on first launch — right-click"
  echo "  the app → Open → Open Anyway. After verifying the"
  echo "  flow works, run again without 'local' to notarize."
  echo "════════════════════════════════════════════════════"
  exit 0
fi

# 5. Notarize
echo "▶ [5/8] Notarizing (this may take 1-5 minutes)…"
xcrun notarytool submit "$DMG_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --keychain-profile "AC_PASSWORD" \
  --wait

# 6. Staple
echo "▶ [6/8] Stapling notarization ticket…"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# 7. Sign update with Sparkle EdDSA
echo "▶ [7/8] Signing update for Sparkle…"
SIGN_UPDATE_BIN=".build/artifacts/sparkle/Sparkle/bin/sign_update"
if [ ! -x "$SIGN_UPDATE_BIN" ]; then
  SIGN_UPDATE_BIN="$(find .build -name 'sign_update' -type f -perm +111 ! -path '*/old_dsa_scripts/*' | head -1)"
fi
if [ -z "$SIGN_UPDATE_BIN" ] || [ ! -x "$SIGN_UPDATE_BIN" ]; then
  echo "⚠️  sign_update binary not found"; exit 1
fi

SIGN_OUTPUT=$("$SIGN_UPDATE_BIN" "$DMG_PATH")
EDS_SIG=$(echo "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
DMG_SIZE=$(stat -f%z "$DMG_PATH")

# 8. Deploy DMG to website
echo "▶ [8/8] Deploying to website…"
mkdir -p "$WEBSITE_DIR/public/download"
cp "$DMG_PATH" "$WEBSITE_DIR/public/download/TalkIsCheap-$VERSION.dmg"
cp "$DMG_PATH" "$WEBSITE_DIR/public/download/TalkIsCheap-latest.dmg"

# Summary — requires manual appcast.xml edit
echo ""
echo "════════════════════════════════════════════════════"
echo "  ✅ Release $VERSION built + notarized"
echo "════════════════════════════════════════════════════"
echo ""
echo "  DMG:        $DMG_PATH"
echo "  Size:       $DMG_SIZE bytes"
echo "  EdSig:      $EDS_SIG"
echo ""
echo "  👉 Add this item to public/appcast.xml (at top of <channel>):"
echo ""
cat <<EOF
    <item>
      <title>Version $VERSION</title>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
        <h2>What's new in $VERSION</h2>
        <ul>
          <li>TODO: describe changes</li>
        </ul>
      ]]></description>
      <pubDate>$(date -R)</pubDate>
      <enclosure
        url="https://talkischeap.app/download/TalkIsCheap-$VERSION.dmg"
        sparkle:edSignature="$EDS_SIG"
        length="$DMG_SIZE"
        type="application/octet-stream"/>
    </item>
EOF
echo ""
echo "  Then:  cd $WEBSITE_DIR && git add . && git commit -m 'Release $VERSION' && git push"
echo "════════════════════════════════════════════════════"
