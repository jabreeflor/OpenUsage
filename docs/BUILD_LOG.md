# Build log

Implementer: `agy --model gemini-4-neon-high` (id confirmed with `agy models`). Reviewer: `codex exec -m gpt-6.2-astra`.

| Milestone | Rounds | Verdict | Open issues |
|---|---|---|---|
| 1. Scaffold, core, demo data, menu bar item | 2 | PASS | Astra's sandbox has no display: it verifies via `--snapshot-dir` renders; live menu bar checked by the orchestrator with a real screenshot |
| 2. Dropdown "Gauge tiles" | 3 | PASS | Nit: some text renders slightly heavier than the stills (revisit in polish) |
| 3. Statistics window | 4 | PASS | — |
| 4. Accounts window | 3 | PASS | — |
| 5. Local-log token parsers | 4 | PASS | Orchestrator cross-check after the PASS: when the Claude log folder lives on iCloud Drive and macOS has evicted many of the files, the parser skips them by design, so Claude totals come out well below an independent full count. Carried into milestone 7 |
| 6. Live limit providers | 4 | FAIL (cap reached) | Verified live on this Mac: Claude weekly (all models), ChatGPT/Codex weekly, Cursor included usage. Gemini (no CLI login to test) and OpenCode ship as "Not yet supported". Astra's two remaining defects, both in the Codex reader: (1) a rollout file over 16 MiB is skipped silently, so an older reading is shown; (2) an undated event can outrank a later timestamped one. Stopped at the 4-round cap; the user chose to proceed without fixing them, so they are listed as known issues in the PR |
| 7. Polish + final full pass | 4 | FAIL (cap reached) | Visual polish passes on every screen (side-by-sides vs stills within 2 pt). iCloud-evicted logs are now counted in a background pass and live "Limits hit" is recorded locally. One remaining Astra defect: when a download finishes just after its time limit while a local refresh is enumerating files, that unchanged file can be parsed twice (wasted read, totals stay correct). Stopped at the 4-round cap |
