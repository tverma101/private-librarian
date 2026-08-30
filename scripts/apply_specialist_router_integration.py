#!/usr/bin/env python3
from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one match in {path}, found {count}: {old[:80]!r}")
    p.write_text(text.replace(old, new, 1))


INDEXER = "Sources/LibrarianCore/Indexer.swift"
APP = "Sources/LibrarianApp/PrivateLibrarianApp.swift"
VIEWS = "Sources/LibrarianApp/MagicViews.swift"
CI = ".github/workflows/ci.yml"

replace_once(
    INDEXER,
    '''        public var embeddingProviderKind: String? = nil
        /// Absolute source prefixes that are intentionally outside this scan.
''',
    '''        public var embeddingProviderKind: String? = nil
        /// Cheap-first specialist routing. Fast never uses generative models;
        /// balanced/quality may escalate only ambiguous files.
        public var localModelProfile: LocalModelProfile = .fast
        /// Absolute source prefixes that are intentionally outside this scan.
''')

replace_once(
    INDEXER,
    '''    public let embeddingProvider: any EmbeddingProvider
    private let embeddingAvailable: Bool
    private let metricsLock = NSLock()
''',
    '''    public let embeddingProvider: any EmbeddingProvider
    private let embeddingAvailable: Bool
    private let specialistBridge: SpecialistModelBridge?
    private let specialistRouter: LocalModelRouter
    private let availableSpecialistModelIDs: Set<String>
    private let metricsLock = NSLock()
''')

replace_once(
    INDEXER,
    '''        self.options = options
        self.evidence = EvidenceExtractor(broker: broker)
        if let p = embeddingProvider { self.embeddingProvider = p }
        else if let kind = options.embeddingProviderKind { self.embeddingProvider = EmbeddingProviderFactory.make(kind: kind) }
        else { self.embeddingProvider = LocalModelEmbeddingProvider() }
        let learnedRules = (try? catalog.listRules()) ?? []
''',
    '''        self.options = options
        self.evidence = EvidenceExtractor(broker: broker)
        let availableSpecialists = SpecialistModelBridge.availableModelIDs()
        let specialistBridge = availableSpecialists.isEmpty ? nil : SpecialistModelBridge()
        self.specialistBridge = specialistBridge
        self.specialistRouter = LocalModelRouter(profile: options.localModelProfile)
        self.availableSpecialistModelIDs = availableSpecialists
        if let p = embeddingProvider {
            self.embeddingProvider = p
        } else if options.localModelProfile != .fast {
            if let specialistBridge {
                self.embeddingProvider = SpecialistSigLIP2EmbeddingProvider(bridge: specialistBridge)
            } else {
                self.embeddingProvider = UnavailableEmbeddingProvider(
                    providerID: "specialist:siglip2-so400m-naflex@cc24074",
                    reason: "Balanced/quality profile requires a provisioned SigLIP2 specialist checkpoint.")
            }
        } else if availableSpecialists.contains(LocalModelStack.siglip2.id), let specialistBridge {
            // Fast remains non-generative, but if the chosen embedding stack is installed,
            // use it instead of silently staying on the legacy CLIP space.
            self.embeddingProvider = SpecialistSigLIP2EmbeddingProvider(bridge: specialistBridge)
        } else if let kind = options.embeddingProviderKind {
            self.embeddingProvider = EmbeddingProviderFactory.make(kind: kind)
        } else {
            self.embeddingProvider = LocalModelEmbeddingProvider()
        }
        let learnedRules = (try? catalog.listRules()) ?? []
''')

replace_once(
    INDEXER,
    '''    public static let embeddingSpaceVersion = "emb-v2:clip-3d74acf9|siglip-7fd15f06|mclip-71aa3e13|dino-ed25f3a3|minilm-1110a243|dim-512+384"
''',
    '''    public static let embeddingSpaceVersion = "emb-v3:mclip-s0|siglip2-cc24074:1152|dinov3-5931719:768|minilm-1110a243:384"
''')

replace_once(
    INDEXER,
    '''        if options.enableLocalEmbeddings {
            let clip = LocalModelBridge.isProvisioned(.clipImage) ? "clip:on" : "clip:off"
            let mini = LocalModelBridge.isProvisioned(.miniLMText) ? "minilm:on" : "minilm:off"
            let prov = providerID ?? options.embeddingProviderKind ?? LocalModelEmbeddingProvider().providerID
            parts.append("tier2:\(clip),\(mini),\(embeddingSpaceVersion),provider:\(prov)")
        } else {
            parts.append("tier2:off")
        }
''',
    '''        if options.enableLocalEmbeddings {
            let prov = providerID ?? options.embeddingProviderKind ?? LocalModelEmbeddingProvider().providerID
            let specialists = SpecialistModelBridge.availableModelIDs().sorted().joined(separator: ",")
            parts.append("tier2:\(embeddingSpaceVersion),provider:\(prov),profile:\(options.localModelProfile.rawValue),specialists:\(specialists)")
        } else {
            parts.append("tier2:off")
        }
''')

replace_once(
    INDEXER,
    '''        let ev = evidence.extract(identity: ident)
        var textContent: String? = ev.textSample

        switch ident.kind {
        case .pdf:
            if let pdfData = try? broker.completeSnapshot(path, maxBytes: 64 * 1024 * 1024),
               let pdfText = PDFText.extract(data: pdfData) {
                textContent = String(pdfText.prefix(200_000))
            }
''',
    '''        let ev = evidence.extract(identity: ident)
        var textContent: String? = ev.textSample
        var documentSnapshot: Data? = nil

        switch ident.kind {
        case .pdf:
            if let pdfData = try? broker.completeSnapshot(path, maxBytes: 64 * 1024 * 1024) {
                documentSnapshot = pdfData
                if let pdfText = PDFText.extract(data: pdfData) {
                    textContent = String(pdfText.prefix(200_000))
                }
            }
''')

replace_once(
    INDEXER,
    '''        // MARK: Media lane — audio/video probe + gating + sparse video frames
''',
    '''        // Optional specialist OCR is an escalation only. Native text/Vision OCR wins when
        // it already produced useful text, and source paths are never sent to the model helper.
        if options.localModelProfile != .fast,
           let specialistBridge,
           availableSpecialistModelIDs.contains(LocalModelStack.paddleOCR.id) {
            let nativeText = textContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let documentLikeImage = ident.kind == .image && (
                screenshotAssessment?.isScreenshot == true
                || visionLabels.contains { label, _ in
                    let lower = label.lowercased()
                    return lower.contains("text") || lower.contains("document") || lower.contains("paper")
                })
            let pdfNeedsOCR = ident.kind == .pdf && VisionOCR.needsOCR(pdfText: textContent)
            let nativeOCRSucceeded = !nativeText.isEmpty && !pdfNeedsOCR
            let route = specialistRouter.route(
                context: LocalModelRouteContext(
                    kind: ident.kind, confidence: 0, hasUsefulText: !nativeText.isEmpty,
                    nativeOCRSucceeded: nativeOCRSucceeded,
                    isDocumentLikeImage: documentLikeImage),
                availableModelIDs: availableSpecialistModelIDs)
            if route.contains(where: { $0.id == LocalModelStack.paddleOCR.id }),
               let bytes = imageBytes ?? documentSnapshot, !bytes.isEmpty {
                recordWork { $0.ocrCalls += 1 }
                let suffix = "." + (ident.path as NSString).pathExtension
                if let specialist = scheduler.perform(as: .heavy, {
                    specialistBridge.recognizeDocument(bytes, suffix: suffix, timeout: 90)
                }) {
                    let recovered = specialist.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !recovered.isEmpty {
                        if nativeText.isEmpty { textContent = recovered }
                        else if !nativeText.contains(recovered.prefix(256)) {
                            textContent = nativeText + "\n" + recovered
                        }
                        ocrExtractor = "paddleocr-vl-1.6"
                    }
                }
            }
        }

        // MARK: Media lane — audio/video probe + gating + sparse video frames
''')

replace_once(
    INDEXER,
    '''        var stagedMiniLM: EmbeddingVector? = nil
        var stagedChunks: [(index: Int, data: Data, dim: Int)] = []
        if options.enableLocalEmbeddings,
           let t = textContent, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           embeddingAvailable {
            recordWork { $0.textEmbedCalls += 1 }
            if let w = worker, embeddingProvider is LocalModelEmbeddingProvider,
               let result = w.embedText(t, timeout: 10) {
                stagedMiniLM = EmbeddingVector(spaceID: "text:\(embeddingProvider.providerID)",
                                               dim: result.dim, data: result.data)
            } else {
                stagedMiniLM = scheduler.perform(as: .medium) { [embeddingProvider] in
                    embeddingProvider.embedText(t)
                }
            }
            if stagedMiniLM?.data.isEmpty == true { stagedMiniLM = nil }
            // Pre-compute chunk embeddings *outside* the transaction so no
            // Python/model call holds the DB commit open.
            let chunks = LocalModelBridge.textChunks(t)
            if chunks.count > 1 {
                for (idx, chunk) in chunks.enumerated() {
                    recordWork { $0.textEmbedCalls += 1 }
                    if let w = worker, embeddingProvider is LocalModelEmbeddingProvider,
                       let ce = w.embedText(chunk, timeout: 8), !ce.data.isEmpty {
                        stagedChunks.append((idx, ce.data, ce.dim))
                    } else if let ce = scheduler.perform(as: .medium, { [embeddingProvider] in
                        embeddingProvider.embedText(chunk)
                    }),
                              !ce.data.isEmpty {
                        stagedChunks.append((idx, ce.data, ce.dim))
                    }
                }
            }
        }
''',
    '''        var stagedDINO: EmbeddingVector? = nil
        if options.enableLocalEmbeddings, ident.kind == .image,
           let bytes = imageBytes, !bytes.isEmpty,
           let specialistBridge,
           availableSpecialistModelIDs.contains(LocalModelStack.dinov3.id) {
            recordWork { $0.clipCalls += 1 }
            stagedDINO = scheduler.perform(as: .medium) {
                specialistBridge.embedDINOImage(bytes, timeout: 25)
            }
            if stagedDINO?.data.isEmpty == true { stagedDINO = nil }
        }

        var stagedMiniLM: EmbeddingVector? = nil
        var stagedChunks: [(index: Int, data: Data, dim: Int)] = []
        if options.enableLocalEmbeddings,
           let t = textContent, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           embeddingAvailable {
            let embedOne: (String, TimeInterval) -> EmbeddingVector? = { [worker, embeddingProvider, scheduler] text, timeout in
                self.recordWork { $0.textEmbedCalls += 1 }
                if let w = worker, embeddingProvider is LocalModelEmbeddingProvider,
                   let result = w.embedText(text, timeout: timeout) {
                    return EmbeddingVector(spaceID: "text:\(embeddingProvider.providerID)",
                                           dim: result.dim, data: result.data)
                }
                return scheduler.perform(as: .medium) { [embeddingProvider] in
                    embeddingProvider.embedText(text)
                }
            }
            switch SemanticCompaction.strategy(path: ident.path, text: t) {
            case .skip:
                break
            case .single(let primary):
                stagedMiniLM = embedOne(primary, 10)
            case .prose(let primary, let chunks):
                stagedMiniLM = embedOne(primary, 10)
                if chunks.count > 1 {
                    for (idx, chunk) in chunks.enumerated() {
                        if let ce = embedOne(chunk, 8), !ce.data.isEmpty {
                            stagedChunks.append((idx, ce.data, ce.dim))
                        }
                    }
                }
            }
            if stagedMiniLM?.data.isEmpty == true { stagedMiniLM = nil }
        }
''')

replace_once(
    INDEXER,
    '''        let hashToRecord: Data? = {
''',
    '''        // Only ambiguous results can wake generative specialists. Execute candidates in
        // cheap-first order and stop as soon as one produces a good schema-valid answer.
        if var current = validatedClass,
           current.confidence < 0.72,
           let specialistBridge,
           !availableSpecialistModelIDs.isEmpty {
            let usefulText = !(textContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let documentLikeImage = current.categories.contains("Image/Documents")
                || screenshotAssessment?.isScreenshot == true
            let route = specialistRouter.route(
                context: LocalModelRouteContext(
                    kind: ident.kind, confidence: current.confidence,
                    hasUsefulText: usefulText,
                    nativeOCRSucceeded: ocrExtractor != nil || usefulText,
                    isDocumentLikeImage: documentLikeImage),
                availableModelIDs: availableSpecialistModelIDs)
            let specialistEvidence = SpecialistEvidence(
                kind: ident.kind.rawValue,
                filename: (ident.path as NSString).lastPathComponent,
                deterministicCategories: current.categories,
                deterministicConfidence: current.confidence,
                textSample: textContent,
                visionLabels: visionLabels.map(\.0))
            for model in route where current.confidence < 0.72 {
                let result: SpecialistClassification?
                switch model.capability {
                case .textReasoning:
                    result = scheduler.perform(as: .heavy) {
                        specialistBridge.classifyText(model: model, evidence: specialistEvidence)
                    }
                case .visionFallback, .visionHeavyFallback:
                    guard let bytes = imageBytes, !bytes.isEmpty else { continue }
                    result = scheduler.perform(as: .heavy) {
                        specialistBridge.classifyImage(bytes, model: model, evidence: specialistEvidence)
                    }
                case .imageSemantic, .visualSimilarity, .documentOCR:
                    continue
                }
                guard let result else { continue }
                var categories = current.categories
                for category in result.categories
                    where !categories.contains(category) && categories.count < ClassifierContract.maxCategories {
                    categories.append(category)
                }
                let reasons = Array((current.reasonCodes
                    + ["specialist:\(result.modelID)"]
                    + result.reasons.map { "model:\($0)" })
                    .prefix(ClassifierContract.maxReasonCodes))
                let trial = Classification(
                    fileID: current.fileID,
                    categories: categories,
                    description: result.description.isEmpty ? current.description : result.description,
                    confidence: max(current.confidence, result.confidence),
                    reasonCodes: reasons)
                if let data = try? trial.jsonData(),
                   let validated = ClassifierContract.validate(data) {
                    current = validated
                    validatedClass = validated
                }
            }
        }

        let hashToRecord: Data? = {
''')

replace_once(
    INDEXER,
    '''                if let tr = stagedTranscript, !tr.segments.isEmpty {
''',
    '''                if let dino = stagedDINO {
                    try catalog.txRun("""
                        INSERT INTO embeddings(file_id, model, dim, vector) VALUES(?,?,?,?)
                        ON CONFLICT(file_id, model) DO UPDATE SET dim=excluded.dim, vector=excluded.vector
                        """, binds: [.text(id), .text("image:\(SpecialistModelBridge.dinoSpaceID)"),
                                      .int(Int64(dino.dim)), .blob(dino.data)])
                }
                if let tr = stagedTranscript, !tr.segments.isEmpty {
''')

replace_once(
    INDEXER,
    '''        for model in models {
            adapters.append(EmbeddingEdgeAdapter(model: model,
                                                 scorer: CatalogEmbeddingSimilarityScorer(),
                                                 minimumScore: 0.75))
        }
''',
    '''        for model in models where !model.contains("dinov3-visual") {
            adapters.append(EmbeddingEdgeAdapter(model: model,
                                                 scorer: CatalogEmbeddingSimilarityScorer(),
                                                 minimumScore: 0.75))
        }
''')

replace_once(
    APP,
    '''    @Published var localEmbeddingsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(localEmbeddingsEnabled, forKey: "tier2-enabled-v1")
            restartLiveCoordinator()
            refreshDashboard()
        }
    }
    @Published var searchMode: String = "auto" // auto | exact | semantic | visual | clipText
''',
    '''    @Published var localEmbeddingsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(localEmbeddingsEnabled, forKey: "tier2-enabled-v1")
            restartLiveCoordinator()
            refreshDashboard()
        }
    }
    @Published var localModelProfile: LocalModelProfile {
        didSet {
            UserDefaults.standard.set(localModelProfile.rawValue, forKey: "local-model-profile-v1")
            restartLiveCoordinator()
            refreshDashboard()
        }
    }
    @Published var searchMode: String = "auto" // auto | exact | semantic | visual | clipText
''')

replace_once(
    APP,
    '''    var isTier2Provisioned: Bool {
        CoreMLMobileCLIPProvider.isAvailable
            || LocalModelBridge.isProvisioned(.clipImage)
            || LocalModelBridge.isProvisioned(.miniLMText)
    }
''',
    '''    var isTier2Provisioned: Bool {
        CoreMLMobileCLIPProvider.isAvailable
            || LocalModelBridge.isProvisioned(.clipImage)
            || LocalModelBridge.isProvisioned(.miniLMText)
            || !SpecialistModelBridge.availableModelIDs().isEmpty
    }
''')

replace_once(
    APP,
    '''        self.localEmbeddingsEnabled = UserDefaults.standard.bool(forKey: "tier2-enabled-v1")
        if let m = UserDefaults.standard.string(forKey: "tier2-search-mode-v1") { self.searchMode = m }
''',
    '''        self.localEmbeddingsEnabled = UserDefaults.standard.bool(forKey: "tier2-enabled-v1")
        self.localModelProfile = LocalModelProfile(
            rawValue: UserDefaults.standard.string(forKey: "local-model-profile-v1") ?? "fast") ?? .fast
        if let m = UserDefaults.standard.string(forKey: "tier2-search-mode-v1") { self.searchMode = m }
''')

replace_once(
    APP,
    '''        options.enableLocalEmbeddings = localEmbeddingsEnabled
        options.embeddingProviderKind = CoreMLMobileCLIPProvider.isAvailable ? "coreml-mobileclip" : nil
        options.excludedPaths = effectiveExcludedPaths
''',
    '''        options.enableLocalEmbeddings = localEmbeddingsEnabled
        options.embeddingProviderKind = CoreMLMobileCLIPProvider.isAvailable ? "coreml-mobileclip" : nil
        options.localModelProfile = localModelProfile
        options.excludedPaths = effectiveExcludedPaths
''')

replace_once(
    VIEWS,
    '''                    Toggle("Local transcription", isOn: $model.localTranscriptionEnabled)
''',
    '''                    Picker("Model profile", selection: $model.localModelProfile) {
                        Text("Fast · embeddings only").tag(LocalModelProfile.fast)
                        Text("Balanced · specialist fallback").tag(LocalModelProfile.balanced)
                        Text("Quality · heavy fallback allowed").tag(LocalModelProfile.quality)
                    }
                    .pickerStyle(.menu)
                    .help("Models are local-only and never downloaded automatically. Heavy models run only on ambiguous files.")
                    Toggle("Local transcription", isOn: $model.localTranscriptionEnabled)
''')

replace_once(
    CI,
    '''      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.app
''',
    '''      - name: Specialist helper contract
        run: |
          python3 -m py_compile scripts/specialist.py scripts/provision_specialist_models.py
          python3 scripts/specialist.py --syntax-check
          python3 scripts/provision_specialist_models.py --list >/dev/null

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.app
''')

print("specialist router integration applied")
