#!/bin/bash
# Compile provisioned MobileCLIP S0 .mlpackage files for the native runtime.
# This is deliberately separate from provisioning: compilation is local and
# does not contact the network.
set -euo pipefail

MODEL_DIR="${1:-Models/mobileclip-s0-coreml}"
OUTPUT_DIR="${2:-$MODEL_DIR}"

provenance="$MODEL_DIR/provenance.json"
[ -f "$provenance" ] || { echo "missing $provenance (provision with --download first)" >&2; exit 1; }

for model in mobileclip_s0_image mobileclip_s0_text; do
    input="$MODEL_DIR/$model.mlpackage"
    [ -d "$input" ] || { echo "missing $input (run provision_mobileclip_coreml.py --download)" >&2; exit 1; }
    xcrun coremlcompiler compile "$input" "$OUTPUT_DIR"
done

python3 - "$provenance" "$MODEL_DIR" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
root = Path(sys.argv[2])
if path.exists():
    record = json.loads(path.read_text())
    manifest = dict(record.get("files_sha256", {}))
    for compiled in root.glob("mobileclip_s0_*.mlmodelc"):
        for child in compiled.rglob("*"):
            if child.is_file():
                digest = hashlib.sha256()
                with child.open("rb") as handle:
                    for chunk in iter(lambda: handle.read(1 << 20), b""):
                        digest.update(chunk)
                manifest[str(child.relative_to(root))] = digest.hexdigest()
    record["files_sha256"] = dict(sorted(manifest.items()))
    record["compiled"] = True
    path.write_text(json.dumps(record, indent=2) + "\n")
PY

echo "compiled MobileCLIP S0 models into $OUTPUT_DIR"
