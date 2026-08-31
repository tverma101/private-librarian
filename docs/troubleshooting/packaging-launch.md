# Packaged app launch failure

## Symptom

The app bundle passed `codesign --verify --deep --strict` and appeared in
`/Applications`, but Launch Services returned `RBSRequestErrorDomain Code=5`
with `Launchd job spawn failed` (POSIX error 163). Direct execution was also
terminated with status 137.

## Root cause

The package script manually added `com.apple.application-identifier`,
`com.apple.developer.team-identifier`, and `keychain-access-groups` to the
signed entitlements. Those are restricted entitlements and require a matching
embedded provisioning profile. The local Apple Development certificate had no
matching profile, so AMFI logged `No matching profile found` and killed the
process before the app could start. A successful `codesign --verify` did not
prove that launch policy would accept the restricted entitlements.

## Recovery

`scripts/package_app.sh` now signs only the profile-free sandbox/read-only
entitlements from `Sources/LibrarianApp/Entitlements.plist.in`. It keeps the
stable Apple Development identity and bundle identifier, and does not invent a
Keychain-sharing or data-protection entitlement that the local signing setup
cannot authorize. The app-owned catalog key uses a dedicated stable
traditional Keychain service instead.

The normal package path also stages the app under ignored `.build/` output,
leaves only `PrivateLibrarian-VERSION.dmg` in `dist/`, and installs one
canonical `/Applications/PrivateLibrarian.app`. Old generated app bundles are
moved to a recoverable ignored archive instead of being left as duplicate
launch targets.

The packager also compiles the checked-in `AppIcon` asset catalog into
`Assets.car` and `AppIcon.icns`, and verifies both resources before signing.
This keeps Finder/Dock resource resolution inside the signed bundle instead of
falling back to an empty or stale app-icon registration.

## Validation

The repaired bundle was rebuilt with `scripts/package_app.sh --xcode --install`.
The installed app passed deep code-sign verification, the sandbox/read-only
entitlement audit, universal `arm64` + `x86_64` inspection, and DMG verification.
`open -n /Applications/PrivateLibrarian.app` returned success and the
`LibrarianApp` process remained alive. Spotlight found only that installed
bundle, and `dist/` contained only the versioned DMG.

## Residual boundary

The current machine has only an Apple Development certificate. `spctl` still
rejects the artifact for public distribution because Developer ID signing,
notarization, and stapling are not available. That is separate from the fixed
local launch failure. An existing legacy catalog still needs the explicit
in-app migration action and one user-approved **Always Allow** Keychain access;
startup no longer probes that legacy item automatically.

If Finder or an Open With list still shows old copies after a prior development
run, inspect LaunchServices first and unregister only the exact stale bundle
paths. Do not reset LaunchServices globally or change the user's default
handler. The current install should be the only registered
`/Applications/PrivateLibrarian.app` path.
