#!/usr/bin/env python3
from pathlib import Path

path = Path("Sources/LibrarianCore/Catalog/Catalog+SemanticContext.swift")
text = path.read_text()
if "SQLiteValue" not in text:
    raise SystemExit("semantic scope bind type already fixed or unexpected source")
path.write_text(text.replace("SQLiteValue", "SQLValue"))
