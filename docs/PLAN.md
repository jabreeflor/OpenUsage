# OpenUsage v1 — build plan

Orchestrator: Claude Fable 5.2. Implementer: Gemini 4 Neon (`agy --model gemini-4-neon-high`). Reviewer: Codex `gpt-6.2-astra`. Loop and evidence rules: `docs/ORCHESTRATION.md`. Each milestone is capped at 4 implement/review rounds.

## Shared decisions

- **Project layout:** XcodeGen `project.yml` → `OpenUsage.xcodeproj` (generated, not committed). App target `OpenUsage` (`Sources/OpenUsage`), logic in a `OpenUsageCore` framework/target (`Sources/OpenUsageCore`) so parsers, aggregators and color logic are unit-testable, tests in `Tests/OpenUsageCoreTests` with fixtures in `Tests/Fixtures`.
- **Build/test commands** (always with `DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer`): `scripts/build.sh` (xcodegen + xcodebuild, output in `build/`), `scripts/test.sh`, `scripts/run-demo.sh [args]`.
- **Demo mode:** `--demo` or `OPENUSAGE_DEMO=1`. Fixture numbers equal the reference stills. Demo never reads real credentials, logs or the network.
  - `--demo-scenario all` (default; stills 01–04, 07), `disconnected` (still 05: Gemini expired, OpenCode not connected), `connecting` (still 06: Gemini connecting, OpenCode off).
  - `--open dropdown|statistics|accounts` opens that screen at launch, so reviewers and recordings can reach every screen without clicking.
  - `--snapshot-dir <dir>` renders every screen (menu bar label, dropdown per scenario/selection, Statistics Overview 30D + Claude 7D, Accounts per scenario) to PNG offscreen and exits. Used by the reviewer where screen capture is unavailable. PR evidence still comes from the real running app.
- **Depletion color:** one pure function `DepletionColor.level(percent:yellow:red)` in Core; thresholds stored in `UserDefaults` (defaults 50 / 80), editable in Accounts.
- **Providers:** `UsageProvider` protocol per provider (limits) and `TokenLogSource` per local log format (tokens). Each has a demo fake.

## Milestones

| # | Milestone | Reference | Acceptance (summary) |
|---|---|---|---|
| 1 | Scaffold, core model, demo data, menu bar item | `01` (top right), `05`, `06` menu bars | Builds from CLI; `LSUIElement`; menu bar shows 5 logos + colored percents in demo; expired shows dimmed `--`, not-connected omitted; depletion-color + threshold tests pass; `--snapshot-dir` works |
| 2 | Dropdown "Gauge tiles" | `01`, `02`, `05` | 380 pt popover, tiles grid, Today tile, selection → detail card, dashed tiles, footer links |
| 3 | Statistics window | `03`, `04` | Sidebar, 7D/30D, rings row, KPI cards, stacked bars, top models, heatmap; demo numbers equal stills |
| 4 | Accounts window | `06`, `07` | Tabs, subscription rows with pills and neutral buttons, demo sign-in/reconnect/sign-out flow, local-tool checkboxes, editable thresholds that recolor everything live |
| 5 | Local-log token parsers + aggregator | — | Parsers for Claude Code, Codex, Gemini CLI, OpenCode with fixture tests; per day/hour/provider/model aggregation with in/out/cache; folder watching + incremental refresh; live (non-demo) Statistics fed by it |
| 6 | Live limit providers | — | One provider at a time, each verified against the real account on this Mac or shipped as a labelled "not yet supported" state; Keychain-only credentials; 60 s / 5 min refresh |
| 7 | Polish + evidence | all | Side-by-sides vs reference stills, fixes from the comparison, final full Astra pass |

## Evidence (after milestone 7)

Screenshots, two recordings and side-by-sides listed in `docs/ORCHESTRATION.md`, all from the real app in demo mode, written to `evidence/` (git-ignored) and attached to the PR with `gh … --attach`.

## Gemini sign-in repair (2026-11-28)

- Replace the unrelated website link with browser OAuth, a loopback callback and PKCE/state validation; keep app-owned credentials in Keychain.
- Reuse existing Gemini CLI credentials read-only, refresh access tokens, and connect production to the Code Assist quota endpoint.
- Test callback validation, cancellation/timeouts, refresh, sign-out and provider wiring; build and review with Astra.
- Verify the actual account flow with the user, preserve demo-only public evidence, and clearly distinguish CLI quotas from Gemini website quotas.
