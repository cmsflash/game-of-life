# Second execution change, 2026-11-10

Each generated successor board now shares its unchanged cells with the common evolved board. Up to nine changed cells are saved as exact patches. Population is derived by applying each change to the parent counts; cell-by-cell consumers materialize the full board on demand. Search order, work, budgets and tie-breaking are unchanged. This is an offline build only.

Apply `incremental.patch` **after** the first immutable-board cache patch. The AOT executable SHA-256 is `94a37a5b5eca3391ddb4b331351a87cf3a51a166d225af62cf0c06c6f570eb0b`. All 47 canonical engine tests passed, including canonical successor differential tests. On the same 120 checks the chosen move and all non-time diagnostics matched both previous executables. The counterbalanced test measured a further 2.36× speedup on the tested subset. `boundaries.json` identifies each game's saved position immediately before this switch. Keep wall-clock timing separate from logical search effort.
