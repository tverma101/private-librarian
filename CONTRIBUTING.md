# Contributing

Private Librarian is still an alpha project, but outside bug reports, tests, benchmarks, and focused pull requests are welcome.

## Before you start

Check the open issues and pull requests first. For a small bug fix, you can usually go straight to a pull request. For a larger feature or architecture change, open an issue first so the work does not collide with an existing lane.

Keep pull requests focused on one problem. A small change that is easy to review is much more useful than a giant branch that mixes unrelated cleanup, UI work, model changes, and refactors.

## Local setup

The project targets macOS 14 or newer and is built with Swift Package Manager. CI currently uses Xcode 16 on Apple silicon.

```bash
swift build
swift test
bash script/build_and_run.sh
```

Fast mode does not require downloaded AI models. Balanced/Quality model setup is explicit and app-initiated; optional backends must fail closed when they are unavailable.

## Project rules that should not be broken

These are product invariants, not style preferences:

- Analysis of original user files is read-only. `SourceBroker` owns that read boundary and must never hand a write-capable source handle to model or parser code.
- Finder mutation is allowed only through the explicit, reviewed `OrganizationApplier` Apply/Undo workflow. Do not add hidden or automatic moves, renames, deletes, rewrites, permission changes, Finder tags, or xattrs.
- Every Apply move must remain confined to an active user-authorized read/write root, be journaled in the encrypted catalog, and remain undoable according to the Apply contract.
- Analysis and model code should receive broker-owned bytes, derived text, feature data, or decoded PCM rather than source filesystem authority.
- The encrypted catalog is the writable knowledge layer. Organization remains virtual until the user explicitly confirms Apply.
- The app is local-first. Do not add telemetry, cloud inference, update beacons, listeners, or unrelated runtime network access. Outbound networking is reserved for explicit user-initiated model provisioning; normal indexing and inference stay offline.
- Credentials for optional gated model setup belong in Keychain and must not be placed in argv, shell history, UserDefaults, manifests, or logs.
- Symlinks and package boundaries must stay fail-closed.
- Expensive work must stay incremental. An unchanged file should not repeatedly trigger OCR, embeddings, decoding, or ASR.
- Tests should use generated or synthetic fixtures, not files copied from a real Desktop, Downloads folder, class folder, photo library, or other personal source.

If a proposed feature needs to weaken one of these rules, discuss it in an issue before writing the implementation.

## What a good pull request includes

A useful pull request normally has:

1. A plain-English explanation of the problem.
2. A focused implementation.
3. Tests that fail before the fix and pass after it when practical.
4. The exact commands used to verify the change.
5. Documentation updates when behavior, permissions, model requirements, or security boundaries change.

Run at least:

```bash
swift test
```

For packaging, entitlement, model-provider, OCR, media, or security-boundary changes, also run the relevant scripts described in `README.md` and `docs/VERIFICATION.md`.

## Public repository hygiene

Do not commit:

- API keys, tokens, passwords, private keys, certificates, provisioning profiles, or `.env` files;
- downloaded model weights;
- real user documents, screenshots, recordings, databases, or catalog files;
- personal absolute paths or machine-specific identifiers in fixtures;
- third-party code without checking its license and keeping required notices/provenance.

Use neutral synthetic examples such as `/Users/example/...` in tests and documentation.

## Security problems

Do not publish exploit details in a normal issue. Follow the private reporting instructions in `SECURITY.md`.

## License

Private Librarian is licensed under the Apache License 2.0. Keep third-party notices and provenance stored under `ThirdParty/` intact.
