#!/usr/bin/env python3
from pathlib import Path

path = Path("Sources/LibrarianCore/ImageJunkScorer.swift")
text = path.read_text()
old = '''            } else if stats.occupiedBins <= 3 || stats.variance <= 18 {
                score += 0.35
                reasons.append("very-low-information")
'''
new = '''            } else if stats.occupiedBins <= 3 || stats.variance <= 18 {
                // Low diversity alone is weak evidence: icons, gradients and
                // deliberately simple graphics can all look sparse after a tiny
                // thumbnail pass. It may support size/aspect evidence but cannot
                // make an otherwise useful small image cross the junk threshold.
                score += 0.20
                reasons.append("very-low-information")
'''
if old not in text:
    if "score += 0.20\n                reasons.append(\"very-low-information\")" in text:
        print("junk tuning already applied")
        raise SystemExit(0)
    raise SystemExit("expected low-information score block not found")
path.write_text(text.replace(old, new, 1))
print("tightened low-information junk weight")
