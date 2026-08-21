# Vendored SQLCipher 4.17.0 amalgamation

- Source: https://github.com/sqlcipher/sqlcipher tag `v4.17.0`
- Tarball SHA-256: `79c0e164b9c059e7487bf8f29272f601cca5f3312cc267461f81e349962a5058`
  (https://github.com/sqlcipher/sqlcipher/archive/refs/tags/v4.17.0.tar.gz)
- Amalgamation generated locally from the verified tarball with
  `./configure && make sqlite3.c` (tclsh 8.5.9), then copied unmodified.
- Licenses: `LICENSE_SQLCIPHER.md` (BSD-style) and `LICENSE_SQLITE.md` (public domain)
  copied verbatim from the same tag.

## Compile flags required (already set in Package.swift)

```
-DSQLITE_HAS_CODEC
-DSQLITE_ENABLE_FTS5
-DSQLCIPHER_CRYPTO_CC          # Apple CommonCrypto provider — no OpenSSL dependency
-DSQLITE_TEMP_STORE=2
-DSQLITE_EXTRA_INIT=sqlcipher_extra_init
-DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown
```

Link: `-framework Security -framework CoreFoundation` (CommonCrypto is auto-linked).

## Verified locally (scripts/sqlcipher_smoke.c)

- open + `sqlite3_key` + write/read round-trip: OK
- reopen without key: denied, `SQLITE_NOTADB` ("file is not a database")
- reopen with wrong key: denied, `SQLITE_NOTADB`
- on-disk header is NOT plaintext `"SQLite format 3\0"`
- FTS5 virtual table creation works in this build
