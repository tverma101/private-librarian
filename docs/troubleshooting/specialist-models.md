# Specialist model setup and runtime failures

## Symptoms

- The app reports model files but local embeddings are unavailable.
- A specialist appears present, but indexing falls back to native Vision or keeps
  an item pending.
- Packaging fails while trying to include a specialist checkpoint.

## Root causes

Specialist checkpoints are admitted only when their pinned Hugging Face identity,
revision prefix, SHA-256 file manifest, safe relative paths, and exact regular-file
set all agree. The runtime then checks the Python modules needed by that specific
model before loading it. A directory copied from an older cache, a partial download,
an extra file, or an incomplete runtime is therefore intentionally unavailable.

PaddleOCR-VL is a separate platform case: its upstream runtime documentation
currently excludes CPU and Arm, so the macOS app reports it as unsupported and
continues with native Vision OCR. macOS provisioning and packaging skip that
checkpoint rather than treating it as a broken required dependency.

## Recovery

Start with the bounded embeddings profile:

```bash
./scripts/setup_models.sh --specialist-profile embeddings
```

Use these explicit operations when repairing an existing installation:

```bash
./scripts/setup_models.sh --specialist-runtime-only
./scripts/setup_models.sh --specialist-models-only

SPECIALIST_PYTHON="$HOME/Library/Containers/com.tejas.private-librarian/Data/Library/Application Support/PrivateLibrarian/model-runtime/bin/python3"
LIBRARIAN_SPECIALIST_MODELS_DIR="$HOME/Library/Containers/com.tejas.private-librarian/Data/Library/Application Support/PrivateLibrarian/Models/specialists" \
  "$SPECIALIST_PYTHON" scripts/provision_specialist_models.py --profile embeddings --verify-only
"$SPECIALIST_PYTHON" scripts/specialist.py --syntax-check
"$SPECIALIST_PYTHON" scripts/specialist.py --runtime-check siglip2-so400m-naflex
```

`--specialist-models-only` does not create or modify a Python environment; it
requires the selected runtime to already exist. `--force` is the deliberate
redownload path and preserves the previous checkpoint in a recoverable sibling
directory. Normal app startup never downloads weights, imports the provisioning
library, or sends source paths to the worker.

## Validation

The dependency-free contract test covers mutation after a structural status probe,
extra files, unsafe manifest paths, and selecting a later valid model root:

```bash
python3 scripts/test_specialist_contract.py
python3 scripts/test_model_provisioning.py
swift test --disable-sandbox --filter SpecialistModelBridgeTests
```

The app's provider preflight is stricter than `specialist.py --check`: it also
requires the packaged helper and imports the model-specific runtime modules. A
successful structural check alone is not evidence that a large checkpoint can fit
in memory or produce a live inference result on the current Mac.

## Residual boundary

DINOv3 remains gated upstream and requires accepted access before provisioning.
Large quality-tier VLMs are opt-in and may require substantial unified memory;
they are transient and are released after an escalation. Public distribution still
needs a separately provisioned, licensed runtime/model policy; the normal DMG keeps
user-specific weights in Application Support.
