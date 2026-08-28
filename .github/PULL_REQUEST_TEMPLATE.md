## What changed?

Describe the change in plain English.

## Why?

What problem does this solve?

## How was it tested?

List the commands and focused tests you ran.

- [ ] `swift test`
- [ ] Relevant focused tests or verification scripts were run when needed.

## Safety and privacy check

- [ ] This does not add a source-file write, move, rename, delete, tag, permission-change, or xattr path.
- [ ] This does not add runtime network access, telemetry, or cloud inference.
- [ ] Models/decoders receive broker-owned bytes, derived text, feature data, or PCM rather than source filesystem authority.
- [ ] Unchanged files still avoid unnecessary expensive work.
- [ ] Tests and docs contain only synthetic or sanitized data; no secrets, private files, or personal machine paths are included.
- [ ] Any reused third-party code has a compatible license and keeps the required notice/provenance.

If a box does not apply, explain why instead of checking it blindly.

## Notes for reviewers

Call out anything risky, intentionally deferred, benchmark-sensitive, or dependent on an optional local model/provider.
