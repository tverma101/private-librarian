#!/usr/bin/env python3
"""
Entitlement auditor. Inspects a signed .app (or Mach-O binary) and fails when
production permissions drift from Private Librarian's explicit security model.

The app deliberately has outbound client networking so the user can provision
models from Settings. It never has inbound/server networking. Source folders
use user-selected read/write scope because Apply/Undo can move files only after
confirmation; analysis itself remains read-only by implementation.

Usage: audit_entitlements.py <path-to-app-or-binary> [--expect-hardened]
Exit 0 = pass, 1 = fail.
"""
import re
import subprocess
import sys

FORBIDDEN = [
    "com.apple.security.network.server",
    "com.apple.security.automation.apple-events",
    "com.apple.security.privileged-file-operations",
    "com.apple.security.files.all",
    "com.apple.security.temporary-exception.files.absolute-path.read-write",
    "com.apple.security.personal-information.photos-library",
    "com.apple.security.device.audio-input",
]

REQUIRED_APP = [
    "com.apple.security.app-sandbox",
    "com.apple.security.files.user-selected.read-write",
    "com.apple.security.files.bookmarks.app-scope",
    "com.apple.security.network.client",
]


def entitlements(path):
    out = subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", path],
        capture_output=True, text=True)
    return out.stdout or ""


def has_true(ents, key):
    return re.search(rf"<key>{re.escape(key)}</key>\s*<true/>", ents) is not None


def main():
    if len(sys.argv) < 2:
        print("usage: audit_entitlements.py <app-or-binary> [--expect-hardened]", file=sys.stderr)
        return 2
    path = sys.argv[1]
    expect_hardened = "--expect-hardened" in sys.argv
    ents = entitlements(path)

    if not ents.strip():
        print(f"FAIL: no entitlements found on {path} (unsigned?)")
        return 1

    failures = []
    for key in FORBIDDEN:
        if has_true(ents, key):
            failures.append(f"FORBIDDEN entitlement present: {key}")

    is_app = path.endswith(".app") or "/LibrarianApp" in path
    if is_app:
        for key in REQUIRED_APP:
            if not has_true(ents, key):
                failures.append(f"REQUIRED entitlement missing: {key}")

        # Do not accidentally regress to the old read-only sandbox profile:
        # the app advertises Apply/Undo and needs write authority inside only
        # those roots the user explicitly selected.
        if has_true(ents, "com.apple.security.files.user-selected.read-only"):
            failures.append("legacy user-selected.read-only entitlement is still present")

    if expect_hardened and "com.apple.security.cs.disable-library-validation" in ents:
        failures.append("library validation disabled")

    if failures:
        print("ENTITLEMENT AUDIT FAIL")
        for failure in failures:
            print("  -", failure)
        return 1

    print("ENTITLEMENT AUDIT PASS")
    print("  sandbox:           ", "yes" if has_true(ents, "com.apple.security.app-sandbox") else "n/a")
    print("  selected read/write:", "yes" if has_true(ents, "com.apple.security.files.user-selected.read-write") else "n/a")
    print("  app bookmarks:      ", "yes" if has_true(ents, "com.apple.security.files.bookmarks.app-scope") else "n/a")
    print("  network client:     ", "yes (explicit model setup)" if has_true(ents, "com.apple.security.network.client") else "n/a")
    print("  network server:     ", "absent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
