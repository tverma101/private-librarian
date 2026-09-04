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

The optional Hugging Face token was a third prompt source: opening Settings
automatically read the token even though DINOv3 setup had not been requested.
Settings now displays an inert status until the user explicitly starts the
optional gated-model install. The token is read from Keychain only on that
button action. Normal app-owned catalog reads also set a non-interactive
authentication context, so a stale ACL returns a visible recovery state rather
than presenting a login-keychain sheet during startup or view refresh.

## Recovery

`scripts/package_app.sh` now archives the app through Xcode and automatically
selects a stable local Developer ID or Apple Development identity, with
`CODESIGN_IDENTITY` available for an explicit release identity. It does not
inject restricted Keychain-group or data-protection entitlements without a
matching provisioning profile. The app-owned catalog key uses a dedicated
stable traditional Keychain service, isolated from the legacy CLI service. It
falls back to ad-hoc only when no certificate is installed.

`CatalogKeychain.loadOrCreate()` first reads the new app-owned Keychain service,
but the GUI startup path does not call the legacy lookup automatically. When
an existing encrypted catalog has no app-owned key, the window renders with a
visible **Migrate Existing Catalog** action. That action performs one legacy
lookup, preserves the same 32-byte key, and writes it to the new app-owned item.
Choose **Always Allow** on that one prompt. Afterward, normal launches use the
new item and do not touch the legacy ACL. A denial is cached for the process;
relaunching is the deliberate retry boundary.

The CLI no longer accesses the GUI Keychain at all. It requires
`LIBRARIAN_CATALOG_KEY` for catalog commands, so debug/CI binaries cannot
trigger a Keychain prompt.

The existing catalog key is preserved. Do not delete the Keychain item or
`catalog.db` merely as a prompt workaround: rotating either one makes the
encrypted catalog unreadable without a migration path. If the catalog is
known to be disposable, a deliberate reset may move exactly `catalog.db`,
`catalog.db-wal`, and `catalog.db-shm` out of the app container while the app
is quit; leave the model/runtime directories and source bookmarks alone. The
next launch creates a new app-owned item and encrypted catalog without
consulting the legacy service.

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
does not prompt, and opening Settings does not read the optional token. A
post-migration prompt-free operation still requires the user to approve the one
explicit legacy migration action.

## Residual boundary

The explicit migration action's access to an old item created by a different
signing identity still requires one user approval because bypassing that ACL
would defeat macOS Keychain protection. Choose **Always Allow** once, quit, and
relaunch. Future rebuilds retain the stable signing identity and use the
app-owned item. A Developer ID identity, notarization, and stapling are still
required for public distribution.

## When every launch prompts and then fails (wedged ACL)

If an existing app-owned item was created by an ad-hoc-signed build, the item's
ACL designates that dead binary hash. Repackaging with the stable Apple
Development identity fixes all FUTURE builds, but the first launch of the
newly signed app is still a new client for the EXISTING item and prompts once.
Choosing **Always Allow** adds the stable team identity to the item's trust and
ends the prompting permanently.

If the prompt instead fails repeatedly (denied, canceled, or errored), the app
now offers an explicit recovery action in both the home catalog card and the
advanced library: **Key Still Blocked? Reset Catalog Key…** (two-step
confirmation). It:

1. moves `catalog.db`, `catalog.db-wal`, and `catalog.db-shm` aside as
   `catalog.locked-<timestamp>.db*` — never deletes them;
2. deletes only the app-owned catalog key item (`destroyAppOwned()`); the
   legacy login-keychain item is untouched;
3. creates a new app-owned key and encrypted catalog created by the currently
   signed binary, whose ACL is then stable across rebuilds signed with the same
   identity; authorized source folders are kept so re-indexing needs no
   re-picking.

The locked-aside catalog stays decryptable forever with its old key, so this is
recoverable, not data loss.

## Dev builds

`script/build_and_run.sh --debug` re-signs the freshly linked SwiftPM binary
with the stable Apple Development identity. Plain `swift build` output stays
ad-hoc signed; launching `LibrarianApp` from `.build/debug/` directly will
therefore prompt for the dev-namespace keychain item on each rebuild — use the
script, or re-sign manually, if you run dev builds against a real catalog.
