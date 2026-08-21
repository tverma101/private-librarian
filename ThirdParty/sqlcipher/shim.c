#include <sqlite3.h>

// Thin re-export of the vendored SQLCipher amalgamation so SwiftPM can link it
// once for every dependent target. All flags come from Package.swift.

// Compile-time guard: this build must be the encrypted codec build with FTS5.
// (Kept in the .c file — module verification compiles headers without the
// target's cSettings, so a header guard would false-fire there.)
#ifndef SQLITE_HAS_CODEC
#error "SQLCipher shim requires SQLITE_HAS_CODEC"
#endif
#ifndef SQLITE_ENABLE_FTS5
#error "SQLCipher shim requires SQLITE_ENABLE_FTS5"
#endif

__attribute__((visibility("default"))) const char * librarian_sqlite_libversion(void) {
    return sqlite3_libversion();
}
