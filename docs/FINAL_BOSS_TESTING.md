# Final-boss messy-library testing

Private Librarian is not judged against a tidy demo folder. The release target is a real Downloads/Desktop-style mess: installers, archives, screenshots, recordings, PDFs, code, school material, duplicates, generated filenames, malformed labels, and transient browser files mixed together.

## Product invariants

- Originals remain untouched. Organization is virtual.
- Smart Groups stay small (default maximum: 18).
- A repeated arbitrary/model-generated label does not become a polished group just because it appears twice.
- Raw Vision labels remain evidence unless they map to the curated taxonomy.
- Course groups must have canonical course-code shape.
- Screenshot groups must use a known screenshot subtype.
- Duplicate families, semantic clusters, screenshot subtypes, courses, and project groups have independent display caps.
- Installers/apps/disk images/archives collapse into one human-facing `Installers & archives` group.
- Audio/video collapses into one `Recordings & media` group.
- Stable document groups remain visible ahead of generic semantic clusters in a crowded library.
- Weird parent-folder names, Unicode, emoji, repeated slashes, traversal-looking labels, control characters, and very long labels must not create virtual folders.
- Programming words such as `canvas`, `assignment`, `screenshot`, `material`, or `matrix` must not accidentally produce school/screenshot categories without the right context.
- Browser partial downloads and filesystem metadata are transient noise; they should be ignored until a stable completed file exists.

## Synthetic stress receipts

`SmartOrganizationStressTests` covers thousands of noisy category signals, malformed taxonomy, Unicode/control strings, weird source paths, category monopolization, and keyword collisions.

`DownloadsFinalBossTests` models a chaotic Downloads folder with:

- dozens of disk images/apps/packages/archives;
- recordings and video;
- PDFs and code;
- multiple courses and screenshot types;
- repeated malformed category rows;
- thousands of one-off generated labels;
- repeated installer duplicate families;
- semantic school clusters.

The expected output is a bounded, diverse set of useful virtual groups rather than a generated directory tree.

## Real-library acceptance

Before calling the product polished, run it read-only against a genuinely messy library and record:

1. number of cataloged files;
2. number of promoted Smart Groups;
3. number of singleton/junk groups (target: zero);
4. useful-group rate from a manual sample;
5. files incorrectly placed into School/Projects/Screenshots;
6. duplicate-family false positives;
7. Review Inbox rate;
8. unorganized files that should obviously have been grouped;
9. memory/CPU during initial indexing and an unchanged second pass;
10. source immutability snapshot before/after.

Synthetic tests are a guardrail, not a substitute for this final messy-library smoke.
