#!/usr/bin/env bash
set -euo pipefail

# Build one canonical PrivateLibrarian.app artifact and, by default, a
# versioned DMG. The CLI remains a development/verification harness and is
# never copied into the production app. Release packaging uses an Xcode
# archive by default so the executable is built through the same signing
# pipeline as the distributable app.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${LIBRARIAN_BUILD_DIR:-$ROOT_DIR/.build/release}"
OUT_DIR="${LIBRARIAN_DIST_DIR:-$ROOT_DIR/dist}"
STAGE_DIR="${LIBRARIAN_PACKAGE_STAGE_DIR:-$ROOT_DIR/.build/package-stage}"
BUILD_SYSTEM="${LIBRARIAN_BUILD_SYSTEM:-xcode}"
XCODE_DERIVED_DATA_DIR="${LIBRARIAN_XCODE_DERIVED_DATA_DIR:-$ROOT_DIR/.build/xcode-derived}"
XCODE_ARCHIVE_DIR="${LIBRARIAN_XCODE_ARCHIVE_DIR:-$ROOT_DIR/.build/xcode-archive}"
XCODE_CONFIGURATION="${LIBRARIAN_XCODE_CONFIGURATION:-Release}"
XCODE_DESTINATION="${LIBRARIAN_XCODE_DESTINATION:-generic/platform=macOS}"
IDENTITY="${CODESIGN_IDENTITY:-}"
VERSION="${APP_VERSION:-}"
BUILD_VERSION="${APP_BUILD_VERSION:-1}"
APP_SUPPORT_DIR="${LIBRARIAN_APP_SUPPORT_DIR:-$HOME/Library/Containers/com.tejas.private-librarian/Data/Library/Application Support/PrivateLibrarian}"
MODEL_SOURCE="${LIBRARIAN_MODELS_DIR:-$APP_SUPPORT_DIR/Models}"
SPECIALIST_MODEL_SOURCE="${LIBRARIAN_SPECIALIST_MODELS_DIR:-$MODEL_SOURCE/specialists}"
RUNTIME_SOURCE="${LIBRARIAN_MODEL_RUNTIME_DIR:-$APP_SUPPORT_DIR/model-runtime}"
INCLUDE_MODELS=0
INCLUDE_SPECIALISTS=0
INCLUDE_RUNTIME=0
MAKE_DMG=1
INSTALL_APP=0
OPEN_APP=0
POSITIONAL_BUILD_DIR=0
BUILD_SYSTEM_EXPLICIT=0
SPECIALIST_DIR_EXPLICIT=0
if [ -n "${LIBRARIAN_BUILD_SYSTEM:-}" ]; then
    BUILD_SYSTEM_EXPLICIT=1
fi

APP_BUNDLE_NAME="PrivateLibrarian.app"
APP_EXECUTABLE="LibrarianApp"
BUNDLE_IDENTIFIER="com.tejas.private-librarian"
INSTALL_PATH="/Applications/$APP_BUNDLE_NAME"

usage() {
    cat <<EOF
Usage: $0 [build-dir] [options]

Creates $APP_BUNDLE_NAME from an Xcode macOS archive and emits
dist/PrivateLibrarian-VERSION.dmg unless --no-dmg is supplied. A positional
build directory is retained as a SwiftPM compatibility path.

Options:
  --xcode                 archive the package with xcodebuild (default)
  --swiftpm               package an existing SwiftPM release build
  --xcode-derived-data PATH
                           Xcode derived-data directory (default: .build/xcode-derived)
  --xcode-archive PATH    Xcode archive directory (default: .build/xcode-archive)
  --xcode-configuration VALUE
                           Xcode configuration (default: Release)
  --destination VALUE     xcodebuild destination (default: generic/platform=macOS)
  --version VERSION       CFBundleShortVersionString (default: VERSION file)
  --build-version VALUE   CFBundleVersion (default: 1)
  --models-dir PATH       verified model root to bundle with --include-models
  --include-models        include both verified wired Python checkpoints
  --specialists-dir PATH  verified specialist root to bundle with --include-specialists
  --include-specialists    include every verified specialist checkpoint found there
  --runtime-dir PATH      isolated Python runtime to bundle with --include-runtime
  --include-runtime       include the optional Python runtime in Resources
  --no-dmg                 keep the signed .app in .build/package-stage
  --install                replace /Applications/$APP_BUNDLE_NAME
  --open                   launch the packaged app after validation
  -h, --help              show this help

Environment:
  CODESIGN_IDENTITY, DEVELOPMENT_TEAM, APP_VERSION, APP_BUILD_VERSION,
  LIBRARIAN_BUILD_SYSTEM, LIBRARIAN_DIST_DIR, LIBRARIAN_PACKAGE_STAGE_DIR,
  LIBRARIAN_APP_SUPPORT_DIR,
  LIBRARIAN_MODELS_DIR, LIBRARIAN_SPECIALIST_MODELS_DIR,
  LIBRARIAN_XCODE_DERIVED_DATA_DIR, LIBRARIAN_XCODE_ARCHIVE_DIR,
  LIBRARIAN_XCODE_CONFIGURATION, LIBRARIAN_XCODE_DESTINATION,
  LIBRARIAN_XCODE_DEVELOPMENT_TEAM
EOF
}

while (($#)); do
    case "$1" in
        --xcode)
            BUILD_SYSTEM="xcode"
            BUILD_SYSTEM_EXPLICIT=1
            shift
            ;;
        --swiftpm)
            BUILD_SYSTEM="swiftpm"
            BUILD_SYSTEM_EXPLICIT=1
            shift
            ;;
        --xcode-derived-data)
            [ "$#" -ge 2 ] || { echo "--xcode-derived-data needs a path" >&2; exit 2; }
            XCODE_DERIVED_DATA_DIR="$2"
            shift 2
            ;;
        --xcode-archive)
            [ "$#" -ge 2 ] || { echo "--xcode-archive needs a path" >&2; exit 2; }
            XCODE_ARCHIVE_DIR="$2"
            shift 2
            ;;
        --xcode-configuration)
            [ "$#" -ge 2 ] || { echo "--xcode-configuration needs a value" >&2; exit 2; }
            XCODE_CONFIGURATION="$2"
            shift 2
            ;;
        --destination)
            [ "$#" -ge 2 ] || { echo "--destination needs a value" >&2; exit 2; }
            XCODE_DESTINATION="$2"
            shift 2
            ;;
        --version)
            [ "$#" -ge 2 ] || { echo "--version needs a value" >&2; exit 2; }
            VERSION="$2"
            shift 2
            ;;
        --build-version)
            [ "$#" -ge 2 ] || { echo "--build-version needs a value" >&2; exit 2; }
            BUILD_VERSION="$2"
            shift 2
            ;;
        --models-dir)
            [ "$#" -ge 2 ] || { echo "--models-dir needs a path" >&2; exit 2; }
            MODEL_SOURCE="$2"
            if [ "$SPECIALIST_DIR_EXPLICIT" -eq 0 ]; then
                SPECIALIST_MODEL_SOURCE="$MODEL_SOURCE/specialists"
            fi
            shift 2
            ;;
        --include-models)
            INCLUDE_MODELS=1
            shift
            ;;
        --specialists-dir)
            [ "$#" -ge 2 ] || { echo "--specialists-dir needs a path" >&2; exit 2; }
            SPECIALIST_MODEL_SOURCE="$2"
            SPECIALIST_DIR_EXPLICIT=1
            shift 2
            ;;
        --include-specialists)
            INCLUDE_SPECIALISTS=1
            shift
            ;;
        --runtime-dir)
            [ "$#" -ge 2 ] || { echo "--runtime-dir needs a path" >&2; exit 2; }
            RUNTIME_SOURCE="$2"
            shift 2
            ;;
        --include-runtime)
            INCLUDE_RUNTIME=1
            shift
            ;;
        --no-dmg)
            MAKE_DMG=0
            shift
            ;;
        --install)
            INSTALL_APP=1
            shift
            ;;
        --open)
            OPEN_APP=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [ "$POSITIONAL_BUILD_DIR" -eq 1 ]; then
                echo "only one build directory may be supplied" >&2
                exit 2
            fi
            BUILD_DIR="$1"
            POSITIONAL_BUILD_DIR=1
            if [ "$BUILD_SYSTEM_EXPLICIT" -eq 0 ]; then
                BUILD_SYSTEM="swiftpm"
            fi
            shift
            ;;
    esac
done

case "$BUILD_SYSTEM" in
    xcode|swiftpm) ;;
    *)
        echo "invalid build system: $BUILD_SYSTEM (expected xcode or swiftpm)" >&2
        exit 2
        ;;
esac

# Re-signing an app ad hoc on every build changes its Keychain code
# requirement. That makes macOS ask again for the same catalog item and can
# look like a prompt loop. Prefer a stable local Developer ID identity, then
# an Apple Development identity; callers and CI can still override this with
# CODESIGN_IDENTITY, and ad-hoc remains the fallback when no identity exists.
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
fi
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
fi
IDENTITY="${IDENTITY:--}"

# Accept the short selectors commonly used in Xcode settings while resolving
# them to one concrete certificate for the final bundle signature.
case "$IDENTITY" in
    "Developer ID Application"*)
        RESOLVED_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
        [ -z "$RESOLVED_IDENTITY" ] || IDENTITY="$RESOLVED_IDENTITY"
        ;;
    "Apple Development"*)
        RESOLVED_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
        [ -z "$RESOLVED_IDENTITY" ] || IDENTITY="$RESOLVED_IDENTITY"
        ;;
esac

XCODE_DEVELOPMENT_TEAM="${LIBRARIAN_XCODE_DEVELOPMENT_TEAM:-${DEVELOPMENT_TEAM:-}}"
if [ "$IDENTITY" != "-" ] && [ -z "$XCODE_DEVELOPMENT_TEAM" ]; then
    # The team identifier is the certificate OU. This keeps the packager
    # portable across developer accounts without hard-coding the current
    # account's team into the repository.
    CERT_SUBJECT="$(security find-certificate -c "$IDENTITY" -a -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null || true)"
    XCODE_DEVELOPMENT_TEAM="$(printf '%s\n' "$CERT_SUBJECT" \
        | sed -n 's/.*OU[[:space:]]*=[[:space:]]*\([^,]*\).*/\1/p' | head -1)"
fi

case "$BUILD_DIR" in
    /*) ;;
    *) BUILD_DIR="$ROOT_DIR/$BUILD_DIR" ;;
esac
case "$OUT_DIR" in
    /*) ;;
    *) OUT_DIR="$ROOT_DIR/$OUT_DIR" ;;
esac
case "$STAGE_DIR" in
    /*) ;;
    *) STAGE_DIR="$ROOT_DIR/$STAGE_DIR" ;;
esac
case "$MODEL_SOURCE" in
    /*) ;;
    *) MODEL_SOURCE="$ROOT_DIR/$MODEL_SOURCE" ;;
esac
case "$SPECIALIST_MODEL_SOURCE" in
    /*) ;;
    *) SPECIALIST_MODEL_SOURCE="$ROOT_DIR/$SPECIALIST_MODEL_SOURCE" ;;
esac
case "$RUNTIME_SOURCE" in
    /*) ;;
    *) RUNTIME_SOURCE="$ROOT_DIR/$RUNTIME_SOURCE" ;;
esac
case "$XCODE_DERIVED_DATA_DIR" in
    /*) ;;
    *) XCODE_DERIVED_DATA_DIR="$ROOT_DIR/$XCODE_DERIVED_DATA_DIR" ;;
esac
case "$XCODE_ARCHIVE_DIR" in
    /*) ;;
    *) XCODE_ARCHIVE_DIR="$ROOT_DIR/$XCODE_ARCHIVE_DIR" ;;
esac

if [ -z "$VERSION" ] && [ -f "$ROOT_DIR/VERSION" ]; then
    VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
fi
VERSION="${VERSION:-0.1.0}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?([.-][A-Za-z0-9.-]+)?$ ]] || {
    echo "invalid app version: $VERSION" >&2
    exit 2
}
[[ "$BUILD_VERSION" =~ ^[0-9]+([.][0-9]+)*$ ]] || {
    echo "invalid bundle build version: $BUILD_VERSION" >&2
    exit 2
}

BUILD_BINARY=""
RESOURCE_SEARCH_ROOT="$BUILD_DIR"
if [ "$BUILD_SYSTEM" = "xcode" ]; then
    XCODE_ARCHIVE_PATH="$XCODE_ARCHIVE_DIR/PrivateLibrarian.xcarchive"
    mkdir -p "$XCODE_DERIVED_DATA_DIR" "$XCODE_ARCHIVE_DIR"
    rm -rf "$XCODE_ARCHIVE_PATH"

    # Xcode package targets do not have an .xcodeproj, but xcodebuild still
    # provides the LibrarianApp scheme and archives it with the repository's
    # macOS package settings. Manual signing is intentional: automatic
    # signing tries to create provisioning settings for every SwiftPM target.
    XCODE_ARGS=(
        xcodebuild
        -scheme "$APP_EXECUTABLE"
        -configuration "$XCODE_CONFIGURATION"
        -destination "$XCODE_DESTINATION"
        -derivedDataPath "$XCODE_DERIVED_DATA_DIR"
        -archivePath "$XCODE_ARCHIVE_PATH"
    )
    if [ "$IDENTITY" = "-" ]; then
        XCODE_ARGS+=(CODE_SIGNING_ALLOWED=NO)
    else
        XCODE_IDENTITY="$IDENTITY"
        case "$IDENTITY" in
            Apple\ Development:*) XCODE_IDENTITY="Apple Development" ;;
            Developer\ ID\ Application:*) XCODE_IDENTITY="Developer ID Application" ;;
        esac
        XCODE_ARGS+=(
            CODE_SIGN_STYLE=Manual
            CODE_SIGNING_ALLOWED=YES
            CODE_SIGN_IDENTITY="$XCODE_IDENTITY"
        )
        if [ -n "$XCODE_DEVELOPMENT_TEAM" ]; then
            XCODE_ARGS+=(DEVELOPMENT_TEAM="$XCODE_DEVELOPMENT_TEAM")
        fi
    fi
    "${XCODE_ARGS[@]}" archive
    BUILD_BINARY="$XCODE_ARCHIVE_PATH/Products/usr/local/bin/$APP_EXECUTABLE"
    RESOURCE_SEARCH_ROOT="$XCODE_DERIVED_DATA_DIR"
else
    BUILD_BINARY="$BUILD_DIR/$APP_EXECUTABLE"
    if [ ! -x "$BUILD_BINARY" ] && [ "$BUILD_DIR" = "$ROOT_DIR/.build/release" ]; then
        # SwiftPM uses both .build/release and .build/<triple>/release layouts
        # across supported toolchains. Preserve the documented command when
        # the latter is the layout on this host.
        FALLBACK_BINARY="$(find "$ROOT_DIR/.build" -mindepth 2 -maxdepth 2 \
            -type f -path '*/release/LibrarianApp' -print -quit)"
        if [ -n "$FALLBACK_BINARY" ]; then
            BUILD_DIR="$(dirname "$FALLBACK_BINARY")"
            BUILD_BINARY="$FALLBACK_BINARY"
        fi
    fi
    if [ ! -x "$BUILD_BINARY" ]; then
        echo "missing executable: $BUILD_BINARY" >&2
        echo "Build it first with: swift build -c release, or rerun without a positional build directory to use Xcode." >&2
        exit 1
    fi
fi
[ -x "$BUILD_BINARY" ] || {
    echo "Xcode archive did not produce an executable: $BUILD_BINARY" >&2
    exit 1
}

mkdir -p "$ROOT_DIR/.build" "$OUT_DIR" "$STAGE_DIR"
APP_BUNDLE="$STAGE_DIR/$APP_BUNDLE_NAME"
RESOURCES="$APP_BUNDLE/Contents/Resources"
MACOS="$APP_BUNDLE/Contents/MacOS"
DMG_PATH="$OUT_DIR/PrivateLibrarian-$VERSION.dmg"
DMG_SOURCE_DIR=""
ASSET_CATALOG="$ROOT_DIR/Sources/LibrarianApp/Assets.xcassets"
ASSET_PARTIAL_INFO="$ROOT_DIR/.build/private-librarian-assets-partial-info.plist"

cleanup_dmg_source() {
    if [ -n "$DMG_SOURCE_DIR" ] && [ -d "$DMG_SOURCE_DIR" ]; then
        rm -rf "$DMG_SOURCE_DIR"
    fi
}
trap cleanup_dmg_source EXIT

# `dist/` is a release-output directory, not a second installation location.
# Move any old app with this bundle identifier from the old packager to an
# ignored, recoverable archive before creating the new DMG. Names are not a
# safe discriminator because Finder copies and older scripts used variants.
LEGACY_ARCHIVE_DIR=""
while IFS= read -r -d '' stale_app; do
    [ "$stale_app" = "$APP_BUNDLE" ] && continue
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$stale_app/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$bundle_id" = "$BUNDLE_IDENTIFIER" ]; then
        if [ -z "$LEGACY_ARCHIVE_DIR" ]; then
            LEGACY_ARCHIVE_DIR="$(mktemp -d "$ROOT_DIR/.build/private-librarian-legacy-dist.XXXXXX")"
        fi
        mv "$stale_app" "$LEGACY_ARCHIVE_DIR/"
        echo "moved stale generated bundle to: $LEGACY_ARCHIVE_DIR/$(basename "$stale_app")"
    fi
done < <(find "$OUT_DIR" -maxdepth 1 \( -type d -o -type l \) -name '*.app' -print0)

MODEL_PYTHON=""
SPECIALIST_MODELS=()
if [ "$INCLUDE_MODELS" -eq 1 ] || [ "$INCLUDE_SPECIALISTS" -eq 1 ]; then
    MODEL_PYTHON="${LIBRARIAN_MODEL_PYTHON:-}"
    if [ -z "$MODEL_PYTHON" ] && [ -x "$RUNTIME_SOURCE/bin/python3" ]; then
        MODEL_PYTHON="$RUNTIME_SOURCE/bin/python3"
    fi
    if [ -z "$MODEL_PYTHON" ]; then
        MODEL_PYTHON="$(command -v python3 || true)"
    fi
    [ -x "$MODEL_PYTHON" ] || {
        echo "cannot verify models: set LIBRARIAN_MODEL_PYTHON or install Python 3" >&2
        exit 1
    }
    # Validate all requested large inputs before replacing the current
    # generated app.
    if [ "$INCLUDE_MODELS" -eq 1 ]; then
        "$MODEL_PYTHON" "$ROOT_DIR/scripts/provision_image_models.py" \
            --all --verify-only --models-dir "$MODEL_SOURCE"
    fi
    if [ "$INCLUDE_SPECIALISTS" -eq 1 ]; then
        for model in \
            siglip2-so400m-naflex \
            dinov3-vitb16-lvd1689m \
            paddleocr-vl-1.6 \
            minicpm-v-4.6 \
            ling-3.0-tiny \
            lfm2.5-vl-3b \
            internvl3.5-4b \
            mimo-vl-7b-rl-2508; do
            model_path="$SPECIALIST_MODEL_SOURCE/$model"
            if [ ! -e "$model_path" ] && [ ! -L "$model_path" ]; then
                continue
            fi
            if [ "$(uname -s)" = "Darwin" ] && [ "$model" = "paddleocr-vl-1.6" ]; then
                echo "skipping unsupported macOS specialist checkpoint: $model" >&2
                continue
            fi
            if [ ! -d "$model_path" ] || [ -L "$model_path" ]; then
                echo "specialist checkpoint is not a real directory: $model_path" >&2
                exit 1
            fi
            "$MODEL_PYTHON" "$ROOT_DIR/scripts/provision_specialist_models.py" \
                --model "$model" --verify-only --models-dir "$SPECIALIST_MODEL_SOURCE"
            SPECIALIST_MODELS+=("$model")
        done
        if [ "${#SPECIALIST_MODELS[@]}" -eq 0 ]; then
            echo "--include-specialists requested, but no specialist checkpoints were found in: $SPECIALIST_MODEL_SOURCE" >&2
            echo "Provision one with: scripts/setup_models.sh --specialist-profile embeddings" >&2
            exit 1
        fi
    fi
fi

if [ "$INCLUDE_RUNTIME" -eq 1 ]; then
    [ -x "$RUNTIME_SOURCE/bin/python3" ] || {
        echo "missing model runtime: $RUNTIME_SOURCE/bin/python3" >&2
        echo "Run scripts/setup_models.sh first or pass --runtime-dir PATH." >&2
        exit 1
    }
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$RESOURCES/scripts"
install -m 0555 "$BUILD_BINARY" "$MACOS/$APP_EXECUTABLE"
install -m 0444 "$ROOT_DIR/scripts/embed.py" "$RESOURCES/scripts/embed.py"
if [ -f "$ROOT_DIR/scripts/specialist.py" ]; then
    install -m 0444 "$ROOT_DIR/scripts/specialist.py" "$RESOURCES/scripts/specialist.py"
fi

# The release bundle is assembled from the archived executable, so compile
# the asset catalog explicitly instead of relying on SwiftPM's resource bundle
# layout. This keeps the app icon and accent color in the actual .app payload.
[ -d "$ASSET_CATALOG" ] || {
    echo "missing asset catalog: $ASSET_CATALOG" >&2
    exit 1
}
xcrun actool \
    --compile "$RESOURCES" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --accent-color AccentColor \
    --output-partial-info-plist "$ASSET_PARTIAL_INFO" \
    "$ASSET_CATALOG" >/dev/null
[ -f "$RESOURCES/Assets.car" ] || {
    echo "asset catalog compilation did not produce Assets.car" >&2
    exit 1
}
[ -f "$RESOURCES/AppIcon.icns" ] || {
    echo "asset catalog compilation did not produce AppIcon.icns" >&2
    exit 1
}

# SwiftPM emits the target resource bundle beside the executable. Keep it in
# the app even though the current UI only needs the executable; this preserves
# Assets.xcassets and future Bundle.module resources in the distributable.
RESOURCE_BUNDLE="$(find "$RESOURCE_SEARCH_ROOT" -type d -name '*LibrarianApp.bundle' -print -quit)"
if [ -n "$RESOURCE_BUNDLE" ]; then
    ditto "$RESOURCE_BUNDLE" "$RESOURCES/$(basename "$RESOURCE_BUNDLE")"
fi

if [ "$INCLUDE_MODELS" -eq 1 ]; then
    mkdir -p "$RESOURCES/Models"
    for model in clip-vit-base-patch32 all-MiniLM-L6-v2; do
        ditto "$MODEL_SOURCE/$model" "$RESOURCES/Models/$model"
    done
fi

if [ "$INCLUDE_SPECIALISTS" -eq 1 ]; then
    mkdir -p "$RESOURCES/Models/specialists"
    for model in "${SPECIALIST_MODELS[@]}"; do
        ditto "$SPECIALIST_MODEL_SOURCE/$model" "$RESOURCES/Models/specialists/$model"
    done
fi

if [ "$INCLUDE_RUNTIME" -eq 1 ]; then
    ditto "$RUNTIME_SOURCE" "$RESOURCES/model-runtime"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Private Librarian</string>
    <key>CFBundleDisplayName</key><string>Private Librarian</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleExecutable</key><string>$APP_EXECUTABLE</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
EOF

plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null
ENTITLEMENTS="$ROOT_DIR/Sources/LibrarianApp/Entitlements.plist.in"
[ -f "$ENTITLEMENTS" ] || { echo "missing entitlements template: $ENTITLEMENTS" >&2; exit 1; }
SIGNED_ENTITLEMENTS="$ROOT_DIR/.build/private-librarian-signed-entitlements.plist"
mkdir -p "$(dirname "$SIGNED_ENTITLEMENTS")"
cp "$ENTITLEMENTS" "$SIGNED_ENTITLEMENTS"
# Do not invent restricted application-identifier or keychain-access-groups
# entitlements here. Apple requires those values to be backed by a matching
# provisioning profile; a manually signed sandbox app without that profile is
# rejected by AMFI at launch even though codesign --verify succeeds. The
# data-protection Keychain uses the app's default sandbox namespace, and the
# stable certificate + bundle identifier are sufficient for this single app.
plutil -lint "$SIGNED_ENTITLEMENTS" >/dev/null
codesign --force --sign "$IDENTITY" --timestamp=none --options runtime \
    --entitlements "$SIGNED_ENTITLEMENTS" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

if [ "$MAKE_DMG" -eq 1 ]; then
    DMG_SOURCE_DIR="$(mktemp -d "$ROOT_DIR/.build/private-librarian-dmg.XXXXXX")"
    # Keep the app and the Applications alias at the volume root so Finder
    # presents the conventional drag-to-install release surface. The signed
    # bundle itself remains the only app payload and is removed from staging
    # after the image is verified.
    ditto "$APP_BUNDLE" "$DMG_SOURCE_DIR/$APP_BUNDLE_NAME"
    ln -s /Applications "$DMG_SOURCE_DIR/Applications"
    rm -f "$DMG_PATH"
    hdiutil create -quiet -volname "Private Librarian $VERSION" \
        -srcfolder "$DMG_SOURCE_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null
    hdiutil verify -quiet "$DMG_PATH" >/dev/null
fi

if [ "$INSTALL_APP" -eq 1 ]; then
    rm -rf "$INSTALL_PATH"
    ditto "$APP_BUNDLE" "$INSTALL_PATH"
    codesign --verify --deep --strict "$INSTALL_PATH"
fi

if [ "$OPEN_APP" -eq 1 ]; then
    if [ "$INSTALL_APP" -eq 1 ]; then
        /usr/bin/open -n "$INSTALL_PATH"
    else
        /usr/bin/open -n "$APP_BUNDLE"
    fi
fi

# A normal release leaves only the DMG in dist/ and the installed app (when
# requested). Keep the app only for an explicit --no-dmg development output or
# when --open needs a non-installed bundle to remain available.
KEEP_STAGE=0
if [ "$MAKE_DMG" -eq 0 ] && [ "$INSTALL_APP" -eq 0 ]; then
    KEEP_STAGE=1
fi
if [ "$OPEN_APP" -eq 1 ] && [ "$INSTALL_APP" -eq 0 ]; then
    KEEP_STAGE=1
fi
if [ "$KEEP_STAGE" -eq 0 ]; then
    rm -rf "$APP_BUNDLE"
fi

if [ "$KEEP_STAGE" -eq 1 ]; then
    echo "packaged app: $APP_BUNDLE"
else
    echo "staged app verified and removed: $APP_BUNDLE"
fi
if [ "$MAKE_DMG" -eq 1 ]; then
    echo "packaged DMG: $DMG_PATH"
    shasum -a 256 "$DMG_PATH"
fi
if [ "$INSTALL_APP" -eq 1 ]; then
    echo "installed app: $INSTALL_PATH"
fi
if [ "$KEEP_STAGE" -eq 0 ]; then
    echo "release output: $OUT_DIR (DMG only)"
fi
