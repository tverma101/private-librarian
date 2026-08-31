#!/usr/bin/env python3
from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one match in {path}, found {count}: {old[:120]!r}")
    p.write_text(text.replace(old, new, 1))


APP = "Sources/LibrarianApp/PrivateLibrarianApp.swift"
PACKAGE = "scripts/package_app.sh"

replace_once(
    APP,
    '''        WindowGroup("Private Librarian", id: "main") {
            MagicContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification)) { _ in
                    model.shutdown()
                }
        }
        .defaultSize(width: 1100, height: 720)
''',
    '''        WindowGroup("Private Librarian", id: "main") {
            CleanerHomeView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 600)
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification)) { _ in
                    model.shutdown()
                }
        }
        .defaultSize(width: 820, height: 760)
'''
)

replace_once(
    APP,
    '''        Settings {
            LibrarianSettingsView()
                .environmentObject(model)
        }
''',
    '''        WindowGroup("Advanced Library", id: "advanced-library") {
            MagicContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1100, height: 720)

        Settings {
            SimpleSettingsView()
                .environmentObject(model)
        }
'''
)

replace_once(
    PACKAGE,
    '''mkdir -p "$MACOS" "$RESOURCES/scripts"
install -m 0555 "$BUILD_BINARY" "$MACOS/$APP_EXECUTABLE"
install -m 0444 "$ROOT_DIR/scripts/embed.py" "$RESOURCES/scripts/embed.py"
if [ -f "$ROOT_DIR/scripts/specialist.py" ]; then
    install -m 0444 "$ROOT_DIR/scripts/specialist.py" "$RESOURCES/scripts/specialist.py"
fi
''',
    '''mkdir -p "$MACOS" "$RESOURCES/scripts"
install -m 0555 "$BUILD_BINARY" "$MACOS/$APP_EXECUTABLE"
install -m 0444 "$ROOT_DIR/scripts/embed.py" "$RESOURCES/scripts/embed.py"
if [ -f "$ROOT_DIR/scripts/specialist.py" ]; then
    install -m 0444 "$ROOT_DIR/scripts/specialist.py" "$RESOURCES/scripts/specialist.py"
fi
# Model provisioning is intentionally an explicit Terminal action. The app's
# runtime network entitlement stays disabled; these helpers are packaged so a
# clean install can bootstrap pinned local models without a source checkout.
install -m 0555 "$ROOT_DIR/scripts/setup_models.sh" "$RESOURCES/scripts/setup_models.sh"
install -m 0444 "$ROOT_DIR/scripts/provision_image_models.py" "$RESOURCES/scripts/provision_image_models.py"
install -m 0444 "$ROOT_DIR/scripts/provision_specialist_models.py" "$RESOURCES/scripts/provision_specialist_models.py"
install -m 0444 "$ROOT_DIR/scripts/model-requirements.txt" "$RESOURCES/scripts/model-requirements.txt"
install -m 0444 "$ROOT_DIR/scripts/specialist-requirements.txt" "$RESOURCES/scripts/specialist-requirements.txt"
'''
)

print("simple UI integration patch applied")
