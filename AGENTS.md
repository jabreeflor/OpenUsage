# OpenUsage

A personal macOS menu bar app that shows usage limits, token counts and model statistics for Jabree's AI subscriptions: Claude, ChatGPT/Codex, Cursor, Gemini and OpenCode.

- What to build: `docs/SPEC.md`. The source of truth for the look is `design/reference/*.png`.
- How the build is run (orchestrator / implementer / reviewer): `docs/ORCHESTRATION.md`.
- Design sources: `design/final/` (canvas files) and `design/demo/` (animated walkthroughs and the scripts that record them: `node record.mjs <tiles|menu|accounts>`, needs `npm i` in that folder).

## Conventions

- Swift 6 / SwiftUI, macOS 14+. Build with `DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer` on the Mac mini.
- Usage percentages are always colored by depletion: green below the yellow threshold (default 50%), yellow from it, and red from the red threshold (default 80%).
- No blue buttons in Accounts, and no trailing "…" on button labels.
- Credentials live only in the Keychain. Never commit tokens, `.env*`, recordings, GIFs or real account data. The GitHub repo is public.
- `--demo` / `OPENUSAGE_DEMO=1` uses fixture data. All screenshots and videos for PRs use demo mode.
- PRs: ready for review, with a recording attached to the PR, never merged by an agent.
