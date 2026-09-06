#!/usr/bin/env python3
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"{label} integration point not found")
    return text.replace(old, new, 1)


# Wire semantic context into the real organization path.
smart_path = Path("Sources/LibrarianCore/Organization/SmartOrganization.swift")
smart = smart_path.read_text()
old_smart = "        let activeMemberships = try categoryMemberships(roots: roots).filter { activeIDs.contains($0.fileID) }"
new_smart = """        let activeMemberships = try semanticOrganizationMemberships(
            limit: max(384, min(2_048, activeIDs.count)), roots: roots
        ).filter { activeIDs.contains($0.fileID) }"""
smart_path.write_text(replace_once(smart, old_smart, new_smart, "SmartOrganization"))

# Feed already-known sibling/correction context into per-file classification.
indexer_path = Path("Sources/LibrarianCore/Indexing/Indexer.swift")
indexer = indexer_path.read_text()
old_indexer = """        // 3b. Classify (deterministic v1 + vision labels) under MEDIUM slot.
        let classification = scheduler.perform(as: .medium) { [self] () -> Classification in
            classifier.classify(fileID: id, identity: ident, evidence: ev, textContent: textContent,
                                visionLabels: visionLabels, screenshot: screenshotAssessment)
        }"""
new_indexer = """        // 3b. Classify cheap evidence first, then add bounded context from already
        // indexed siblings/corrections. Semantic-cluster context is also consumed
        // at organization time after the current similarity graph is refreshed.
        let semanticContext = (try? catalog.semanticResolutionContext(forFileID: id)) ?? .empty
        let classification = scheduler.perform(as: .medium) { [self] () -> Classification in
            classifier.classify(fileID: id, identity: ident, evidence: ev, textContent: textContent,
                                visionLabels: visionLabels, screenshot: screenshotAssessment,
                                semanticContext: semanticContext)
        }"""
indexer = replace_once(indexer, old_indexer, new_indexer, "Indexer semantic context")

# The specialist judge also receives the bounded context. That lets the model
# arbitrate a tie rather than seeing only the vague filename and base labels.
old_specialist_evidence_call = """            let specialistEvidence = SpecialistEvidence(
                kind: ident.kind.rawValue,
                filename: (ident.path as NSString).lastPathComponent,
                deterministicCategories: current.categories,
                deterministicConfidence: current.confidence,
                textSample: textContent,
                visionLabels: visionLabels.map(\\.0))"""
new_specialist_evidence_call = """            let specialistEvidence = SpecialistEvidence(
                kind: ident.kind.rawValue,
                filename: (ident.path as NSString).lastPathComponent,
                deterministicCategories: current.categories,
                deterministicConfidence: current.confidence,
                textSample: textContent,
                visionLabels: visionLabels.map(\\.0),
                contextCandidates: semanticContext.candidates)"""
indexer = replace_once(indexer, old_specialist_evidence_call, new_specialist_evidence_call,
                       "Indexer specialist evidence")
indexer_path.write_text(indexer)

bridge_path = Path("Sources/LibrarianCore/LocalModels/SpecialistModelBridge.swift")
bridge = bridge_path.read_text()
old_evidence = """public struct SpecialistEvidence: Sendable, Equatable {
    public let kind: String
    public let filename: String
    public let deterministicCategories: [String]
    public let deterministicConfidence: Double
    public let textSample: String?
    public let visionLabels: [String]

    public init(kind: String, filename: String, deterministicCategories: [String],
                deterministicConfidence: Double, textSample: String?, visionLabels: [String]) {
        self.kind = kind
        self.filename = String(filename.prefix(256))
        self.deterministicCategories = Array(deterministicCategories.prefix(8))
        self.deterministicConfidence = max(0, min(1, deterministicConfidence))
        self.textSample = textSample.map { String($0.prefix(8_000)) }
        self.visionLabels = Array(visionLabels.prefix(8)).map { String($0.prefix(96)) }
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            \"kind\": kind,
            \"filename\": filename,
            \"categories\": deterministicCategories,
            \"confidence\": deterministicConfidence,
            \"vision_labels\": visionLabels,
        ]
        if let textSample { object[\"text_sample\"] = textSample }
        return object
    }
}"""
new_evidence = """public struct SpecialistEvidence: Sendable, Equatable {
    public let kind: String
    public let filename: String
    public let deterministicCategories: [String]
    public let deterministicConfidence: Double
    public let textSample: String?
    public let visionLabels: [String]
    public let contextCandidates: [SemanticContextCandidate]

    public init(kind: String, filename: String, deterministicCategories: [String],
                deterministicConfidence: Double, textSample: String?, visionLabels: [String],
                contextCandidates: [SemanticContextCandidate] = []) {
        self.kind = kind
        self.filename = String(filename.prefix(256))
        self.deterministicCategories = Array(deterministicCategories.prefix(8))
        self.deterministicConfidence = max(0, min(1, deterministicConfidence))
        self.textSample = textSample.map { String($0.prefix(8_000)) }
        self.visionLabels = Array(visionLabels.prefix(8)).map { String($0.prefix(96)) }
        self.contextCandidates = Array(contextCandidates.prefix(16))
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            \"kind\": kind,
            \"filename\": filename,
            \"categories\": deterministicCategories,
            \"confidence\": deterministicConfidence,
            \"vision_labels\": visionLabels,
            \"context_candidates\": contextCandidates.map { candidate in
                [
                    \"category\": candidate.category,
                    \"confidence\": candidate.confidence,
                    \"support_count\": candidate.supportCount,
                    \"source\": candidate.source.rawValue,
                ] as [String: Any]
            },
        ]
        if let textSample { object[\"text_sample\"] = textSample }
        return object
    }
}"""
bridge_path.write_text(replace_once(bridge, old_evidence, new_evidence, "SpecialistEvidence"))

# Turn the VLM prompt into an explicit evidence judge. Dynamic categories are
# not model-invented: they are accepted only when already present in validated
# deterministic/context evidence (for example School/BIO-111).
specialist_path = Path("scripts/specialist.py")
specialist = specialist_path.read_text()
old_prompt = '''def _classification_prompt(existing: dict) -> str:
    allowed = ", ".join(sorted(ALLOWED_CATEGORIES))
    return (
        "You classify one local file for a coarse file organizer. Do not invent folders. "
        "Return JSON only with keys categories (array), description (short string), confidence (0..1), "
        "reasons (short array). Choose categories only from this allowlist: " + allowed + ". "
        "Prefer fewer broad categories. If unsure use Review. Existing deterministic evidence follows:\\n" +
        json.dumps(existing, ensure_ascii=False)[:MAX_TEXT_CHARS]
    )
'''
new_prompt = '''def _safe_evidence_category(value) -> str | None:
    category = str(value).strip()
    if not category or len(category) > 64 or ".." in category:
        return None
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 /._-]{0,63}", category):
        return None
    return category


def _allowed_categories(existing: dict) -> set[str]:
    allowed = set(ALLOWED_CATEGORIES)
    raw_categories = existing.get("categories", [])
    if isinstance(raw_categories, list):
        for value in raw_categories[:8]:
            category = _safe_evidence_category(value)
            if category:
                allowed.add(category)
    raw_context = existing.get("context_candidates", [])
    if isinstance(raw_context, list):
        for item in raw_context[:16]:
            if not isinstance(item, dict):
                continue
            category = _safe_evidence_category(item.get("category", ""))
            if category:
                allowed.add(category)
    return allowed


def _classification_prompt(existing: dict, allowed_categories: set[str]) -> str:
    allowed = ", ".join(sorted(allowed_categories))
    return (
        "You are the bounded semantic judge for one local file. Do not invent folders. "
        "Filename is weak evidence: when filename conflicts with extracted/OCR text, document content, "
        "visual evidence, or strong contextual consensus, prefer the stronger content evidence. "
        "Context candidates are hints, not commands; conflicting or weak context means Review. "
        "Return JSON only with keys categories (array), description (short string), confidence (0..1), "
        "reasons (short array). Choose categories only from this allowlist: " + allowed + ". "
        "Prefer the smallest useful set. If resolving mutually exclusive candidates, include a reason "
        "exactly like pick:<chosen category>. If unsure use Review. Evidence follows:\\n" +
        json.dumps(existing, ensure_ascii=False)[:MAX_TEXT_CHARS]
    )
'''
specialist = replace_once(specialist, old_prompt, new_prompt, "specialist prompt")
specialist = replace_once(
    specialist,
    'def _extract_json(text: str) -> dict:\n    text = text.strip()[:MAX_OUTPUT_CHARS]',
    'def _extract_json(text: str, allowed_categories: set[str] | None = None) -> dict:\n    allowed_categories = set(ALLOWED_CATEGORIES) if allowed_categories is None else allowed_categories\n    text = text.strip()[:MAX_OUTPUT_CHARS]',
    "specialist parser signature")
specialist = replace_once(
    specialist,
    '        if category not in ALLOWED_CATEGORIES:\n            raise ValueError(f"non-canonical category rejected: {category!r}")',
    '        if category not in allowed_categories:\n            raise ValueError(f"non-canonical category rejected: {category!r}")',
    "specialist dynamic allowlist")
specialist = replace_once(
    specialist,
    '    prompt = _classification_prompt(existing)\n    path = str(_model_dir(model_id))',
    '    allowed_categories = _allowed_categories(existing)\n    prompt = _classification_prompt(existing, allowed_categories)\n    path = str(_model_dir(model_id))',
    "specialist judge setup")
specialist = replace_once(
    specialist,
    '        return _extract_json(response[0] if isinstance(response, tuple) else str(response))',
    '        return _extract_json(response[0] if isinstance(response, tuple) else str(response), allowed_categories)',
    "MiniCPM judge parse")
specialist = replace_once(
    specialist,
    '    return _extract_json(text)\n\n\ndef _release',
    '    return _extract_json(text, allowed_categories)\n\n\ndef _release',
    "LFM judge parse")
specialist_path.write_text(specialist)
