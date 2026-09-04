#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def replace_once(path: str, old: str, new: str) -> None:
    target = ROOT / path
    text = target.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:100]!r}")
    target.write_text(text.replace(old, new, 1))


# Python specialist worker: support exactly one profile-selected SigLIP encoder
# at a time. Base and So400m are incompatible embedding spaces and must never
# be resident/stored as though they were interchangeable.
replace_once(
    "scripts/specialist.py",
    '''MODEL_SPECS = {\n    "siglip2-so400m-naflex": ("google/siglip2-so400m-patch16-naflex", "cc24074"),''',
    '''MODEL_SPECS = {\n    "siglip2-base-naflex": ("google/siglip2-base-patch16-naflex", "b53b807"),\n    "siglip2-so400m-naflex": ("google/siglip2-so400m-patch16-naflex", "cc24074"),''')
replace_once(
    "scripts/specialist.py",
    '''RUNTIME_MODULES = {\n    "siglip2-so400m-naflex": ("PIL", "torch", "transformers", "accelerate", "safetensors"),''',
    '''RUNTIME_MODULES = {\n    "siglip2-base-naflex": ("PIL", "torch", "transformers", "accelerate", "safetensors"),\n    "siglip2-so400m-naflex": ("PIL", "torch", "transformers", "accelerate", "safetensors"),''')
replace_once(
    "scripts/specialist.py",
    '''WARM_MODELS = {\n    "siglip2-so400m-naflex",\n    "dinov3-vitb16-lvd1689m",\n}''',
    '''SIGLIP_MODELS = {\n    "siglip2-base-naflex",\n    "siglip2-so400m-naflex",\n}\nWARM_MODELS = SIGLIP_MODELS | {"dinov3-vitb16-lvd1689m"}''')
replace_once(
    "scripts/specialist.py",
    '''def _prepare_for_model(model_id: str) -> None:\n    if model_id in TRANSIENT_MODELS:\n        # A transient specialist gets the machine to itself. This is the key RAM invariant:\n        # SigLIP/DINO/Paddle/LLMs/VLMs never stack during an escalation batch.\n        _drop_cached_models()\n        return\n    # Warm embedding models may coexist with one another, but never with a leaked transient model.\n    leaked = set(_CACHE) - WARM_MODELS\n    if leaked:\n        _drop_cached_models(keep=set(_CACHE) & WARM_MODELS)\n''',
    '''def _prepare_for_model(model_id: str) -> None:\n    if model_id in TRANSIENT_MODELS:\n        # A transient specialist gets the machine to itself. This is the key RAM invariant:\n        # SigLIP/DINO/Paddle/LLMs/VLMs never stack during an escalation batch.\n        _drop_cached_models()\n        return\n\n    keep = set(_CACHE) & WARM_MODELS\n    if model_id in SIGLIP_MODELS:\n        # Base and So400m produce incompatible semantic spaces. Keep DINO plus\n        # this exact semantic encoder, but evict the alternate SigLIP before\n        # loading so a 16-GB Mac never stacks both checkpoints.\n        keep -= SIGLIP_MODELS - {model_id}\n    if set(_CACHE) != keep:\n        _drop_cached_models(keep=keep)\n''')
replace_once(
    "scripts/specialist.py",
    '''def _memory_policy_self_test() -> None:\n    # Dependency-free invariant test used by CI. Dummy objects prove transient escalation evicts\n    # warm encoders, while warm-to-warm transitions are allowed to retain both encoders.\n    _CACHE.clear()\n    _CACHE["siglip2-so400m-naflex"] = object()\n    _CACHE["dinov3-vitb16-lvd1689m"] = object()\n    _prepare_for_model("minicpm-v-4.6")\n    if _CACHE:\n        raise RuntimeError("transient model did not evict warm model cache")\n    _CACHE["siglip2-so400m-naflex"] = object()\n    _prepare_for_model("dinov3-vitb16-lvd1689m")\n    if set(_CACHE) != {"siglip2-so400m-naflex"}:\n        raise RuntimeError("warm model policy evicted compatible encoder")\n    _CACHE.clear()\n''',
    '''def _memory_policy_self_test() -> None:\n    # Dependency-free invariant test used by CI. Transient escalation evicts\n    # every warm encoder, DINO may coexist with one semantic encoder, and the\n    # two incompatible SigLIP variants are mutually exclusive.\n    _CACHE.clear()\n    _CACHE["siglip2-base-naflex"] = object()\n    _CACHE["dinov3-vitb16-lvd1689m"] = object()\n    _prepare_for_model("minicpm-v-4.6")\n    if _CACHE:\n        raise RuntimeError("transient model did not evict warm model cache")\n\n    _CACHE["siglip2-base-naflex"] = object()\n    _prepare_for_model("dinov3-vitb16-lvd1689m")\n    if set(_CACHE) != {"siglip2-base-naflex"}:\n        raise RuntimeError("DINO preparation evicted compatible semantic encoder")\n\n    _CACHE["dinov3-vitb16-lvd1689m"] = object()\n    _prepare_for_model("siglip2-so400m-naflex")\n    if set(_CACHE) != {"dinov3-vitb16-lvd1689m"}:\n        raise RuntimeError("So400m preparation did not evict Base")\n\n    _CACHE["siglip2-so400m-naflex"] = object()\n    _prepare_for_model("siglip2-base-naflex")\n    if _CACHE:\n        raise RuntimeError("Base preparation did not evict So400m")\n    _CACHE.clear()\n''')
replace_once(
    "scripts/specialist.py",
    '''def _load_siglip():\n    key = "siglip2-so400m-naflex"\n    if key in _CACHE:\n        return _CACHE[key]\n    if not _verify_snapshot(key):\n        raise RuntimeError(f"untrusted/unprovisioned model: {key}")\n    _prepare_for_model(key)\n    import torch\n    from transformers import AutoModel, AutoProcessor\n    path = str(_model_dir(key))\n    processor = AutoProcessor.from_pretrained(path, local_files_only=True, trust_remote_code=False)\n    target, load_kwargs = _warm_encoder_load_kwargs(torch)\n    model = AutoModel.from_pretrained(\n        path, local_files_only=True, trust_remote_code=False, **load_kwargs)\n    if target == "mps":\n        model = model.to("mps")\n    model.eval()\n    _CACHE[key] = (model, processor)\n    return model, processor\n\n\ndef _siglip_image(image) -> dict:\n    import torch\n    model, processor = _load_siglip()\n    with torch.inference_mode():\n        inputs = _move_encoder_inputs(\n            processor(images=image, return_tensors="pt"), model, torch)\n        if hasattr(model, "get_image_features"):\n            vector = model.get_image_features(**inputs)\n        else:\n            output = model(**inputs)\n            vector = getattr(output, "image_embeds", None)\n            if vector is None:\n                vector = getattr(output, "pooler_output", None)\n            if vector is None:\n                raise RuntimeError("SigLIP2 runtime exposed no image embedding")\n    values = _normalize_tensor(vector)\n    return {"model": "siglip2-so400m-naflex", "space": "siglip2-joint", "dim": len(values), "vector": values}\n\n\ndef _siglip_text(text: str) -> dict:\n    import torch\n    model, processor = _load_siglip()\n    with torch.inference_mode():\n        inputs = _move_encoder_inputs(\n            processor(text=[text[:MAX_TEXT_CHARS]], padding="max_length", return_tensors="pt"),\n            model, torch)\n        if hasattr(model, "get_text_features"):\n            vector = model.get_text_features(**inputs)\n        else:\n            output = model(**inputs)\n            vector = getattr(output, "text_embeds", None)\n            if vector is None:\n                vector = getattr(output, "pooler_output", None)\n            if vector is None:\n                raise RuntimeError("SigLIP2 runtime exposed no text embedding")\n    values = _normalize_tensor(vector)\n    return {"model": "siglip2-so400m-naflex", "space": "siglip2-joint", "dim": len(values), "vector": values}\n''',
    '''def _load_siglip(key: str):\n    if key not in SIGLIP_MODELS:\n        raise ValueError(f"model is not a configured SigLIP encoder: {key!r}")\n    if key in _CACHE:\n        return _CACHE[key]\n    if not _verify_snapshot(key):\n        raise RuntimeError(f"untrusted/unprovisioned model: {key}")\n    _prepare_for_model(key)\n    import torch\n    from transformers import AutoModel, AutoProcessor\n    path = str(_model_dir(key))\n    processor = AutoProcessor.from_pretrained(path, local_files_only=True, trust_remote_code=False)\n    target, load_kwargs = _warm_encoder_load_kwargs(torch)\n    model = AutoModel.from_pretrained(\n        path, local_files_only=True, trust_remote_code=False, **load_kwargs)\n    if target == "mps":\n        model = model.to("mps")\n    model.eval()\n    _CACHE[key] = (model, processor)\n    return model, processor\n\n\ndef _siglip_image(image, model_id: str) -> dict:\n    import torch\n    model, processor = _load_siglip(model_id)\n    with torch.inference_mode():\n        inputs = _move_encoder_inputs(\n            processor(images=image, return_tensors="pt"), model, torch)\n        if hasattr(model, "get_image_features"):\n            vector = model.get_image_features(**inputs)\n        else:\n            output = model(**inputs)\n            vector = getattr(output, "image_embeds", None)\n            if vector is None:\n                vector = getattr(output, "pooler_output", None)\n            if vector is None:\n                raise RuntimeError("SigLIP2 runtime exposed no image embedding")\n    values = _normalize_tensor(vector)\n    return {"model": model_id, "space": f"{model_id}-joint", "dim": len(values), "vector": values}\n\n\ndef _siglip_text(text: str, model_id: str) -> dict:\n    import torch\n    model, processor = _load_siglip(model_id)\n    with torch.inference_mode():\n        inputs = _move_encoder_inputs(\n            processor(text=[text[:MAX_TEXT_CHARS]], padding="max_length", return_tensors="pt"),\n            model, torch)\n        if hasattr(model, "get_text_features"):\n            vector = model.get_text_features(**inputs)\n        else:\n            output = model(**inputs)\n            vector = getattr(output, "text_embeds", None)\n            if vector is None:\n                vector = getattr(output, "pooler_output", None)\n            if vector is None:\n                raise RuntimeError("SigLIP2 runtime exposed no text embedding")\n    values = _normalize_tensor(vector)\n    return {"model": model_id, "space": f"{model_id}-joint", "dim": len(values), "vector": values}\n''')
replace_once(
    "scripts/specialist.py",
    '''    if op == "siglip_image":\n        _, image = _decode_image(str(request.get("data_b64", "")))\n        return _siglip_image(image)\n    if op == "siglip_text":\n        return _siglip_text(str(request.get("text", ""))[:MAX_TEXT_CHARS])\n''',
    '''    if op == "siglip_image":\n        model_id = str(request.get("model", "siglip2-so400m-naflex"))\n        if model_id not in SIGLIP_MODELS:\n            raise ValueError("model is not a configured SigLIP encoder")\n        _, image = _decode_image(str(request.get("data_b64", "")))\n        return _siglip_image(image, model_id)\n    if op == "siglip_text":\n        model_id = str(request.get("model", "siglip2-so400m-naflex"))\n        if model_id not in SIGLIP_MODELS:\n            raise ValueError("model is not a configured SigLIP encoder")\n        return _siglip_text(str(request.get("text", ""))[:MAX_TEXT_CHARS], model_id)\n''')
replace_once(
    "scripts/specialist.py",
    '''            "warm_encoder_backend": "mps-fp16-when-available; cpu-fp32-fallback",\n''',
    '''            "warm_encoder_backend": "mps-fp16-when-available; cpu-fp32-fallback",\n            "semantic_encoder_policy": "profile-exclusive-base-or-so400m",\n''')

# Indexing and query-time search must select the same profile-specific space.
replace_once(
    "Sources/LibrarianCore/Indexing/Indexer.swift",
    '''            self.embeddingProvider = LocalEmbeddingProviderSelection.make(\n                enabled: options.enableLocalEmbeddings,\n                requestedProviderKind: options.embeddingProviderKind,\n                specialistBridge: specialistBridge)''',
    '''            self.embeddingProvider = LocalEmbeddingProviderSelection.make(\n                enabled: options.enableLocalEmbeddings,\n                profile: options.localModelProfile,\n                requestedProviderKind: options.embeddingProviderKind,\n                specialistBridge: specialistBridge)''')
replace_once(
    "Sources/LibrarianCore/Indexing/Indexer.swift",
    '''    public static let embeddingSpaceVersion = "emb-v3:mclip-s0|siglip2-cc24074:1152|dinov3-5931719:768|minilm-1110a243:384"''',
    '''    public static let embeddingSpaceVersion = "emb-v4:mclip-s0|siglip2-base-b53b807:768|siglip2-so400m-cc24074:1152|dinov3-5931719:768|minilm-1110a243:384"''')
replace_once(
    "Sources/LibrarianCore/Search/SearchService.swift",
    '''            self.embeddingProvider = LocalEmbeddingProviderSelection.make(\n                enabled: enabled,\n                requestedProviderKind: embeddingProviderKind)''',
    '''            self.embeddingProvider = LocalEmbeddingProviderSelection.make(\n                enabled: enabled,\n                profile: localModelProfile,\n                requestedProviderKind: embeddingProviderKind)''')

# Product readiness/UI follows the selected semantic model instead of treating
# So400m as the universal requirement.
replace_once(
    "Sources/LibrarianApp/Library/LibrarianModel+ModelReadiness.swift",
    '''        case .balanced:\n            let required = [\n                LocalModelStack.siglip2.id,\n                LocalModelStack.miniCPM.id,\n            ]\n            return isTier2Provisioned && required.allSatisfy(specialistProvisionedIDs.contains)\n        case .quality:\n            let required = [\n                LocalModelStack.siglip2.id,\n                LocalModelStack.miniCPM.id,\n                LocalModelStack.lfm.id,\n            ]''',
    '''        case .balanced:\n            let required = [\n                LocalModelStack.siglip2Base.id,\n                LocalModelStack.miniCPM.id,\n            ]\n            return isTier2Provisioned && required.allSatisfy(specialistProvisionedIDs.contains)\n        case .quality:\n            let required = [\n                LocalModelStack.siglip2So400m.id,\n                LocalModelStack.miniCPM.id,\n                LocalModelStack.lfm.id,\n            ]''')
replace_once(
    "Sources/LibrarianApp/Library/AppEntryPoint.swift",
    '''            if readiness.specialistRuntimeIDs.contains(LocalModelStack.siglip2.id) {\n                self.tier2Status = "Tier-2 ready — local SigLIP2 specialist"\n            } else if readiness.coreML {''',
    '''            if let semantic = LocalModelStack.semanticModel(for: self.localModelProfile),\n               readiness.specialistRuntimeIDs.contains(semantic.id) {\n                self.tier2Status = semantic.id == LocalModelStack.siglip2Base.id\n                    ? "Tier-2 ready — SigLIP2 Base NaFlex"\n                    : "Tier-2 ready — SigLIP2 So400m NaFlex"\n            } else if readiness.coreML {''')
replace_once(
    "Sources/LibrarianApp/App/SimpleSettingsView.swift",
    '''        case .fast:\n            return [LocalModelStack.siglip2]\n        case .balanced:\n            return [\n                LocalModelStack.siglip2,\n                LocalModelStack.paddleOCR,\n                LocalModelStack.miniCPM,\n            ]\n        case .quality:\n            return [\n                LocalModelStack.siglip2,\n                LocalModelStack.paddleOCR,\n                LocalModelStack.miniCPM,\n                LocalModelStack.lfm,\n            ]''',
    '''        case .fast:\n            return []\n        case .balanced:\n            return [\n                LocalModelStack.siglip2Base,\n                LocalModelStack.paddleOCR,\n                LocalModelStack.miniCPM,\n            ]\n        case .quality:\n            return [\n                LocalModelStack.siglip2So400m,\n                LocalModelStack.paddleOCR,\n                LocalModelStack.miniCPM,\n                LocalModelStack.lfm,\n            ]''')
replace_once(
    "Sources/LibrarianApp/App/SimpleSettingsView.swift",
    '''        case LocalModelStack.siglip2.id: return "SigLIP2"\n        case LocalModelStack.dinov3.id: return "DINOv3"''',
    '''        case LocalModelStack.siglip2Base.id: return "SigLIP2 Base NaFlex"\n        case LocalModelStack.siglip2So400m.id: return "SigLIP2 So400m NaFlex"\n        case LocalModelStack.dinov3.id: return "DINOv3"''')
replace_once(
    "Sources/LibrarianApp/Library/ModelSetupView.swift",
    '''        case .balanced:\n            return "Downloads the public local models used for better image meaning and bounded ambiguity handling."\n        case .quality:\n            return "Downloads the Balanced stack plus the larger public Quality fallback for difficult images."''',
    '''        case .balanced:\n            return "Downloads SigLIP2 Base NaFlex for fast screenshot meaning plus bounded ambiguity handling."\n        case .quality:\n            return "Downloads the larger SigLIP2 So400m semantic encoder plus the bounded Quality fallback for difficult images."''')

# Tests lock the new profile semantics and prevent a future accidental stack of
# both semantic encoders.
replace_once(
    "Tests/LibrarianTests/LocalModelRouterTests.swift",
    '''        XCTAssertEqual(route.map(\\.id), [LocalModelStack.siglip2.id, LocalModelStack.dinov3.id])\n        XCTAssertTrue(route.allSatisfy { $0.capability == .imageSemantic || $0.capability == .visualSimilarity })''',
    '''        XCTAssertTrue(route.isEmpty, "Fast must remain the zero-download/no-Python profile")''')
replace_once(
    "Tests/LibrarianTests/LocalModelRouterTests.swift",
    '''            LocalModelStack.siglip2.id,\n            LocalModelStack.dinov3.id,''',
    '''            LocalModelStack.siglip2Base.id,\n            LocalModelStack.dinov3.id,''')
replace_once(
    "Tests/LibrarianTests/LocalModelRouterTests.swift",
    '''        XCTAssertEqual(clear.map(\\.id), [LocalModelStack.siglip2.id, LocalModelStack.dinov3.id])''',
    '''        XCTAssertEqual(clear.map(\\.id), [LocalModelStack.siglip2Base.id, LocalModelStack.dinov3.id])''')
replace_once(
    "Tests/LibrarianTests/LocalModelRouterTests.swift",
    '''        XCTAssertFalse(clear.contains { $0.cost == .heavy })''',
    '''        XCTAssertFalse(clear.contains { $0.cost == .heavy })\n        XCTAssertTrue(clear.contains { $0.id == LocalModelStack.siglip2So400m.id })\n        XCTAssertFalse(clear.contains { $0.id == LocalModelStack.siglip2Base.id })''')
replace_once(
    "Tests/LibrarianTests/LocalModelRouterTests.swift",
    '''    func testSigLIPAndDINOUseDifferentSpacesAndDimensions() {\n        XCTAssertNotEqual(SpecialistModelBridge.siglipSpaceID, SpecialistModelBridge.dinoSpaceID)\n        XCTAssertNotEqual(SpecialistModelBridge.siglipDimension, SpecialistModelBridge.dinoDimension)\n        XCTAssertEqual(SpecialistModelBridge.siglipDimension, 1152)\n        XCTAssertEqual(SpecialistModelBridge.dinoDimension, 768)\n    }''',
    '''    func testProfileSelectsExactlyOneSemanticEncoder() {\n        XCTAssertNil(LocalModelStack.semanticModel(for: .fast))\n        XCTAssertEqual(LocalModelStack.semanticModel(for: .balanced)?.id, LocalModelStack.siglip2Base.id)\n        XCTAssertEqual(LocalModelStack.semanticModel(for: .quality)?.id, LocalModelStack.siglip2So400m.id)\n    }\n\n    func testSigLIPVariantsAndDINOUseExplicitSpacesAndDimensions() {\n        let baseSpace = SpecialistModelBridge.siglipSpaceID(for: LocalModelStack.siglip2Base)\n        let qualitySpace = SpecialistModelBridge.siglipSpaceID(for: LocalModelStack.siglip2So400m)\n        XCTAssertNotEqual(baseSpace, qualitySpace)\n        XCTAssertNotEqual(baseSpace, SpecialistModelBridge.dinoSpaceID)\n        XCTAssertNotEqual(qualitySpace, SpecialistModelBridge.dinoSpaceID)\n        XCTAssertEqual(SpecialistModelBridge.siglipDimension(for: LocalModelStack.siglip2Base), 768)\n        XCTAssertEqual(SpecialistModelBridge.siglipDimension(for: LocalModelStack.siglip2So400m), 1152)\n        XCTAssertEqual(SpecialistModelBridge.dinoDimension, 768)\n    }''')

replace_once(
    "scripts/test_specialist_contract.py",
    '''        self.assertTrue(provisioner.MODELS["dinov3-vitb16-lvd1689m"].get("gated"))\n''',
    '''        self.assertTrue(provisioner.MODELS["dinov3-vitb16-lvd1689m"].get("gated"))\n        self.assertIn("siglip2-base-naflex", provisioner.selected_for_profile("balanced"))\n        self.assertNotIn("siglip2-so400m-naflex", provisioner.selected_for_profile("balanced"))\n        self.assertIn("siglip2-so400m-naflex", provisioner.selected_for_profile("quality"))\n        self.assertNotIn("siglip2-base-naflex", provisioner.selected_for_profile("quality"))\n''')

print("one-shot profile migration patches applied")
