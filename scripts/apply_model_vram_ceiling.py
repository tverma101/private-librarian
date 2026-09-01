#!/usr/bin/env python3
from pathlib import Path
import re

FORBIDDEN = {
    "ling-3.0-tiny",
    "internvl3.5-4b",
    "mimo-vl-7b-rl-2508",
}


def read(path: str) -> str:
    return Path(path).read_text()


def write(path: str, text: str) -> None:
    Path(path).write_text(text)


def replace_once(text: str, old: str, new: str, *, path: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected one match in {path}, found {count}: {old[:120]!r}")
    return text.replace(old, new, 1)


def remove_swift_descriptor(text: str, name: str, next_marker: str, *, path: str) -> str:
    pattern = rf"\n    public static let {re.escape(name)} = LocalModelDescriptor\(.*?\n    \)\n(?=\n    {re.escape(next_marker)})"
    text, count = re.subn(pattern, "", text, count=1, flags=re.S)
    if count != 1:
        raise SystemExit(f"failed to remove Swift descriptor {name} from {path}")
    return text


def remove_python_dict_entry(text: str, key: str, *, path: str) -> str:
    pattern = rf'^    "{re.escape(key)}": \{{\n(?:        .*\n)+?    \}},\n'
    text, count = re.subn(pattern, "", text, count=1, flags=re.M)
    if count != 1:
        raise SystemExit(f"failed to remove dict entry {key} from {path}")
    return text


# Swift registry/router -------------------------------------------------------
path = "Sources/LibrarianCore/LocalModelRouter.swift"
text = read(path)
text = remove_swift_descriptor(text, "ling", "/// First generative vision fallback", path=path)
text = remove_swift_descriptor(text, "mimo", "public static let internVL", path=path)
text = remove_swift_descriptor(text, "internVL", "public static let lfm", path=path)
text = replace_once(
    text,
    """    public static let all: [LocalModelDescriptor] = [\n        siglip2, dinov3, paddleOCR, ling, miniCPM, mimo, internVL, lfm\n    ]\n""",
    """    /// Supported on the target Mac under the 11.50 GiB per-model working-set ceiling.\n    /// The registry intentionally excludes Ling 3.0 Tiny, InternVL3.5-4B and MiMo-VL 7B: the\n    /// first/last exceed the ceiling in weights alone and InternVL leaves too little activation\n    /// headroom for a reliable 11.50 GiB peak.\n    public static let all: [LocalModelDescriptor] = [\n        siglip2, dinov3, paddleOCR, miniCPM, lfm\n    ]\n""",
    path=path,
)
text = replace_once(
    text,
    """        if profile == .quality, ambiguous {\n            if context.hasUsefulText { append(LocalModelStack.ling) }\n            if context.kind == .image {\n                append(LocalModelStack.lfm)\n                append(LocalModelStack.internVL)\n                append(LocalModelStack.mimo)\n            }\n        }\n""",
    """        if profile == .quality, ambiguous, context.kind == .image {\n            // LFM2.5-VL-3B is the largest supported fallback. Larger candidates were removed\n            // from the product so a single model cannot violate the 11.50 GiB Mac ceiling.\n            append(LocalModelStack.lfm)\n        }\n""",
    path=path,
)
write(path, text)

# Provisioner ----------------------------------------------------------------
path = "scripts/provision_specialist_models.py"
text = read(path)
for key in ("ling-3.0-tiny", "internvl3.5-4b", "mimo-vl-7b-rl-2508"):
    text = remove_python_dict_entry(text, key, path=path)
text = text.replace(
    '        print("WARNING: quality profile includes multiple multi-GB models; this is an explicit large download.", file=sys.stderr)\n',
    '        print("Quality profile adds LFM2.5-VL-3B; models above the 11.50 GiB Mac ceiling are not offered.", file=sys.stderr)\n',
)
write(path, text)

# Offline worker --------------------------------------------------------------
path = "scripts/specialist.py"
text = read(path)
for key in ("ling-3.0-tiny", "internvl3.5-4b", "mimo-vl-7b-rl-2508"):
    # MODEL_SPECS tuple entries and RUNTIME_MODULES tuple entries are both one-line dict entries.
    text = re.sub(rf'^    "{re.escape(key)}": .*\n', "", text, flags=re.M)
    text = re.sub(rf'^    "{re.escape(key)}",\n', "", text, flags=re.M)

# Remove text-generator path entirely: no oversized text generator remains in the supported stack.
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
write(path, text)

# Packager -------------------------------------------------------------------
path = "scripts/package_app.sh"
text = read(path)
for line in (
    "            ling-3.0-tiny \\\n",
    "            internvl3.5-4b \\\n",
    "            mimo-vl-7b-rl-2508; do\n",
):
    if line not in text:
        raise SystemExit(f"missing package model line: {line!r}")
# Keep LFM as the final loop item after removing the larger candidates.
text = text.replace("            ling-3.0-tiny \\\n", "")
text = text.replace("            lfm2.5-vl-3b \\\n            internvl3.5-4b \\\n            mimo-vl-7b-rl-2508; do\n", "            lfm2.5-vl-3b; do\n")
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

# Final guard: forbidden models must not remain in product registry, provisioner, worker, packager or UI.
for path in (
    "Sources/LibrarianCore/LocalModelRouter.swift",
    "scripts/provision_specialist_models.py",
    "scripts/specialist.py",
    "scripts/package_app.sh",
    "Sources/LibrarianApp/SimpleSettingsView.swift",
):
    content = read(path)
    leftovers = sorted(model for model in FORBIDDEN if model in content)
    if leftovers:
        raise SystemExit(f"forbidden >11.50 GiB model IDs remain in {path}: {leftovers}")

print("applied 11.50 GiB model ceiling")
