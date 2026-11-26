# OpenUsage — v1 spec

A personal macOS menu bar app that signs in to Jabree's AI subscriptions, shows how much of each usage limit is left, and keeps statistics on tokens and models. It is built for one person on one Mac and is not a product.

The look is settled. Match the final designs pixel-for-pixel where SwiftUI allows:

- `design/reference/*.png`: stills of the final designs at 2× (1440×900 desktop). **These are the source of truth.**
- `design/final/*.dc.html`: the design canvas source for the three final screens. Open them in a browser to read exact colors, sizes, spacing and copy.
- `design/demo/demo.html?variant=tiles` and `?variant=accounts`: animated walkthroughs of the intended interactions. `08-alt-native-menu.png` shows a rejected alternative, for reference only.
- `design/final/logos-svg/*.svg` and `design/final/provider-logos.js`: the provider logo paths (Simple Icons, 24×24 viewBox).

## Providers (exactly five)

| Provider | Plan shown | Limits to show |
|---|---|---|
| Claude | e.g. Max 5x | 5-hour session · Weekly (all models) · Weekly (Opus) |
| ChatGPT (Codex) | e.g. Plus | 5-hour · Weekly |
| Cursor | e.g. Pro | Included usage ($ used of $ included, resets on billing date) |
| Gemini | e.g. Google AI Pro | Daily requests |
| OpenCode | e.g. Zen | Credit / subscription usage |

## Screens

### 1. Menu bar item (`01-menubar-dropdown.png`, top right)
- One item: for each connected provider, its logo (white, 11 pt) followed by its **fullest** limit in percent, in JetBrains Mono (or SF Mono) bold 11 pt.
- Each percentage is colored by depletion: **green `#4ADE80` below the yellow threshold, yellow `#FACC15` from the yellow threshold (default 50%), red `#F87171` from the red threshold (default 80%)**. Both thresholds are user-editable in Accounts.
- A provider whose login expired shows its logo dimmed with `--`. A provider that is not connected is omitted.
- Clicking it opens the dropdown. The item gets the standard highlighted background while open.

### 2. Dropdown: "Gauge tiles" (`01`, `02`, `05`)
- A 380 pt wide dark popover (`#17191E`, 1 px `#30343C` border, 14 pt radius), anchored under the menu bar item (MenuBarExtra with `.window` style).
- Header: "Usage" + "updated N min ago".
- A 3-column grid: one tile per provider (ring gauge 64 pt with the logo inside, percent colored by depletion, provider name, name of the fullest limit), plus a sixth "Today" tile (tokens today, hourly sparkline, request count).
- Disconnected or expired providers get a dashed tile ("Not connected" / "Sign-in expired" in yellow).
- Clicking a tile selects it (lighter background + border) and fills the detail card below: every limit with a colored bar, its percent and its reset text, then "Models today · N tokens" as a stacked bar with legend.
- Footer links: Statistics, Accounts, Quit.

### 3. Statistics window (`03`, `04`)
- A dark window (1000×~750). Title "Statistics", with a 7D / 30D segmented control top right.
- Sidebar: Overview + each provider. Each row has a small ring (fullest limit, depletion color), the logo, the name, and the token total for the range.
- Main area:
  - Ring gauges row: Overview shows each provider's fullest limit, and a provider shows each of its limits.
  - KPI cards: Total tokens · In / out / cache split · Requests · Limits hit (red).
  - "Tokens per day" stacked bar chart by provider. Series colors: Claude `#E8957A`, ChatGPT `#F4F4F5`, Cursor `#71717A`, Gemini `#8AB4F8`, OpenCode `#A78BFA`.
  - "Most used models": top 5 with provider logo, token count and share.
  - "When you use AI": a 7×24 day-by-hour heatmap.

### 4. Accounts window (`06`, `07`)
- A dark settings window with General / Accounts / Alerts tabs. Only Accounts needs real content in v1.
- Subscriptions list, one row each with:
  - A ring with the logo when connected (grey when not), the name and plan, and how it is connected.
  - The fullest-limit percent, and a status pill: Connected (green) / Needs sign-in (yellow) / Off (grey) / Connecting (grey).
  - One button: **Sign in** / **Reconnect** are light neutral (`#F4F4F5` fill, `#17191E` text). **Sign out** is a quiet outline (`#3F434C` border). **Waiting** shows a small spinner. **No blue buttons and no trailing "…" on button labels.**
- "Count tokens from local tools": one checkbox per local source (paths below).
- Colors row: Yellow from [50]% · Red from [80]%. A note says credentials stay in the Keychain.

## Data

Two separate kinds of data. Keep them behind a `UsageProvider` protocol per provider so each can be built, faked and tested on its own.

1. **Limits (live, per subscription).** Use the login the user's tools already have on this Mac before asking them to sign in again. Candidate sources are below. **Every one of them is unverified.** Verify each against the real account on this Mac before relying on it. If one can't be made to work, ship that provider with a clearly labelled "not yet supported" state and say so in the PR. Never fake live numbers.
   - Claude: the Claude Code OAuth credentials in the Keychain, then the account's usage/limits endpoint used by claude.ai's usage page.
   - ChatGPT/Codex: `~/.codex/auth.json`, and/or the `rate_limits` data in recent `~/.codex/sessions/**/rollout-*.jsonl` events.
   - Cursor: the Cursor app's signed-in session (its local state DB under `~/Library/Application Support/Cursor`) and cursor.com's usage endpoint.
   - Gemini: the Gemini CLI / Google OAuth login and its quota endpoint.
   - OpenCode: `~/.local/share/opencode/auth.json` and OpenCode's account/usage endpoint.
   - Sign-in (when nothing local is found) opens the provider's normal web login in the browser. Store any credential OpenUsage owns in the Keychain only.
2. **Tokens and models (local logs, historical).** Parse:
   - `~/.claude/projects/**/*.jsonl` (message `usage` + `model`)
   - `~/.codex/sessions/**`
   - Gemini CLI logs under `~/.gemini/tmp`
   - OpenCode's `~/.local/share/opencode` storage/db
   - Cursor usage from its account

   Aggregate per day, hour, provider and model, with input / output / cache split. Watch the folders and refresh incrementally.

- Refresh limits every 60 s while the dropdown is open, and every 5 min otherwise.
- **Demo mode:** launching with `--demo` (or `OPENUSAGE_DEMO=1`) uses fixture data equal to the numbers in the reference stills. Use it for UI tests and for all PR evidence, so no real account data is ever published.

## Build

- Swift 6 + SwiftUI, macOS 14+, `MenuBarExtra` with `.window` style, and `LSUIElement` (no Dock icon). Use XcodeGen (`project.yml`, installed via Homebrew) or a Swift package with a bundle script, whichever builds reliably from the CLI.
- Xcode 26.6 is installed but not selected. Use `DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer` instead of `xcode-select` (which needs sudo).
- Bundle JetBrains Mono, or fall back to SF Mono.
- Tests: unit tests for every log parser and aggregator, using fixture files checked into `Tests/Fixtures`. Also test the depletion-color function and the threshold settings.
