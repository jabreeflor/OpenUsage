# Build log

Implementer: `agy --model gemini-4-neon-high` (id confirmed with `agy models`). Reviewer: `codex exec -m gpt-6.2-astra`.

| Milestone | Rounds | Verdict | Open issues |
|---|---|---|---|
| 1. Scaffold, core, demo data, menu bar item | 2 | PASS | Astra's sandbox has no display: it verifies via `--snapshot-dir` renders; live menu bar checked by the orchestrator with a real screenshot |
| 2. Dropdown "Gauge tiles" | 3 | PASS | Nit: some text renders slightly heavier than the stills (revisit in polish) |
| 3. Statistics window | 4 | PASS | — |
| 4. Accounts window | 3 | PASS | — |
| 5. Local-log token parsers | 4 | PASS | Orchestrator cross-check after the PASS: when the Claude log folder lives on iCloud Drive and macOS has evicted many of the files, the parser skips them by design, so Claude totals come out well below an independent full count. Carried into milestone 7 |
