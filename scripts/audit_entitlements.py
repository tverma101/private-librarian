#!/usr/bin/env python3
"""
Entitlement auditor (plan §38). Inspects a signed .app (or any Mach-O binary)
and FAILS if forbidden entitlements are present, or — for the app target —
if required ones are missing.

Usage: audit_entitlements.py <path-to-app-or-binary> [--expect-hardened]
Exit 0 = pass, 1 = fail.
"""
import re
import subprocess
import sys

FORBIDDEN = [
    "com.apple.security.files.user-selected.read-write",
    "com.apple.security.network.client",
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
    "com.apple.security.files.user-selected.read-only",
]


def entitlements(path):
    out = subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", path],
        capture_output=True, text=True)
    return out.stdout or ""


def main():
    path = sys.argv[1]
    expect_hardened = "--expect-hardened" in sys.argv
    ents = entitlements(path)

    if not ents.strip():
        print(f"FAIL: no entitlements found on {path} (unsigned?)")
        return 1

    failures = []
    for f in FORBIDDEN:
        # Match the key with a true value (not <false/>).
        pat = re.compile(rf"<key>{re.escape(f)}</key>\s*<true/>")
        if pat.search(ents):
            failures.append(f"FORBIDDEN entitlement present: {f}")

    is_app = path.endswith(".app") or "/LibrarianApp" in path
    if is_app:
        for r in REQUIRED_APP:
            pat = re.compile(rf"<key>{re.escape(r)}</key>\s*<true/>")
            if not pat.search(ents):
                failures.append(f"REQUIRED entitlement missing: {r}")

    if expect_hardened and "com.apple.security.cs.disable-library-validation" in ents:
        failures.append("library validation disabled")

    if failures:
        print("ENTITLEMENT AUDIT FAIL")
        for f in failures:
            print("  -", f)
        return 1

    print("ENTITLEMENT AUDIT PASS")
    print("  sandbox:        ", "yes" if "app-sandbox</key>" in ents else "n/a (non-app binary)")
    print("  read-write access:", "ABSENT (good)" if "user-selected.read-write" not in ents else "PRESENT (bad)")
    print("  network client: ", "ABSENT (good)" if "network.client" not in ents else "PRESENT (bad)")
    print("  network server: ", "ABSENT (good)" if "network.server" not in ents else "PRESENT (bad)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
