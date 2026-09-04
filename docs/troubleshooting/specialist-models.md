# Specialist model setup and runtime failures

## Symptoms

- The app reports model files but local embeddings are unavailable.
- A specialist appears present, but analysis falls back to native Vision or keeps an item pending.
- **Set Up & Analyze** fails before the selected quality level becomes ready.
- Packaging fails while trying to include a specialist checkpoint.

## Root causes

Specialist checkpoints are admitted only when their pinned Hugging Face identity,
revision prefix, SHA-256 file manifest, safe relative paths, and exact regular-file
set all agree. The runtime then checks the Python modules needed by that specific
model before loading it. A directory copied from an older cache, a partial download,
an extra file, or an incomplete runtime is therefore intentionally unavailable.

The pinned Transformers runtime can also change the return type of a model
helper without changing the checkpoint. In Transformers 5, SigLIP2's
`get_image_features` and `get_text_features` helpers return a
`BaseModelOutputWithPooling` object; the bridge must unwrap `pooler_output`
(or the equivalent full-output embedding field) before normalizing it. A
raw `.float()` call on that wrapper is a runtime failure even though the
snapshot and Python dependencies are valid.

On macOS, the same Transformers import can occasionally be interrupted while
its model-package discovery walks the filesystem, producing
`[Errno 4] Interrupted system call`. The packaged specialist and legacy
embedding workers now disable bytecode writes (their bundle is read-only) and
retry only that bounded `InterruptedError` at both readiness and lazy import
boundaries. A persistent import failure still reaches the worker's JSON error
boundary; it is not reported as a false-ready model.

The LFM2.5-VL processor additionally uses the pinned `torchvision` runtime
package. `scripts/model-requirements.txt` declares the version paired with the
pinned Torch build; omitting it makes readiness look successful while a real
`classify_image` call fails during image preprocessing.

The setup shell path is also quoted end to end. This matters for the real
container path under `Application Support`, which contains spaces; the
runtime probe and models-only path must invoke the configured Python
executable rather than split it into multiple shell words.

PaddleOCR-VL is a separate platform case: its upstream runtime currently does
not cover the target macOS Apple-silicon path, so the app reports it as
unsupported and continues with native Vision OCR. macOS provisioning and
packaging skip that checkpoint rather than treating it as a broken required
dependency.

## Normal consumer recovery

The normal profiles are public-only. They do **not** require a Hugging Face
account, access request, or token.

Start with the bounded public embeddings profile:

```bash
./scripts/setup_models.sh --specialist-profile embeddings
```

Or repair the profile the user actually selected:

```bash
./scripts/setup_models.sh --specialist-profile balanced
./scripts/setup_models.sh --specialist-profile quality
```

On Apple-silicon macOS, setup can prepare its own app-private pinned Python
runtime. Homebrew, Xcode, and a global Python are not prerequisites. If the
bootstrap archive checksum does not match the repository-pinned digest, setup
fails closed rather than executing it.

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
directory. Normal app startup never downloads weights or sends source paths to
the worker; model downloads occur only after an explicit setup action.

## Optional gated DINOv3

DINOv3 is an optional advanced visual-similarity specialist. It is **not** part
of the normal Fast/Balanced/Quality profiles and its absence must never block
Analyze.

If an advanced user deliberately wants it, upstream approval and a credential
are still required:

```bash
printf '%s\n' "$HF_TOKEN" | ./scripts/setup_models.sh \
  --specialist-model dinov3-vitb16-lvd1689m --hf-token-stdin
```

That credential path is separate from consumer setup. The token is not placed
in argv or shell history by the stdin form, and the explicit gated download is
preflighted before its large transfer.

## Validation

The dependency-free contract test covers snapshot mutation, extra files, unsafe
manifest paths, later valid model roots, and the product rule that every consumer
profile excludes every gated checkpoint:

```bash
python3 scripts/test_specialist_contract.py
python3 scripts/test_model_provisioning.py
swift test --disable-sandbox --filter SpecialistModelBridgeTests
```

The app's provider preflight is stricter than a structural model-directory
check: it also requires the packaged helper and imports the model-specific
runtime modules. A successful structural check alone is not evidence that a
large checkpoint can fit in memory or produce a live inference result on the
current Mac.

## Residual boundary

The Quality profile's largest normally offered fallback is LFM2.5-VL-3B. Ling
3.0 Tiny, InternVL3.5-4B, and MiMo-VL-7B are intentionally not exposed on the
target 16 GB Mac because the product enforces an 11.50 GB per-model working-set
ceiling rather than relying on swap or CPU offload to hide an oversized model.
Supported specialists are transient, run one at a time during escalation, and
are released before the normal embedding path resumes.

A final packaged-app clean-user smoke is still required for the real public
runtime/model download path. A separate private-account smoke is needed only if
the optional DINOv3 path is being advertised as supported; it is not a normal
consumer release blocker.

The current local installation has the pinned Balanced and Quality stacks and
their isolated runtime provisioned and verified: SigLIP2 Base NaFlex, So400m,
MiniCPM-V 4.6, and LFM2.5-VL. The runtime also has the pinned `torchvision`
processor dependency. Gated DINOv3 remains an explicit setup choice; its
absence is reported as gated rather than silently treated as ready.
