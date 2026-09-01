#!/usr/bin/env python3
from pathlib import Path
import re

FORBIDDEN_IDS = ("ling-3.0-tiny", "internvl3.5-4b", "mimo-vl-7b-rl-2508")


def load(path: str) -> str:
    return Path(path).read_text()


def save(path: str, text: str) -> None:
    Path(path).write_text(text)


def replace_once(text: str, old: str, new: str, path: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one match, found {count}: {old[:120]!r}")
    return text.replace(old, new, 1)


def remove_regex_once(text: str, pattern: str, path: str, label: str) -> str:
    text, count = re.subn(pattern, "", text, count=1, flags=re.S | re.M)
    if count != 1:
        raise SystemExit(f"{path}: failed to remove {label}; matches={count}")
    return text


# 1) Swift model registry/router ---------------------------------------------
path = "Sources/LibrarianCore/LocalModelRouter.swift"
text = load(path)
for symbol, runtime in (
    ("ling", "local-generation"),
    ("mimo", "transformers"),
    ("internVL", "transformers-remote-code"),
):
    pattern = (
        rf"\n    public static let {symbol} = LocalModelDescriptor\(\n"
        rf".*?\n        runtime: \"{re.escape(runtime)}\"\)\n"
    )
    text = remove_regex_once(text, pattern, path, symbol)

text = replace_once(
    text,
    """    public static let all: [LocalModelDescriptor] = [
        siglip2, dinov3, paddleOCR, ling, miniCPM, mimo, internVL, lfm
    ]
""",
    """    /// Product-supported stack for the target Mac. Models whose own execution
    /// footprint cannot reliably remain below 11.50 GB are intentionally absent.
    public static let all: [LocalModelDescriptor] = [
        siglip2, dinov3, paddleOCR, miniCPM, lfm
    ]
""",
    path,
)
text = replace_once(
    text,
    """    /// Same cheap-first path, with Ling/heavy VLM escalation available for a small hard queue.
    case quality
""",
    """    /// Same cheap-first path, with one bounded LFM2.5-VL 3B fallback for the hard queue.
    case quality
""",
    path,
)
text = replace_once(
    text,
    """        if profile == .quality, ambiguous {
            if context.hasUsefulText { append(LocalModelStack.ling) }
            if context.kind == .image {
                append(LocalModelStack.lfm)
                append(LocalModelStack.internVL)
                append(LocalModelStack.mimo)
            }
        }
""",
    """        if profile == .quality, ambiguous, context.kind == .image {
            // LFM2.5-VL-3B is the largest supported fallback. Larger candidates
            // were removed rather than relying on swap/offload to hide a RAM violation.
            append(LocalModelStack.lfm)
        }
""",
    path,
)
save(path, text)

# 2) Swift specialist bridge: remove Ling as implicit default ----------------
path = "Sources/LibrarianCore/SpecialistModelBridge.swift"
text = load(path)
text = replace_once(
    text,
    "    public func classifyText(model: LocalModelDescriptor = LocalModelStack.ling,\n",
    "    public func classifyText(model: LocalModelDescriptor,\n",
    path,
)
save(path, text)

# 3) Provisioner: oversized models cannot be downloaded by the app helper ----
path = "scripts/provision_specialist_models.py"
text = load(path)
for model_id in FORBIDDEN_IDS:
    pattern = rf'^    "{re.escape(model_id)}": \{{\n.*?^    \}},\n'
    text = remove_regex_once(text, pattern, path, model_id)
text = text.replace(
    '        print("WARNING: quality profile includes multiple multi-GB models; this is an explicit large download.", file=sys.stderr)\n',
    '        print("Quality adds LFM2.5-VL-3B; models above the 11.50 GB Mac ceiling are not offered.", file=sys.stderr)\n',
)
save(path, text)

# 4) Offline worker: remove oversized loaders/routes and force MPS FP16 -------
path = "scripts/specialist.py"
text = load(path)
for model_id in FORBIDDEN_IDS:
    text = re.sub(rf'^    "{re.escape(model_id)}": .*\n', "", text, flags=re.M)
    text = re.sub(rf'^    "{re.escape(model_id)}",\n', "", text, flags=re.M)

# There is no supported text-generation specialist after Ling is removed.
start = text.find("\ndef _load_text_generator(model_id: str):")
end = text.find("\ndef _vlm_classify(model_id: str, image, existing: dict) -> dict:")
if start < 0 or end <= start:
    raise SystemExit(f"{path}: text generator block not found")
text = text[:start] + text[end:]

text = replace_once(
    text,
    '    if model_id in {"minicpm-v-4.6", "internvl3.5-4b"}:\n',
    '    if model_id == "minicpm-v-4.6":\n',
    path,
)
# Simplify the now-MiniCPM-only custom chat branch.
text = replace_once(
    text,
    """        model, tokenizer = cached
        if model_id == "minicpm-v-4.6":
            response = model.chat(image=image, msgs=[{"role": "user", "content": prompt}], tokenizer=tokenizer,
                                  sampling=False, temperature=0)
        else:
            response = model.chat(tokenizer, image, prompt, generation_config={"do_sample": False, "max_new_tokens": 320})
        return _extract_json(response[0] if isinstance(response, tuple) else str(response))
""",
    """        model, tokenizer = cached
        response = model.chat(image=image, msgs=[{"role": "user", "content": prompt}], tokenizer=tokenizer,
                              sampling=False, temperature=0)
        return _extract_json(response[0] if isinstance(response, tuple) else str(response))
""",
    path,
)
text = replace_once(
    text,
    """    if op == "classify_text":
        return _ling_classify(request.get("evidence") if isinstance(request.get("evidence"), dict) else {})
""",
    "",
    path,
)
text = replace_once(
    text,
    '        if model_id not in {"minicpm-v-4.6", "lfm2.5-vl-3b", "internvl3.5-4b", "mimo-vl-7b-rl-2508"}:\n',
    '        if model_id not in {"minicpm-v-4.6", "lfm2.5-vl-3b"}:\n',
    path,
)
text = replace_once(
    text,
    """def _large_model_load_kwargs(model_id: str) -> dict:
    kwargs = {"low_cpu_mem_usage": True}
""",
    """def _large_model_load_kwargs(model_id: str) -> dict:
    # Hard target-Mac rule: no supported transient model may silently load FP32.
    # Apple Silicon CPU/GPU share unified memory, so swapping layers to CPU is not
    # a substitute for fitting the model. Keep the supported 3B fallback in FP16.
    import torch
    kwargs = {"low_cpu_mem_usage": True}
    if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        kwargs["torch_dtype"] = torch.float16
""",
    path,
)
text = text.replace(
    '"memory_policy": "warm-encoders-only; transient-exclusive; disk-offload-available",',
    '"memory_policy": "11.50-GB-ceiling; warm-encoders-only; transient-exclusive; MPS-fp16",',
)
save(path, text)

# 5) Packager cannot bundle forbidden specialists -----------------------------
path = "scripts/package_app.sh"
text = load(path)
old = """            siglip2-so400m-naflex \\
            dinov3-vitb16-lvd1689m \\
            paddleocr-vl-1.6 \\
            minicpm-v-4.6 \\
            ling-3.0-tiny \\
            lfm2.5-vl-3b \\
            internvl3.5-4b \\
            mimo-vl-7b-rl-2508; do
"""
new = """            siglip2-so400m-naflex \\
            dinov3-vitb16-lvd1689m \\
            paddleocr-vl-1.6 \\
            minicpm-v-4.6 \\
            lfm2.5-vl-3b; do
"""
text = replace_once(text, old, new, path)
save(path, text)

# 6) Settings only show models that can fit ----------------------------------
path = "Sources/LibrarianApp/SimpleSettingsView.swift"
text = load(path)
text = replace_once(
    text,
    '            return "For hard libraries. Adds Ling and optional larger VLM fallbacks. Models run one-at-a-time and unload between stages."\n',
    '            return "For hard libraries. Adds LFM2.5-VL 3B as the largest fallback. Every offered model is bounded for an 11.50 GB Mac ceiling and unloads between stages."\n',
    path,
)
for old in (
    '        case LocalModelStack.ling.id: return "Ling 3.0 Tiny"\n',
    '        case LocalModelStack.internVL.id: return "InternVL3.5 4B"\n',
    '        case LocalModelStack.mimo.id: return "MiMo-VL 7B"\n',
):
    if old not in text:
        raise SystemExit(f"{path}: expected display case missing: {old.strip()}")
    text = text.replace(old, "", 1)
save(path, text)

# 7) Regression tests codify the ceiling -------------------------------------
path = "Tests/LibrarianTests/LocalModelRouterTests.swift"
text = load(path)
text = replace_once(
    text,
    """        XCTAssertTrue(ambiguous.contains { $0.id == LocalModelStack.ling.id })
        XCTAssertTrue(ambiguous.contains { $0.id == LocalModelStack.lfm.id })
        XCTAssertTrue(ambiguous.contains { $0.id == LocalModelStack.internVL.id })
        XCTAssertTrue(ambiguous.contains { $0.id == LocalModelStack.mimo.id })
""",
    """        XCTAssertTrue(ambiguous.contains { $0.id == LocalModelStack.lfm.id })
        XCTAssertEqual(ambiguous.filter { $0.cost == .heavy }.map(\.id), [LocalModelStack.lfm.id])
""",
    path,
)
needle = "    func testUnavailableModelsAreNeverSubstituted() {\n"
insert = """    func testRegistryExcludesModelsThatCannotRespectMacMemoryCeiling() {
        let ids = Set(LocalModelStack.all.map(\.id))
        XCTAssertFalse(ids.contains("ling-3.0-tiny"))
        XCTAssertFalse(ids.contains("internvl3.5-4b"))
        XCTAssertFalse(ids.contains("mimo-vl-7b-rl-2508"))
    }

"""
text = replace_once(text, needle, insert + needle, path)
save(path, text)

# Final product-surface guard. Tests may mention forbidden IDs to assert absence;
# production runtime/provisioning/UI files may not.
product_files = (
    "Sources/LibrarianCore/LocalModelRouter.swift",
    "Sources/LibrarianCore/SpecialistModelBridge.swift",
    "Sources/LibrarianApp/SimpleSettingsView.swift",
    "scripts/provision_specialist_models.py",
    "scripts/specialist.py",
    "scripts/package_app.sh",
)
for product in product_files:
    content = load(product)
    leftovers = [model for model in FORBIDDEN_IDS if model in content]
    if leftovers:
        raise SystemExit(f"{product}: forbidden model IDs remain: {leftovers}")
if "LocalModelStack.ling" in load("Sources/LibrarianCore/SpecialistModelBridge.swift"):
    raise SystemExit("SpecialistModelBridge still references removed Ling symbol")
if 'kwargs["torch_dtype"] = torch.float16' not in load("scripts/specialist.py"):
    raise SystemExit("MPS FP16 load guard was not installed")

print("11.50 GB model ceiling patch applied")
