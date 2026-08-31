# Repeated catalog Keychain prompts

## Symptom

Rebuilding or launching the packaged app repeatedly asks for access to the
Private Librarian catalog item in the macOS Keychain.

## Root cause

There were two separate causes:

1. An ad-hoc signature (`codesign -`) changed the app's Keychain code identity
   on each rebuild. macOS then saw the rebuilt bundle as a different client
   even though the bundle identifier and catalog item were unchanged.
2. The existing item was created by the old unsigned CLI. Its login-keychain
   ACL names `/Users/example/Code/private-librarian/.build/arm64-apple-macosx/debug/librarian-cli`
   and a stale code hash; that path no longer exists, so the signed app cannot
   silently inherit the old authorization.

Repeated SwiftUI/AppKit initialization could also retry a failed lookup. The
runtime now caches one success or failure per process.

## Recovery

`scripts/package_app.sh` now archives the app through Xcode and automatically
selects a stable local Developer ID or Apple Development identity, with
`CODESIGN_IDENTITY` available for an explicit release identity. It does not
inject restricted Keychain-group entitlements without a matching provisioning
profile; the data-protection Keychain uses the app's default sandbox
namespace. It falls back to ad-hoc only when no certificate is installed.

`CatalogKeychain.loadOrCreate()` first reads the new data-protection Keychain,
but the GUI startup path does not call the legacy lookup automatically. When
an existing encrypted catalog has no app-owned key, the window renders with a
visible **Migrate Existing Catalog** action. That action performs one legacy
lookup, preserves the same 32-byte key, and writes it to the app-owned item.
Choose **Always Allow** on that one prompt. Afterward, normal launches use the
new item and do not touch the legacy ACL. A denial is cached for the process;
relaunching is the deliberate retry boundary.

The CLI no longer accesses the GUI Keychain at all. It requires
`LIBRARIAN_CATALOG_KEY` for catalog commands, so debug/CI binaries cannot
trigger a Keychain prompt.

The existing catalog key is preserved. Do not delete the Keychain item or
`catalog.db` as a prompt workaround: rotating either one makes the encrypted
catalog unreadable without a migration path.

## Validation

The current local installed artifact is built by the Xcode archive path and
signed with a stable Apple Development identity and contains the expected
sandbox/read-only entitlements and bundle identifier. It has the expected
runtime flag, passes deep code-sign verification,
and the packager leaves only the versioned DMG in `dist/` while the canonical
copy launches from `/Applications/PrivateLibrarian.app`. The Swift suite and
strict-concurrency warnings-as-errors build cover the catalog-keychain call
path and the package remains sandboxed. The old login-keychain ACL was
inspected and confirmed to reference the removed CLI identity; startup itself
does not prompt, and post-migration prompt-free operation still requires the
user to approve the one explicit migration action.

## Residual boundary

The explicit migration action's access to an old item created by a different
signing identity still requires one user approval because bypassing that ACL
would defeat macOS Keychain protection. Choose **Always Allow** once, quit, and
relaunch. Future rebuilds retain the stable signing identity and use the
app-owned item. A Developer ID identity, notarization, and stapling are still
required for public distribution.
