// swift-tools-version:5.9
// Private Local Librarian — hardened, offline, read-only file librarian.
import PackageDescription

let sqlcipherCSettings: [CSetting] = [
    .define("NDEBUG"),
    // SwiftPM debug builds compile with -O0 and no NDEBUG; without it the
    // amalgamation's assert()s stay enabled (its internal NDEBUG logic is
    // skipped because <assert.h> is included before it via the CommonCrypto
    // provider), and asserts reference SQLITE_DEBUG-only struct members.
    .define("SQLITE_HAS_CODEC"),
    .define("SQLITE_ENABLE_FTS5"),
    .define("SQLCIPHER_CRYPTO_CC"),          // Apple CommonCrypto provider
    .define("SQLITE_TEMP_STORE", to: "2"),
    .define("SQLITE_EXTRA_INIT", to: "sqlcipher_extra_init"),
    .define("SQLITE_EXTRA_SHUTDOWN", to: "sqlcipher_extra_shutdown"),
    .define("SQLITE_THREADSAFE", to: "1"),
]

let sqlcipherLinker: [LinkerSetting] = [
    .linkedFramework("Security"),
    .linkedFramework("CoreFoundation"),
]

let package = Package(
    name: "PrivateLibrarian",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LibrarianCore", targets: ["LibrarianCore"]),
        .executable(name: "librarian-cli", targets: ["librarian-cli"]),
        .executable(name: "LibrarianApp", targets: ["LibrarianApp"]),
    ],
    targets: [
        // C target that COMPILES the vendored SQLCipher amalgamation
        // (encrypted SQLite + FTS5, CommonCrypto provider). This is the only
        // sqlite in the binary — the system libsqlite3 must never be linked.
        .target(
            name: "SQLCipher",
            path: "ThirdParty/sqlcipher",
            exclude: ["LICENSE_SQLCIPHER.md", "LICENSE_SQLITE.md", "PROVENANCE.md"],
            publicHeadersPath: "include",
            cSettings: sqlcipherCSettings,
            linkerSettings: sqlcipherLinker
        ),
        .target(
            name: "LibrarianCore",
            dependencies: ["SQLCipher"],
            path: "Sources/LibrarianCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "librarian-cli",
            dependencies: ["LibrarianCore"],
            path: "Sources/librarian-cli"
        ),
        .executableTarget(
            name: "LibrarianApp",
            dependencies: ["LibrarianCore"],
            path: "Sources/LibrarianApp",
            resources: [
                .process("Assets.xcassets"),
                .copy("Entitlements.plist.in"),
                .copy("Info.plist.in"),
            ]
        ),
        .testTarget(
            name: "LibrarianTests",
            dependencies: ["LibrarianCore"],
            path: "Tests/LibrarianTests"
        ),
    ]
)
