#!/usr/bin/env python3
from pathlib import Path

path = Path("Sources/LibrarianCore/ImageJunkScorer.swift")
text = path.read_text()
old = '''        if let stats {
            if stats.range <= 8 || stats.variance <= 4 {
                score += 0.65
                reasons.append("near-blank")
            } else if stats.occupiedBins <= 3 || stats.variance <= 18 {
                score += 0.35
                reasons.append("very-low-information")
            }
        }
'''
new = '''        if let stats {
            // A tiny thumbnail can alias a real icon, gradient or high-frequency
            // graphic into something that looks blank. Thumbnail sparsity is
            // therefore strong junk evidence only when the ORIGINAL image is
            // objectively disposable-looking too (very small or extreme shape).
            let objectivelyDisposableShape =
                maxSide <= 128 || pixelCount <= 16_384 || aspect >= 10
            if stats.range <= 8 || stats.variance <= 4 {
                score += objectivelyDisposableShape ? 0.65 : 0.10
                reasons.append("near-blank")
            } else if stats.occupiedBins <= 3 || stats.variance <= 18 {
                score += objectivelyDisposableShape ? 0.20 : 0.05
                reasons.append("very-low-information")
            }
        }
'''
# The prior verifier may already have reduced only the low-information weight.
old_tuned = old.replace('score += 0.35', 'score += 0.20').replace(
    '            } else if stats.occupiedBins <= 3 || stats.variance <= 18 {\n                score += 0.20\n',
    '            } else if stats.occupiedBins <= 3 || stats.variance <= 18 {\n                // Low diversity alone is weak evidence: icons, gradients and\n                // deliberately simple graphics can all look sparse after a tiny\n                // thumbnail pass. It may support size/aspect evidence but cannot\n                // make an otherwise useful small image cross the junk threshold.\n                score += 0.20\n'
)
if old in text:
    text = text.replace(old, new, 1)
elif old_tuned in text:
    text = text.replace(old_tuned, new, 1)
elif 'let objectivelyDisposableShape =' in text:
    print("objective junk gate already applied")
    raise SystemExit(0)
else:
    raise SystemExit("expected image information scoring block not found")
path.write_text(text)
print("required objective garbage evidence for thumbnail sparsity")
