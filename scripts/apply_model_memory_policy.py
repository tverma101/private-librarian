#!/usr/bin/env python3
from pathlib import Path

path = Path("scripts/specialist.py")
text = path.read_text()

if "TRANSIENT_MODELS = {" in text:
    print("model memory policy already applied")
    raise SystemExit(0)


def replace_once(old: str, new: str, label: str) -> None:
    global text
    if old not in text:
        raise SystemExit(f"missing expected block: {label}")
    text = text.replace(old, new, 1)


replace_once(
    "_CACHE = {}\n_TRUSTED = set()\n",
    '''_CACHE = {}\n_TRUSTED = set()\n\n# Keep only the cheap image encoders warm. OCR/reasoners/VLMs are transient and\n# must never overlap each other or the warm encoder set on a memory-constrained Mac.\nWARM_MODELS = {\n    "siglip2-so400m-naflex",\n    "dinov3-vitb16-lvd1689m",\n}\nTRANSIENT_MODELS = {\n    "paddleocr-vl-1.6",\n    "minicpm-v-4.6",\n    "ling-3.0-tiny",\n    "lfm2.5-vl-3b",\n    "internvl3.5-4b",\n    "mimo-vl-7b-rl-2508",\n}\nOFFLOADABLE_MODELS = {\n    "minicpm-v-4.6",\n    "ling-3.0-tiny",\n    "lfm2.5-vl-3b",\n    "internvl3.5-4b",\n    "mimo-vl-7b-rl-2508",\n}\nOFFLOAD_ROOT = Path(os.environ.get(\n    "LIBRARIAN_SPECIALIST_OFFLOAD_DIR",\n    str(Path(tempfile.gettempdir()) / "private-librarian-model-offload"),\n))\n\n\ndef _clear_accelerator_cache() -> None:\n    gc.collect()\n    try:\n        import torch\n        if hasattr(torch, "mps") and hasattr(torch.mps, "empty_cache"):\n            torch.mps.empty_cache()\n        if hasattr(torch, "cuda") and torch.cuda.is_available():\n            torch.cuda.empty_cache()\n    except Exception:\n        pass\n\n\ndef _drop_cached_models(keep: set[str] | None = None) -> None:\n    keep = keep or set()\n    for model_id in list(_CACHE):\n        if model_id not in keep:\n            _CACHE.pop(model_id, None)\n    _clear_accelerator_cache()\n\n\ndef _prepare_for_model(model_id: str) -> None:\n    if model_id in TRANSIENT_MODELS:\n        # A transient specialist gets the machine to itself. This is the key RAM invariant:\n        # SigLIP/DINO/Paddle/LLMs/VLMs never stack during an escalation batch.\n        _drop_cached_models()\n        return\n    # Warm embedding models may coexist with one another, but never with a leaked transient model.\n    leaked = set(_CACHE) - WARM_MODELS\n    if leaked:\n        _drop_cached_models(keep=set(_CACHE) & WARM_MODELS)\n\n\ndef _large_model_load_kwargs(model_id: str) -> dict:\n    kwargs = {"low_cpu_mem_usage": True}\n    if model_id not in OFFLOADABLE_MODELS:\n        return kwargs\n    offload = OFFLOAD_ROOT / model_id\n    offload.mkdir(parents=True, exist_ok=True, mode=0o700)\n    # Apple Silicon uses unified memory, so CPU layer offload does not create a second RAM pool.\n    # We still provide a disk-offload folder for oversized quality-tier checkpoints and let\n    # Transformers/Accelerate choose it when the device map requires disk placement.\n    kwargs.update({\n        "device_map": "auto",\n        "offload_folder": str(offload),\n        "offload_state_dict": True,\n    })\n    return kwargs\n\n\ndef _memory_policy_self_test() -> None:\n    # Dependency-free invariant test used by CI. Dummy objects prove transient escalation evicts\n    # warm encoders, while warm-to-warm transitions are allowed to retain both encoders.\n    _CACHE.clear()\n    _CACHE["siglip2-so400m-naflex"] = object()\n    _CACHE["dinov3-vitb16-lvd1689m"] = object()\n    _prepare_for_model("minicpm-v-4.6")\n    if _CACHE:\n        raise RuntimeError("transient model did not evict warm model cache")\n    _CACHE["siglip2-so400m-naflex"] = object()\n    _prepare_for_model("dinov3-vitb16-lvd1689m")\n    if set(_CACHE) != {"siglip2-so400m-naflex"}:\n        raise RuntimeError("warm model policy evicted compatible encoder")\n    _CACHE.clear()\n''',
    "memory policy constants",
)

replace_once(
    '''    if not _verify_snapshot(key):\n        raise RuntimeError(f"untrusted/unprovisioned model: {key}")\n    from transformers import AutoModel, AutoProcessor\n    path = str(_model_dir(key))\n    processor = AutoProcessor.from_pretrained(path, local_files_only=True, trust_remote_code=False)\n    model = AutoModel.from_pretrained(path, local_files_only=True, trust_remote_code=False)\n''',
    '''    if not _verify_snapshot(key):\n        raise RuntimeError(f"untrusted/unprovisioned model: {key}")\n    _prepare_for_model(key)\n    from transformers import AutoModel, AutoProcessor\n    path = str(_model_dir(key))\n    processor = AutoProcessor.from_pretrained(path, local_files_only=True, trust_remote_code=False)\n    model = AutoModel.from_pretrained(\n        path, local_files_only=True, trust_remote_code=False, low_cpu_mem_usage=True)\n''',
    "SigLIP low-memory load",
)

replace_once(
    '''    if not _verify_snapshot(key):\n        raise RuntimeError(f"untrusted/unprovisioned model: {key}")\n    from transformers import AutoImageProcessor, AutoModel\n    path = str(_model_dir(key))\n    processor = AutoImageProcessor.from_pretrained(path, local_files_only=True, trust_remote_code=False)\n    model = AutoModel.from_pretrained(path, local_files_only=True, trust_remote_code=False)\n''',
    '''    if not _verify_snapshot(key):\n        raise RuntimeError(f"untrusted/unprovisioned model: {key}")\n    _prepare_for_model(key)\n    from transformers import AutoImageProcessor, AutoModel\n    path = str(_model_dir(key))\n    processor = AutoImageProcessor.from_pretrained(path, local_files_only=True, trust_remote_code=False)\n    model = AutoModel.from_pretrained(\n        path, local_files_only=True, trust_remote_code=False, low_cpu_mem_usage=True)\n''',
    "DINO low-memory load",
)

replace_once(
    '''    from paddleocr import PaddleOCRVL\n    pipeline = _CACHE.get(key)\n''',
    '''    _prepare_for_model(key)\n    from paddleocr import PaddleOCRVL\n    pipeline = _CACHE.get(key)\n''',
    "Paddle eviction",
)

replace_once(
    '''    from transformers import AutoModelForCausalLM, AutoTokenizer\n    path = str(_model_dir(model_id))\n    tokenizer = AutoTokenizer.from_pretrained(path, local_files_only=True, trust_remote_code=False)\n    model = AutoModelForCausalLM.from_pretrained(path, local_files_only=True, trust_remote_code=False, device_map="auto")\n''',
    '''    _prepare_for_model(model_id)\n    from transformers import AutoModelForCausalLM, AutoTokenizer\n    path = str(_model_dir(model_id))\n    tokenizer = AutoTokenizer.from_pretrained(path, local_files_only=True, trust_remote_code=False)\n    model = AutoModelForCausalLM.from_pretrained(\n        path, local_files_only=True, trust_remote_code=False, **_large_model_load_kwargs(model_id))\n''',
    "text generator offload",
)

replace_once(
    '''    if not _verify_snapshot(model_id):\n        raise RuntimeError(f"untrusted/unprovisioned model: {model_id}")\n    prompt = _classification_prompt(existing)\n''',
    '''    if not _verify_snapshot(model_id):\n        raise RuntimeError(f"untrusted/unprovisioned model: {model_id}")\n    _prepare_for_model(model_id)\n    prompt = _classification_prompt(existing)\n''',
    "VLM eviction",
)

replace_once(
    '''            model = AutoModel.from_pretrained(path, local_files_only=True, trust_remote_code=True, device_map="auto")\n''',
    '''            model = AutoModel.from_pretrained(\n                path, local_files_only=True, trust_remote_code=True,\n                **_large_model_load_kwargs(model_id))\n''',
    "custom VLM offload",
)

replace_once(
    '''        model = AutoModelForImageTextToText.from_pretrained(\n            path, local_files_only=True, trust_remote_code=trust, device_map="auto")\n''',
    '''        model = AutoModelForImageTextToText.from_pretrained(\n            path, local_files_only=True, trust_remote_code=trust,\n            **_large_model_load_kwargs(model_id))\n''',
    "standard VLM offload",
)

replace_once(
    '''def _release(model_id: str | None) -> dict:\n    if model_id:\n        _CACHE.pop(model_id, None)\n    else:\n        _CACHE.clear()\n    gc.collect()\n    try:\n        import torch\n        if hasattr(torch, "mps") and hasattr(torch.mps, "empty_cache"):\n            torch.mps.empty_cache()\n        if hasattr(torch, "cuda") and torch.cuda.is_available():\n            torch.cuda.empty_cache()\n    except Exception:\n        pass\n    return {"released": model_id or "all"}\n''',
    '''def _release(model_id: str | None) -> dict:\n    if model_id:\n        _CACHE.pop(model_id, None)\n        _clear_accelerator_cache()\n    else:\n        _drop_cached_models()\n    return {"released": model_id or "all", "resident": sorted(_CACHE)}\n''',
    "release policy",
)

replace_once(
    '''        return {"offline": True, "available": {mid: _verify_snapshot(mid, verify_hashes=False) for mid in ids if mid in MODEL_SPECS}}\n''',
    '''        return {\n            "offline": True,\n            "available": {mid: _verify_snapshot(mid, verify_hashes=False) for mid in ids if mid in MODEL_SPECS},\n            "resident": sorted(_CACHE),\n            "memory_policy": "warm-encoders-only; transient-exclusive; disk-offload-available",\n        }\n''',
    "status memory policy",
)

replace_once(
    '''    if args.syntax_check:\n        print(json.dumps({"status": "ok", "offline": True, "models": sorted(MODEL_SPECS)}))\n        return 0\n''',
    '''    if args.syntax_check:\n        _memory_policy_self_test()\n        print(json.dumps({\n            "status": "ok",\n            "offline": True,\n            "models": sorted(MODEL_SPECS),\n            "memory_policy": "warm-encoders-only; transient-exclusive; disk-offload-available",\n        }))\n        return 0\n''',
    "memory policy self-test",
)

path.write_text(text)
print("applied model unloading/offload memory policy")
