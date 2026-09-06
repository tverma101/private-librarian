#!/usr/bin/env python3
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"{label} integration point not found")
    return text.replace(old, new, 1)


router_path = Path("Sources/LibrarianCore/LocalModels/LocalModelRouter.swift")
router = router_path.read_text()
old = '''        if profile == .quality, unresolvedBaselineImage, context.kind == .image {
            // LFM2.5-VL-3B is the largest supported fallback. Larger candidates
            // were removed rather than relying on swap/offload to hide a RAM violation.
            append(LocalModelStack.lfm)
        }
        return route
'''
new = '''        if profile == .quality, unresolvedBaselineImage, context.kind == .image {
            // LFM2.5-VL-3B is the largest supported fallback. Larger candidates
            // were removed rather than relying on swap/offload to hide a RAM violation.
            append(LocalModelStack.lfm)
        }

        // LFM2.5-VL-3B is multimodal and can process text without an image. In
        // Quality mode, reuse that already-supported transient checkpoint as the
        // bounded semantic judge for generic documents instead of adding another
        // resident model. Fast/Balanced remain unchanged, and content must have
        // been extracted locally before this route can fire.
        let documentKind = context.kind == .pdf || context.kind == .text || context.kind == .office
        if profile == .quality,
           documentKind,
           context.hasUsefulText,
           context.confidence < SemanticResolver.specialistEscalationThreshold {
            append(LocalModelStack.lfm)
        }
        return route
'''
router_path.write_text(replace_once(router, old, new, "LocalModelRouter text judge"))

bridge_path = Path("Sources/LibrarianCore/LocalModels/SpecialistModelBridge.swift")
bridge = bridge_path.read_text()
old = '''    public func classifyText(model: LocalModelDescriptor,
                             evidence: SpecialistEvidence,
                             timeout: TimeInterval = 120) -> SpecialistClassification? {
        guard model.capability == .textReasoning, Self.isProvisioned(model), let worker else { return nil }
        defer { _ = worker.call(["op": "release", "model": model.id], timeout: 8) }
        return Self.parseClassification(
            worker.call(["op": "classify_text", "evidence": evidence.jsonObject], timeout: timeout),
            modelID: model.id)
    }
'''
new = '''    public func classifyText(model: LocalModelDescriptor,
                             evidence: SpecialistEvidence,
                             timeout: TimeInterval = 120) -> SpecialistClassification? {
        let supportedTextJudge = model.capability == .textReasoning
            || (model.id == LocalModelStack.lfm.id && model.capability == .visionHeavyFallback)
        guard supportedTextJudge, Self.isProvisioned(model), let worker else { return nil }
        defer { _ = worker.call(["op": "release", "model": model.id], timeout: 8) }
        return Self.parseClassification(
            worker.call(["op": "classify_text", "model": model.id,
                         "evidence": evidence.jsonObject], timeout: timeout),
            modelID: model.id)
    }
'''
bridge_path.write_text(replace_once(bridge, old, new, "SpecialistModelBridge classifyText"))

indexer_path = Path("Sources/LibrarianCore/Indexing/Indexer.swift")
indexer = indexer_path.read_text()
old = '''                case .visionFallback, .visionHeavyFallback:
                    guard let bytes = imageBytes, !bytes.isEmpty else { continue }
                    result = scheduler.perform(as: .heavy) {
                        specialistBridge.classifyImage(bytes, model: model, evidence: specialistEvidence)
                    }
                case .imageSemantic, .visualSimilarity, .documentOCR:
                    continue
'''
new = '''                case .visionFallback:
                    guard let bytes = imageBytes, !bytes.isEmpty else { continue }
                    result = scheduler.perform(as: .heavy) {
                        specialistBridge.classifyImage(bytes, model: model, evidence: specialistEvidence)
                    }
                case .visionHeavyFallback:
                    if ident.kind == .image {
                        guard let bytes = imageBytes, !bytes.isEmpty else { continue }
                        result = scheduler.perform(as: .heavy) {
                            specialistBridge.classifyImage(bytes, model: model, evidence: specialistEvidence)
                        }
                    } else if usefulText {
                        result = scheduler.perform(as: .heavy) {
                            specialistBridge.classifyText(model: model, evidence: specialistEvidence)
                        }
                    } else {
                        continue
                    }
                case .imageSemantic, .visualSimilarity, .documentOCR:
                    continue
'''
indexer_path.write_text(replace_once(indexer, old, new, "Indexer multimodal specialist dispatch"))

specialist_path = Path("scripts/specialist.py")
specialist = specialist_path.read_text()
marker = '''    return _extract_json(text, allowed_categories)\n\n\ndef _release(model_id: str | None) -> dict:\n'''
addition = '''    return _extract_json(text, allowed_categories)\n\n\ndef _text_classify(model_id: str, existing: dict) -> dict:\n    if model_id != "lfm2.5-vl-3b":\n        raise ValueError("model is not the configured text semantic judge")\n    if not _verify_snapshot(model_id):\n        raise RuntimeError(f"untrusted/unprovisioned model: {model_id}")\n    _prepare_for_model(model_id)\n    allowed_categories = _allowed_categories(existing)\n    prompt = _classification_prompt(existing, allowed_categories)\n    path = str(_model_dir(model_id))\n    AutoModelForImageTextToText, AutoProcessor = _transformers_classes(\n        "AutoModelForImageTextToText", "AutoProcessor")\n    cached = _CACHE.get(model_id)\n    if cached is None:\n        processor = AutoProcessor.from_pretrained(path, local_files_only=True, trust_remote_code=True)\n        model = AutoModelForImageTextToText.from_pretrained(\n            path, local_files_only=True, trust_remote_code=True,\n            **_large_model_load_kwargs(model_id))\n        model.eval()\n        cached = (model, processor)\n        _CACHE[model_id] = cached\n    model, processor = cached\n    conversation = [{"role": "user", "content": [{"type": "text", "text": prompt}]}]\n    inputs = processor.apply_chat_template(\n        conversation, add_generation_prompt=True, tokenize=True,\n        return_dict=True, return_tensors="pt")\n    device = getattr(model, "device", None)\n    if device is not None:\n        if hasattr(inputs, "to"):\n            inputs = inputs.to(device)\n        elif isinstance(inputs, dict):\n            inputs = {k: v.to(device) if hasattr(v, "to") else v for k, v in inputs.items()}\n    output = model.generate(**inputs, do_sample=False, max_new_tokens=320)\n    input_len = inputs["input_ids"].shape[-1] if "input_ids" in inputs else 0\n    text = processor.batch_decode(output[:, input_len:], skip_special_tokens=True)[0]\n    return _extract_json(text, allowed_categories)\n\n\ndef _release(model_id: str | None) -> dict:\n'''
specialist = replace_once(specialist, marker, addition, "specialist text classifier")

old_handler = '''    if op == "classify_image":\n        model_id = str(request.get("model", "minicpm-v-4.6"))\n        if model_id not in {"minicpm-v-4.6", "lfm2.5-vl-3b"}:\n            raise ValueError("model is not a configured VLM fallback")\n        _, image = _decode_image(str(request.get("data_b64", "")))\n        evidence = request.get("evidence") if isinstance(request.get("evidence"), dict) else {}\n        return _vlm_classify(model_id, image, evidence)\n    raise ValueError(f"unknown operation {op!r}")\n'''
new_handler = '''    if op == "classify_image":\n        model_id = str(request.get("model", "minicpm-v-4.6"))\n        if model_id not in {"minicpm-v-4.6", "lfm2.5-vl-3b"}:\n            raise ValueError("model is not a configured VLM fallback")\n        _, image = _decode_image(str(request.get("data_b64", "")))\n        evidence = request.get("evidence") if isinstance(request.get("evidence"), dict) else {}\n        return _vlm_classify(model_id, image, evidence)\n    if op == "classify_text":\n        model_id = str(request.get("model", "lfm2.5-vl-3b"))\n        if model_id != "lfm2.5-vl-3b":\n            raise ValueError("model is not the configured text semantic judge")\n        evidence = request.get("evidence") if isinstance(request.get("evidence"), dict) else {}\n        return _text_classify(model_id, evidence)\n    raise ValueError(f"unknown operation {op!r}")\n'''
specialist_path.write_text(replace_once(specialist, old_handler, new_handler, "specialist classify_text dispatch"))

router_test_path = Path("Tests/LibrarianTests/LocalModelRouterTests.swift")
router_tests = router_test_path.read_text()
marker = '''    func testRegistryExcludesModelsThatCannotRespectMacMemoryCeiling() {\n'''
addition = '''    func testQualityReusesLFMAsTextJudgeOnlyForAmbiguousDocuments() {\n        let available: Set<String> = [LocalModelStack.lfm.id]\n        let quality = LocalModelRouter(profile: .quality)\n        let vague = quality.route(\n            context: LocalModelRouteContext(kind: .pdf, confidence: 0.69,\n                                            hasUsefulText: true,\n                                            nativeOCRSucceeded: true,\n                                            isDocumentLikeImage: false),\n            availableModelIDs: available)\n        XCTAssertEqual(vague.map(\\.id), [LocalModelStack.lfm.id])\n\n        let clear = quality.route(\n            context: LocalModelRouteContext(kind: .pdf, confidence: 0.80,\n                                            hasUsefulText: true,\n                                            nativeOCRSucceeded: true,\n                                            isDocumentLikeImage: false),\n            availableModelIDs: available)\n        XCTAssertTrue(clear.isEmpty)\n\n        let noText = quality.route(\n            context: LocalModelRouteContext(kind: .office, confidence: 0.20,\n                                            hasUsefulText: false,\n                                            nativeOCRSucceeded: false,\n                                            isDocumentLikeImage: false),\n            availableModelIDs: available)\n        XCTAssertTrue(noText.isEmpty)\n\n        let balanced = LocalModelRouter(profile: .balanced).route(\n            context: LocalModelRouteContext(kind: .text, confidence: 0.20,\n                                            hasUsefulText: true,\n                                            nativeOCRSucceeded: true,\n                                            isDocumentLikeImage: false),\n            availableModelIDs: available)\n        XCTAssertTrue(balanced.isEmpty)\n    }\n\n    func testRegistryExcludesModelsThatCannotRespectMacMemoryCeiling() {\n'''
router_test_path.write_text(replace_once(router_tests, marker, addition, "router text judge test"))

contract_path = Path("scripts/test_specialist_contract.py")
contract = contract_path.read_text()
marker = '''    def test_full_verification_detects_mutation_after_status_probe(self) -> None:\n'''
addition = '''    def test_text_semantic_dispatch_is_lfm_only_and_model_free_in_contract_test(self) -> None:\n        with tempfile.TemporaryDirectory() as directory:\n            module = load_worker(Path(directory))\n            expected = {\n                "categories": ["Review"],\n                "description": "fixture",\n                "confidence": 0.4,\n                "reasons": ["fixture"],\n            }\n            with patch.object(module, "_text_classify", return_value=expected) as classify:\n                result = module._handle({\n                    "op": "classify_text",\n                    "model": "lfm2.5-vl-3b",\n                    "evidence": {"text_sample": "ambiguous document"},\n                })\n            self.assertEqual(result, expected)\n            classify.assert_called_once_with(\n                "lfm2.5-vl-3b", {"text_sample": "ambiguous document"})\n            with self.assertRaisesRegex(ValueError, "configured text semantic judge"):\n                module._handle({\n                    "op": "classify_text",\n                    "model": "minicpm-v-4.6",\n                    "evidence": {},\n                })\n\n    def test_full_verification_detects_mutation_after_status_probe(self) -> None:\n'''
contract_path.write_text(replace_once(contract, marker, addition, "specialist text dispatch test"))
