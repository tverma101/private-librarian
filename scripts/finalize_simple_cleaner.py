#!/usr/bin/env python3
from pathlib import Path
import re

FORBIDDEN = {"ling-3.0-tiny", "internvl3.5-4b", "mimo-vl-7b-rl-2508"}


def read(path: str) -> str:
    return Path(path).read_text()


def write(path: str, text: str) -> None:
    Path(path).write_text(text)


def replace_once(text: str, old: str, new: str, *, path: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected one match in {path}, found {count}: {old[:100]!r}")
    return text.replace(old, new, 1)


def remove_swift_descriptor(text: str, name: str, next_marker: str, *, path: str) -> str:
    start_marker = f"\n    public static let {name} = LocalModelDescriptor("
    start = text.find(start_marker)
    end_marker = "\n\n    " + next_marker
    end = text.find(end_marker, start + len(start_marker)) if start >= 0 else -1
    if start < 0 or end < 0:
        raise SystemExit(f"failed to remove Swift descriptor {name} from {path}")
    return text[:start] + text[end:]


def remove_python_dict_entry(text: str, key: str, *, path: str) -> str:
    pattern = rf'^    "{re.escape(key)}": \{{\n(?:        .*\n)+?    \}},\n'
    text, count = re.subn(pattern, "", text, count=1, flags=re.M)
    if count != 1:
        raise SystemExit(f"failed to remove dict entry {key} from {path}")
    return text


# Swift model registry/router -------------------------------------------------
path = "Sources/LibrarianCore/LocalModelRouter.swift"
text = read(path)
text = remove_swift_descriptor(text, "ling", "/// First generative vision fallback", path=path)
text = remove_swift_descriptor(text, "mimo", "public static let internVL", path=path)
text = remove_swift_descriptor(text, "internVL", "public static let lfm", path=path)
text = replace_once(
    text,
    """    public static let all: [LocalModelDescriptor] = [\n        siglip2, dinov3, paddleOCR, ling, miniCPM, mimo, internVL, lfm\n    ]\n""",
    """    /// Supported on the target Mac under the 11.50 GiB per-model working-set ceiling.\n    /// The registry intentionally excludes Ling 3.0 Tiny, InternVL3.5-4B and MiMo-VL 7B.\n    public static let all: [LocalModelDescriptor] = [\n        siglip2, dinov3, paddleOCR, miniCPM, lfm\n    ]\n""",
    path=path,
)
text = replace_once(
    text,
    """        if profile == .quality, ambiguous {\n            if context.hasUsefulText { append(LocalModelStack.ling) }\n            if context.kind == .image {\n                append(LocalModelStack.lfm)\n                append(LocalModelStack.internVL)\n                append(LocalModelStack.mimo)\n            }\n        }\n""",
    """        if profile == .quality, ambiguous, context.kind == .image {\n            // LFM2.5-VL-3B is the largest supported fallback. Larger candidates are not\n            // exposed on the 16 GB target so one model cannot consume the whole machine.\n            append(LocalModelStack.lfm)\n        }\n""",
    path=path,
)
write(path, text)

# Bridge: no default Ling symbol remains -------------------------------------
path = "Sources/LibrarianCore/SpecialistModelBridge.swift"
text = read(path)
text = replace_once(
    text,
    "    public func classifyText(model: LocalModelDescriptor = LocalModelStack.ling,\n",
    "    public func classifyText(model: LocalModelDescriptor,\n",
    path=path,
)
write(path, text)

# Provisioner ----------------------------------------------------------------
path = "scripts/provision_specialist_models.py"
text = read(path)
for key in sorted(FORBIDDEN):
    text = remove_python_dict_entry(text, key, path=path)
text = text.replace(
    '        print("WARNING: quality profile includes multiple multi-GB models; this is an explicit large download.", file=sys.stderr)\n',
    '        print("Quality profile adds LFM2.5-VL-3B; models above the 11.50 GiB Mac ceiling are not offered.", file=sys.stderr)\n',
)
write(path, text)

# Offline worker --------------------------------------------------------------
path = "scripts/specialist.py"
text = read(path)
for key in sorted(FORBIDDEN):
    text = re.sub(rf'^    "{re.escape(key)}": .*\n', "", text, flags=re.M)
    text = re.sub(rf'^    "{re.escape(key)}",\n', "", text, flags=re.M)

start = text.find("\ndef _load_text_generator(model_id: str):")
end = text.find("\ndef _vlm_classify(model_id: str, image, existing: dict) -> dict:")
if start < 0 or end < 0 or end <= start:
    raise SystemExit("could not locate text-generator block in scripts/specialist.py")
text = text[:start] + text[end:]
text = replace_once(
    text,
    '    if model_id in {"minicpm-v-4.6", "internvl3.5-4b"}:\n',
    '    if model_id == "minicpm-v-4.6":\n',
    path=path,
)
text = replace_once(
    text,
    """        model, tokenizer = cached\n        if model_id == \"minicpm-v-4.6\":\n            response = model.chat(image=image, msgs=[{\"role\": \"user\", \"content\": prompt}], tokenizer=tokenizer,\n                                  sampling=False, temperature=0)\n        else:\n            response = model.chat(tokenizer, image, prompt, generation_config={\"do_sample\": False, \"max_new_tokens\": 320})\n        return _extract_json(response[0] if isinstance(response, tuple) else str(response))\n""",
    """        model, tokenizer = cached\n        response = model.chat(image=image, msgs=[{\"role\": \"user\", \"content\": prompt}], tokenizer=tokenizer,\n                              sampling=False, temperature=0)\n        return _extract_json(response[0] if isinstance(response, tuple) else str(response))\n""",
    path=path,
)
text = replace_once(
    text,
    """    if op == \"classify_text\":\n        return _ling_classify(request.get(\"evidence\") if isinstance(request.get(\"evidence\"), dict) else {})\n""",
    "",
    path=path,
)
text = replace_once(
    text,
    '        if model_id not in {"minicpm-v-4.6", "lfm2.5-vl-3b", "internvl3.5-4b", "mimo-vl-7b-rl-2508"}:\n',
    '        if model_id not in {"minicpm-v-4.6", "lfm2.5-vl-3b"}:\n',
    path=path,
)
text = text.replace(
    '"memory_policy": "warm-encoders-only; transient-exclusive; disk-offload-available",',
    '"memory_policy": "11.50-GiB-ceiling; warm-encoders-only; transient-exclusive; disk-offload-available",',
)
old = '''def _large_model_load_kwargs(model_id: str) -> dict:\n    kwargs = {"low_cpu_mem_usage": True}\n'''
new = '''def _large_model_load_kwargs(model_id: str) -> dict:\n    # The target Mac has an 11.50 GiB model working-set ceiling. Force half\n    # precision on Apple MPS so a supported 3B fallback cannot silently load\n    # FP32 and consume the entire budget before activations are allocated.\n    import torch\n    kwargs = {"low_cpu_mem_usage": True}\n    if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():\n        kwargs["torch_dtype"] = torch.float16\n'''
text = replace_once(text, old, new, path=path)
write(path, text)

# Packager -------------------------------------------------------------------
path = "scripts/package_app.sh"
text = read(path)
text = text.replace("            ling-3.0-tiny \\\n", "")
text = text.replace(
    "            lfm2.5-vl-3b \\\n            internvl3.5-4b \\\n            mimo-vl-7b-rl-2508; do\n",
    "            lfm2.5-vl-3b; do\n",
)
write(path, text)

# Settings -------------------------------------------------------------------
path = "Sources/LibrarianApp/SimpleSettingsView.swift"
text = read(path)
text = text.replace(
    '            return "For hard libraries. Adds Ling and optional larger VLM fallbacks. Models run one-at-a-time and unload between stages."\n',
    '            return "For hard libraries. Adds LFM2.5-VL 3B as the largest fallback. Every offered model stays below the 11.50 GB Mac ceiling and unloads between stages."\n',
)
for line in (
    '        case LocalModelStack.ling.id: return "Ling 3.0 Tiny"\n',
    '        case LocalModelStack.internVL.id: return "InternVL3.5 4B"\n',
    '        case LocalModelStack.mimo.id: return "MiMo-VL 7B"\n',
):
    text = text.replace(line, "")
write(path, text)

# Router tests ----------------------------------------------------------------
path = "Tests/LibrarianTests/LocalModelRouterTests.swift"
text = read(path)
text = replace_once(
    text,
    """        XCTAssertTrue(ambiguous.contains { $0.id == LocalModelStack.ling.id })\n        XCTAssertTrue(ambiguous.contains { $0.id == LocalModelStack.lfm.id })\n        XCTAssertTrue(ambiguous.contains { $0.id == LocalModelStack.internVL.id })\n        XCTAssertTrue(ambiguous.contains { $0.id == LocalModelStack.mimo.id })\n""",
    """        XCTAssertTrue(ambiguous.contains { $0.id == LocalModelStack.lfm.id })\n        XCTAssertEqual(ambiguous.filter { $0.cost == .heavy }.map(\\.id), [LocalModelStack.lfm.id])\n""",
    path=path,
)
text = replace_once(
    text,
    """    func testUnavailableModelsAreNeverSubstituted() {\n""",
    """    func testRegistryExcludesModelsAboveMacMemoryCeiling() {\n        let ids = Set(LocalModelStack.all.map(\\.id))\n        XCTAssertFalse(ids.contains(\"ling-3.0-tiny\"))\n        XCTAssertFalse(ids.contains(\"internvl3.5-4b\"))\n        XCTAssertFalse(ids.contains(\"mimo-vl-7b-rl-2508\"))\n    }\n\n    func testUnavailableModelsAreNeverSubstituted() {\n""",
    path=path,
)
write(path, text)

# Documentation ---------------------------------------------------------------
path = "docs/troubleshooting/specialist-models.md"
text = read(path)
text = text.replace(
    "Large quality-tier VLMs are opt-in and may require substantial unified memory;\nthey are transient and are released after an escalation. Public distribution still\n",
    "The Quality profile's largest offered fallback is LFM2.5-VL-3B. Models above the\n11.50 GiB per-model target are not offered on the 16 GB Mac target; supported\ngenerative fallbacks are transient and released after an escalation. Public distribution still\n",
)
write(path, text)

# Permanent CI guard ----------------------------------------------------------
path = ".github/workflows/ci.yml"
text = read(path)
text = text.replace(
    "          grep -q 'warm-encoders-only; transient-exclusive; disk-offload-available' specialist-contract.json\n",
    "          grep -q '11.50-GiB-ceiling; warm-encoders-only; transient-exclusive; disk-offload-available' specialist-contract.json\n"
    "          grep -F 'kwargs[\"torch_dtype\"] = torch.float16' scripts/specialist.py\n"
    "          for model in ling-3.0-tiny internvl3.5-4b mimo-vl-7b-rl-2508; do\n"
    "            if grep -R --line-number --fixed-strings \"$model\" Sources/LibrarianCore/LocalModelRouter.swift Sources/LibrarianCore/SpecialistModelBridge.swift Sources/LibrarianApp/SimpleSettingsView.swift scripts/provision_specialist_models.py scripts/specialist.py scripts/package_app.sh; then\n"
    "              echo \"oversized model still exposed: $model\" >&2\n"
    "              exit 1\n"
    "            fi\n"
    "          done\n",
)
write(path, text)

# Final assertions ------------------------------------------------------------
for path in (
    "Sources/LibrarianCore/LocalModelRouter.swift",
    "Sources/LibrarianCore/SpecialistModelBridge.swift",
    "scripts/provision_specialist_models.py",
    "scripts/specialist.py",
    "scripts/package_app.sh",
    "Sources/LibrarianApp/SimpleSettingsView.swift",
):
    content = read(path)
    leftovers = sorted(model for model in FORBIDDEN if model in content)
    if leftovers:
        raise SystemExit(f"forbidden >11.50 GiB model IDs remain in {path}: {leftovers}")
if 'kwargs["torch_dtype"] = torch.float16' not in read("scripts/specialist.py"):
    raise SystemExit("MPS half-precision load guard missing")
if "LocalModelStack.ling" in read("Sources/LibrarianCore/SpecialistModelBridge.swift"):
    raise SystemExit("Ling bridge default remains")

print("finalized simple cleaner model policy")
