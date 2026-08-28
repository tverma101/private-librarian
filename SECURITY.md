# Security

Private Librarian is designed around a narrow security rule: source files are readable, never writable, and organization lives in a separate encrypted catalog.

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

- any source-file write, rename, delete, permission change, Finder tag, or xattr path;
- escaping an authorized root through symlinks or path races;
- bypassing the security-scoped folder permission model;
- leaking catalog contents, model inputs, source paths, or user data over the network;
- loading an untrusted or unverified model artifact as if it were trusted;
- exposing stale or corrupted catalog data as current after an indexing failure;
- weakening SQLCipher/Keychain protection for the catalog.

## Supported versions

The project is pre-1.0 and currently supports the latest code on the default branch plus the active integration pull request. There is no long-term support policy yet.
