## What changed?

Describe the change in plain English.

## Why?

What problem does this solve?

## How was it tested?

List the commands and focused tests you ran.

- [ ] `swift test`
- [ ] Relevant focused tests or verification scripts were run when needed.

## Safety and privacy check

- [ ] Analysis still opens original source files through the read-only `SourceBroker` boundary. If this PR touches Finder mutation, it stays inside the explicit, reviewed, journaled, undoable `OrganizationApplier` Apply/Undo path.
- [ ] This does not add hidden or automatic source-file writes, moves, renames, deletes, tags, permission changes, or xattrs.
- [ ] Normal indexing/inference stays offline. Any network-capable change is limited to an explicit model-provisioning or system-browser action and does not add telemetry, cloud inference, or a network listener.
- [ ] Optional gated-model credentials stay out of argv, UserDefaults, manifests, and logs; use the Keychain/stdin/in-memory credential path.
- [ ] Models/decoders receive broker-owned bytes, derived text, feature data, or PCM rather than source filesystem authority.
- [ ] Unchanged files still avoid unnecessary expensive work.
- [ ] Tests and docs contain only synthetic or sanitized data; no secrets, private files, or personal machine paths are included.
- [ ] Any reused third-party code has a compatible license and keeps the required notice/provenance.

If a box does not apply, explain why instead of checking it blindly.

## Notes for reviewers

Call out anything risky, intentionally deferred, benchmark-sensitive, or dependent on an optional local model/provider.
