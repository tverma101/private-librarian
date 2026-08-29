#!/usr/bin/env python3
from pathlib import Path

path = Path("Package.swift")
text = path.read_text()
old = '''            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
'''
new = '''            swiftSettings: [
                // Works in Swift 5 mode and remains valid when the package is
                // explicitly compiled in Swift 6 language mode.
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
'''
if text.count(old) != 1:
    raise SystemExit(f"expected one StrictConcurrency manifest block, found {text.count(old)}")
path.write_text(text.replace(old, new, 1))
print("Swift 6-compatible strict concurrency setting applied")
