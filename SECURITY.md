# Security

Private Librarian is designed around a narrow security rule: **analysis is read-only; source-file mutation exists only behind an explicit, reviewed Apply/Undo boundary inside folders the user authorized for read/write access.** Search, categories, similarity families, transcripts, corrections, learned rules, and move journals live in a separate encrypted catalog.

The implementation details and threat model are documented in `docs/SECURITY.md`.

## Reporting a vulnerability

Please do not open a normal public issue with exploit details, private files, tokens, or proof-of-concept data that could put users at risk.

For a security vulnerability:

1. Use GitHub's private vulnerability reporting / repository security advisory flow when it is available for this repository.
2. If GitHub does not show a private reporting option, open a public issue that only says you need a private security contact. Do not include the vulnerability details in that issue.

A useful private report includes:

- the affected commit or version;
- the part of the app involved;
- clear reproduction steps using synthetic data where possible;
- the security impact;
- any proposed fix or mitigation.

## High-priority areas

Please treat problems in these areas as security-sensitive:

- any source-file write, rename, move, delete, permission change, Finder tag, or xattr path that bypasses the explicit `OrganizationApplier` Apply/Undo workflow;
- any Apply/Undo operation that escapes the reviewed plan, active authorized root, journal, or conflict checks;
- escaping an authorized root through symlinks or path races;
- bypassing the security-scoped folder permission model or silently falling back to an unscoped raw path;
- leaking catalog contents, model inputs, source paths, credentials, or user data over the network;
- adding cloud inference, telemetry, listeners, or unrelated runtime networking. Outbound networking is reserved for an explicit user-initiated model-provisioning action; normal indexing and inference must remain offline;
- loading an untrusted or unverified model artifact as if it were trusted;
- exposing stale or corrupted catalog data as current after an indexing failure;
- weakening SQLCipher/Keychain protection for the catalog or gated-model credentials.

## Supported versions

The project is pre-1.0 and currently supports the latest code on the default branch plus the active integration pull request. There is no long-term support policy yet.
