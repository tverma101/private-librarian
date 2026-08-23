# Upstream reuse audit

Issue #38 is an audit, not permission to import a neighboring application's
write behavior. The selection below keeps Private Librarian's SourceBroker,
SQLCipher catalog, incremental generations, and virtual-only organization as
the source of truth.

| Area | Source | Decision | Boundary |
|---|---|---|---|
| Native image/text embeddings | [sfomuseum/swift-mobileclip](https://github.com/sfomuseum/swift-mobileclip) and [Apple's Core ML MobileCLIP artifacts](https://huggingface.co/apple/coreml-mobileclip) | ADAPT | Genuine S0 model I/O, 256×256 image input, 77-token text input, tokenizer shape, lazy model loading, 512-D normalization, and bounded concurrency are implemented locally. The provider receives bytes/text only and never gets a source path. |
| OpenCLIP / ONNX acceleration | [FileID](https://github.com/WebWorldWide/FileID) | STUDY / DEFER | Warm sessions, dimension guards, preprocessing identity, and ANE-aware concurrency are useful. FileID's ONNX Runtime dependency is not added to this package until a matching image+text export and measured retrieval fixture exist. |
| Semantic restructuring | [FileID restructure design](https://github.com/WebWorldWide/FileID/blob/main/shared/docs/RESTRUCTURE.md) | ADAPT conceptually | Feature fusion, representatives, confidence, and review ideas inform the catalog graph; Finder tags, rename, move, delete, and apply-to-disk flows are excluded. |
| Photo/video retrieval | [Immich search](https://docs.immich.app/features/searching/) and [duplicate utility](https://docs.immich.app/features/duplicates-utility/) | STUDY | Retrieval and background-job patterns are relevant, but the server/Postgres/VectorChord architecture is outside this native local scope. |
| Virtual organization UX | [TagStudio](https://github.com/TagStudioDev/TagStudio) | STUDY | The tag layer over existing files is aligned; its library-root database write is not allowed here. |

## Current decision

`python-transformers` remains the comparison fallback when its local runtime is
actually provisioned. Genuine Core ML MobileCLIP is implemented and has been
validated with a temporary pinned compiled S0 pair: `provider-smoke` produced
real 512-D image/text vectors, warm latency, and a matching-space cosine
receipt. It remains opt-in because that smoke test does not measure Golden
Library Recall@K. FileID's OpenCLIP/ONNX path is rejected as a default for now
because this checkout has no matching text encoder, ONNX Runtime bridge, or
artifact-backed quality measurement.

The tokenizer adaptation is attributed to the BSD-licensed
`sfomuseum/swift-mobileclip` project; its required notice is retained in
`ThirdParty/SWIFT_MOBILECLIP_LICENSE.md`.
