#ifndef LIBRARIAN_SQLCIPHER_SHIM_H
#define LIBRARIAN_SQLCIPHER_SHIM_H

// Public umbrella header of the SQLCipher C target.
//
// The codec APIs (sqlite3_key / sqlite3_key_v2) are declared in sqlite3.h
// only under SQLITE_HAS_CODEC. SwiftPM compiles the *module verification*
// pass of this header without the target's cSettings, so the guard would
// hide them from Swift. The symbols ARE in the compiled object (shim.c and
// sqlite3.c build with SQLITE_HAS_CODEC), so re-declare them here with the
// exact SQLCipher signatures.

#include <sqlite3.h>

#if !defined(SQLITE_HAS_CODEC)
SQLITE_API int sqlite3_key(sqlite3 *db, const void *pKey, int nKey);
SQLITE_API int sqlite3_key_v2(sqlite3 *db, const char *zDbName,
                              const void *pKey, int nKey);
#endif

#endif /* LIBRARIAN_SQLCIPHER_SHIM_H */
