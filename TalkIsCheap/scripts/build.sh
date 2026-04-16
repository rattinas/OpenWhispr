#!/bin/bash
set -e

cd "$(dirname "$0")/.."

echo "🔨 Building TalkIsCheap..."
swift build

echo "📦 Installing binary..."
cp .build/debug/TalkIsCheap dist/TalkIsCheap.app/Contents/MacOS/TalkIsCheap

echo "🔐 Removing extended attributes..."
xattr -cr dist/TalkIsCheap.app

echo "✍️  Ad-hoc signing..."
codesign --force --deep --sign - --identifier "com.talkischeap.app" dist/TalkIsCheap.app

echo "📂 Copying to /Applications..."
pkill -f TalkIsCheap 2>/dev/null || true
sleep 0.5
rm -rf /Applications/TalkIsCheap.app
cp -R dist/TalkIsCheap.app /Applications/TalkIsCheap.app

echo "🔗 Registering URL scheme..."
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f /Applications/TalkIsCheap.app

echo "📋 Resetting permissions for new binary..."
# Reset TCC entries so macOS re-prompts (avoids "denied" state from old binary hash)
tccutil reset Microphone com.talkischeap.app 2>/dev/null || true
tccutil reset Accessibility com.talkischeap.app 2>/dev/null || true
# Pre-grant accessibility via AXIsProcessTrustedWithOptions on next launch
defaults write com.talkischeap.app quickActionVersion -int 0 2>/dev/null || true

echo ""
echo "✅ Done! Starting TalkIsCheap..."
echo "⚠️  Grant Microphone + Accessibility when prompted (dev-only, not needed for end users)"
open /Applications/TalkIsCheap.app
