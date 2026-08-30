# Developer final-boss workload

Private Librarian should remain useful on developer machines containing very large source trees and active build outputs. Chromium-, Firefox-, WebKit-, Android-, Rust-, Node-, Bazel-, CMake-, Xcode-, and similar workloads are treated as first-class stress cases.

## Product rule

Understand authored source and project structure. Do not spend inference, catalog space, or UI attention on generated build output.

Examples of noise that should be filtered before expensive indexing include dependency caches, compiler output, object directories, package-manager caches, coverage output, source maps/build caches, and temporary browser downloads. The exact source tree remains read-only.

## Required scale behavior

- Discovery memory must be bounded by a batch/window, not by total file count.
- Missing-file reconciliation must not require a second in-memory copy of every path.
- Permission-denied subtrees are skipped for that pass and must not cause retry loops or false deletion/missing state.
- Symlink loops remain impossible because source traversal never follows arbitrary symlinks.
- Live build storms must have a bounded pending-event footprint and must collapse overflow into a safe reconciliation path after activity settles.
- Generated/build directories must be rejected before descending into them.
- Unchanged source files must return to zero expensive inference after the initial pass.
- Text/model work is per-file or per-project bounded. The entire repository is never concatenated into an LLM/model context.
- Semantic search must keep only top-K results in memory; it must not materialize every vector in a huge catalog into Swift objects.

## Browser compilation fixture

A release-scale fixture should resemble a browser checkout with source plus generated trees such as:

- `out/Default/obj/...`
- `obj-*`
- `DerivedData/`
- `WebKitBuild/`
- `target/`
- `node_modules/`
- `bazel-out/`, `bazel-bin/`, `bazel-testlogs/`, `bazel-*`
- `cmake-build-*`
- `.gradle/`, `.next/`, `.turbo/`, `.parcel-cache/`

The fixture should prove that authored source remains indexable while the generated trees contribute zero expensive inference and do not flood Smart Groups or Review Inbox.

## Release evidence

Before calling huge developer trees production-ready, record:

- files discovered and files excluded by reason;
- peak RSS during discovery/indexing;
- cold index throughput;
- unchanged warm-rescan work counts;
- DB size and embedding/chunk counts;
- live-event peak pending count during a synthetic compiler storm;
- number of full reconciliations requested/executed;
- search p50/p95 and peak RSS on a large semantic catalog.
