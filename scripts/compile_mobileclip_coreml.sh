#!/bin/bash
# Compile provisioned MobileCLIP S0 .mlpackage files for the native runtime.
# This is deliberately separate from provisioning: compilation is local and
# does not contact the network.
set -euo pipefail

MODEL_DIR="${1:-Models/mobileclip-s0-coreml}"
OUTPUT_DIR="${2:-$MODEL_DIR}"

for model in mobileclip_s0_image mobileclip_s0_text; do
    input="$MODEL_DIR/$model.mlpackage"
    [ -d "$input" ] || { echo "missing $input (run provision_mobileclip_coreml.py --download)" >&2; exit 1; }
    xcrun coremlcompiler compile "$input" "$OUTPUT_DIR"
done

python3 - "$MODEL_DIR/provenance.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if path.exists():
    record = json.loads(path.read_text())
    record["compiled"] = True
    path.write_text(json.dumps(record, indent=2) + "\n")
PY

echo "compiled MobileCLIP S0 models into $OUTPUT_DIR"
