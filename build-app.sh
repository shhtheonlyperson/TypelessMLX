#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="TypelessMLX"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ENTITLEMENTS="$PROJECT_DIR/TypelessMLX/TypelessMLX.entitlements"
INSTALL_DIR="/Applications/$APP_NAME.app"

echo "╔══════════════════════════════════════╗"
echo "║        TypelessMLX Build v1.0        ║"
echo "╚══════════════════════════════════════╝"
echo ""

# --- Step 1: Build release binary ---
echo "🔨 Building release binary..."
cd "$PROJECT_DIR"
swift build -c release 2>&1

# --- Step 2: Create app bundle ---
echo ""
echo "📦 Creating app bundle..."

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
cp ".build/release/TypelessMLX" "$APP_BUNDLE/Contents/MacOS/TypelessMLX"

# Copy Info.plist
cp "TypelessMLX/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Copy backend Python files
mkdir -p "$APP_BUNDLE/Contents/Resources/backend"
cp backend/transcribe_server.py "$APP_BUNDLE/Contents/Resources/backend/"
cp backend/convert.py "$APP_BUNDLE/Contents/Resources/backend/"
cp backend/requirements.txt "$APP_BUNDLE/Contents/Resources/backend/"
echo "  ✅ Python backend bundled"

# Copy app icon
if [ -f "$PROJECT_DIR/icon/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/icon/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "  ✅ App icon bundled"
fi

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# --- Step 3: Code signing ---
echo ""
echo "🔐 Code signing..."
codesign --force --deep --sign - \
    --entitlements "$ENTITLEMENTS" \
    --preserve-metadata=entitlements,identifier \
    "$APP_BUNDLE" 2>&1 || {
        echo "⚠️  Signing with entitlements failed, trying basic..."
        codesign --force --deep --sign - "$APP_BUNDLE" 2>&1 || echo "⚠️  Code signing skipped"
    }

# Verify signature
codesign -dvv "$APP_BUNDLE" 2>&1 | grep -E "Identifier|Authority" || true

# --- Step 4: Report ---
echo ""
APP_SIZE=$(du -sh "$APP_BUNDLE" | awk '{print $1}')
BINARY_SIZE=$(du -sh "$APP_BUNDLE/Contents/MacOS/TypelessMLX" | awk '{print $1}')
echo "═══════════════════════════════════════"
echo "  ✅ Build complete!"
echo "  📍 $APP_BUNDLE"
echo "  📏 App size: $APP_SIZE"
echo "  📏 Binary: $BINARY_SIZE"
echo "═══════════════════════════════════════"

# --- Step 5: Install (optional) ---
if [ "$1" = "--install" ] || [ "$1" = "-i" ]; then
    echo ""
    echo "📲 Installing to /Applications..."
    killall TypelessMLX 2>/dev/null || true
    sleep 1
    rm -rf "$INSTALL_DIR"
    cp -R "$APP_BUNDLE" "$INSTALL_DIR"
    echo "✅ Installed to $INSTALL_DIR"
    echo ""
    echo "🚀 Launching TypelessMLX..."
    open "$INSTALL_DIR"
else
    echo ""
    echo "To install: $0 --install"
    echo "To run:     open \"$APP_BUNDLE\""
fi

echo ""
echo "⚠️  首次使用注意事項："
echo "  1. 授權麥克風存取（系統設定 → 隱私權 → 麥克風）"
echo "  2. 授權輔助使用（系統設定 → 隱私權 → 輔助使用）"
echo "  3. App 啟動後會自動顯示設定視窗，安裝 Python 環境"
echo "  4. 下載並轉換 Breeze-ASR-25 模型（約 10-20 分鐘）"
echo "  5. 完成後按 Right Option 即可開始錄音"
