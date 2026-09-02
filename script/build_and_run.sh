#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="LibrarianApp"
BUNDLE_NAME="PrivateLibrarian.app"
BUNDLE_ID="com.tejas.private-librarian"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="/Applications/$BUNDLE_NAME"

cd "$ROOT_DIR"

# Stop only the task-owned verification process so a previous open instance
# cannot hold the generated bundle or make --verify observe the wrong process.
pkill -x "$APP_NAME" 2>/dev/null || true

case "$MODE" in
    --debug|debug)
        swift build
        BUILD_DIR="$(swift build --show-bin-path)"
        BUILD_BINARY="$BUILD_DIR/$APP_NAME"
        # SwiftPM links ad-hoc (hash-signed) binaries: every rebuild becomes a
        # new untrusted Keychain client and prompts for the catalog key. Re-sign
        # with the stable Apple Development identity when one exists so the
        # keychain ACL keeps trusting dev builds across rebuilds.
        DEV_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
        if [ -n "$DEV_IDENTITY" ]; then
            codesign --force --sign "$DEV_IDENTITY" --timestamp=none "$BUILD_BINARY" 2>/dev/null \
                || echo "warning: could not re-sign dev binary; keychain may prompt" >&2
        fi
        exec lldb -- "$BUILD_BINARY"
        ;;
esac

# Use the Xcode-archived, sandboxed, stably signed bundle as the release
# runner. The packager installs one canonical copy and removes its temporary
# staging bundle; it deliberately does not ship librarian-cli or silently
# include model weights.
scripts/package_app.sh --xcode --no-dmg --install

open_app() { /usr/bin/open -n "$APP_BUNDLE"; }

case "$MODE" in
    run)
        open_app
        ;;
    --logs|logs)
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        open_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        open_app
        sleep 1
        pgrep -x "$APP_NAME" >/dev/null
        codesign --verify --deep --strict "$APP_BUNDLE"
        ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac
