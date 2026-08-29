#!/usr/bin/env python3
from pathlib import Path

path = Path("Sources/LibrarianApp/MagicViews.swift")
text = path.read_text()
old = '''                    Text(model.localTranscriptionStatus)
                        .font(.caption2)
                        .foregroundStyle(model.isLocalTranscriptionAvailable ? .secondary : .orange)
'''
new = '''                    Text(model.localTranscriptionStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
'''
if text.count(old) != 1:
    raise SystemExit(f"expected one generated transcription style block, found {text.count(old)}")
path.write_text(text.replace(old, new, 1))
print("transcription status style fixed")
