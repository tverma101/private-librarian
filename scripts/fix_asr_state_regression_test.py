#!/usr/bin/env python3
from pathlib import Path

path = Path("Tests/LibrarianTests/ASRStateRegressionTests.swift")
text = path.read_text()
replacements = [
    ("try makeWAV(seconds: 3, amplitude: 7_000).write", "try Self.makeWAV(seconds: 3, amplitude: 7_000).write"),
    ("try makeWAV(seconds: 4, amplitude: 5_000).write", "try Self.makeWAV(seconds: 4, amplitude: 5_000).write"),
]
for old, new in replacements:
    if text.count(old) != 1:
        raise SystemExit(f"expected exactly one match for {old!r}, found {text.count(old)}")
    text = text.replace(old, new, 1)
path.write_text(text)
print("ASR regression fixture helper calls fixed")
