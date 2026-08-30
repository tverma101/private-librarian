#!/bin/bash
# Package the sandboxed LibrarianApp into a proper .app bundle with hardened
# entitlements (plan §2, §38) and ad-hoc signing.
#
# The librarian-cli remains a development/verification harness and is
# intentionally NOT shipped inside the production .app bundle.
#
# Usage: scripts/package_app.sh [build-dir]   (default: .build/release)
set -euo pipefail

BUILD_DIR="${1:-.build/release}"
APP_NAME="PrivateLibrarian.app"
OUT_DIR="dist"
IDENTITY="${CODESIGN_IDENTITY:--}"

ENTITLEMENTS="$(mktemp /tmp/librarian-entitlements.XXXXXX.plist)"
cat > "$ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-only</key>
    <true/>
    <key>com.apple.security.files.bookmarks.app-scope</key>
    <true/>
</dict>
</plist>
EOF

rm -rf "$OUT_DIR/$APP_NAME"
mkdir -p "$OUT_DIR/$APP_NAME/Contents/MacOS" "$OUT_DIR/$APP_NAME/Contents/Resources/scripts"
mkdir -p "$OUT_DIR/$APP_NAME/Contents/Resources/Models"

cp "$BUILD_DIR/LibrarianApp" "$OUT_DIR/$APP_NAME/Contents/MacOS/PrivateLibrarian"

# Bundle only offline runtime helpers. Provisioners are deliberately not part
# of the application: model downloads remain a separate explicit operator action.
for helper in scripts/embed.py scripts/specialist.py; do
    if [ -f "$helper" ]; then
        cp "$helper" "$OUT_DIR/$APP_NAME/Contents/Resources/scripts/"
    fi
done

# Optionally bundle already-provisioned Models for offline inference in signed Resources.
# Public/release builds do not download models and CI normally has no Models directory.
if [ -d "Models" ]; then
    for m in Models/*; do
        [ -d "$m" ] || continue
        name="$(basename "$m")"
        cp -R "$m" "$OUT_DIR/$APP_NAME/Contents/Resources/Models/$name" 2>/dev/null || true
    done
fi

cat > "$OUT_DIR/$APP_NAME/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Private Librarian</string>
    <key>CFBundleDisplayName</key><string>Private Librarian</string>
    <key>CFBundleIdentifier</key><string>com.tejas.private-librarian</string>
    <key>CFBundleExecutable</key><string>PrivateLibrarian</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
EOF

codesign --force --sign "$IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    "$OUT_DIR/$APP_NAME"

echo "packaged: $OUT_DIR/$APP_NAME"
rm -f "$ENTITLEMENTS"
