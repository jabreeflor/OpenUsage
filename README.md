# OpenUsage

A native macOS menu bar app for keeping an eye on your AI subscriptions. See usage limits, reset times, token counts, and model statistics for Claude, ChatGPT/Codex, Cursor, Gemini, and OpenCode in one place.

Built with Swift 6, SwiftUI, and AppKit for macOS 14 or later.

## Features

- **Usage at a glance:** provider tiles with depletion gauges and reset times, plus a compact menu bar indicator.
- **Token statistics:** 7-day and 30-day views, with an overview across providers and per-provider model breakdowns.
- **Account controls:** connection status, reconnect actions, and switches for individual token sources.
- **Configurable thresholds:** green below 50% usage, yellow from 50%, and red from 80% by default.
- **Demo mode:** explore the interface with fixture data without connecting accounts.

## Provider support

Subscription limits and token history come from separate sources. Token totals reflect the supported logs available on your Mac; they are not a complete account-wide billing record.

| Provider | Usage limits | Token history |
| --- | --- | --- |
| Claude | Anthropic usage endpoint, using the existing Claude Code login in macOS Keychain | Claude Code logs in `~/.claude/projects` |
| ChatGPT / Codex | Rate-limit events from local Codex CLI sessions, with sign-in checked through `~/.codex/auth.json` | Codex CLI logs in `~/.codex/sessions` |
| Cursor | Cursor usage endpoint, using the signed-in Cursor app session | No local token-history parser yet |
| Gemini | Gemini CLI OAuth and Google quota endpoints; not yet verified with a live account | Gemini CLI logs in `~/.gemini/tmp` |
| OpenCode | OpenCode Go usage endpoint (5-hour, weekly, and monthly limits), using the local `opencode-go` credential in `~/.local/share/opencode/auth.json` (respecting `XDG_DATA_HOME`); OpenCode Zen-only logins are detected as unsupported | `~/.local/share/opencode/opencode.db` and legacy JSON message files under `storage/message` |

Claude weekly limits, Codex weekly limits, and Cursor included usage were verified during development. See the [build log](docs/BUILD_LOG.md) for verification details and remaining issues. Provider APIs and local file formats can change.

## Homebrew packaging

Homebrew release packaging is available via `./scripts/package-release.sh 0.1.0`
or the **Package release** GitHub Actions workflow. It produces a universal Mac
app ZIP, checksum, and matching cask. Installation through Homebrew requires
publishing the release and cask first; see [Homebrew distribution](docs/HOMEBREW.md).

## Build and run

You need macOS 14+, Xcode with Swift 6 support, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The project was developed with Xcode 26.6.0. Install XcodeGen with Homebrew if needed:

```sh
brew install xcodegen
git clone https://github.com/jabreeflor/OpenUsage.git
cd OpenUsage
```

The supplied scripts explicitly select `/Applications/Xcode-26.6.0.app/Contents/Developer`. If your Xcode is installed there:

```sh
./scripts/build.sh
open build/Products/Debug/OpenUsage.app
```

For another Xcode installation, select its developer directory and run the build directly. For example, for `/Applications/Xcode.app`:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate --quiet
xcodebuild \
  -project OpenUsage.xcodeproj \
  -scheme OpenUsage \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  CONFIGURATION_BUILD_DIR="$PWD/build/Products/Debug" \
  build
open build/Products/Debug/OpenUsage.app
```

OpenUsage runs in the menu bar, without a Dock icon. Click its indicator to open the dropdown, select a provider for its limits, or open **Statistics** and **Accounts**.

For live data, sign in to the corresponding CLI or desktop app first, then use **Sign in** or **Reconnect** in OpenUsage's Accounts window. Existing tool credentials are reused; a browser login alone may not establish the local session OpenUsage needs. Allow macOS Keychain access when prompted for Claude Code credentials. OpenCode token counting is off by default and can be enabled in Accounts.

## Try demo mode

With the script's Xcode installation available, this builds if necessary and launches with fixture data:

```sh
./scripts/run-demo.sh --open dropdown
./scripts/run-demo.sh --open statistics --select claude --range 7d
./scripts/run-demo.sh --open accounts --demo-scenario disconnected
```

You can also launch an already-built binary directly:

```sh
build/Products/Debug/OpenUsage.app/Contents/MacOS/OpenUsage --demo --open accounts
```

Quit the running instance before switching modes. Demo scenarios are `all`, `connecting`, and `disconnected`. `OPENUSAGE_DEMO=1` also enables demo mode. Demo providers use fixtures without reading live credentials, querying provider APIs, or changing live preferences. Use demo mode for screenshots and recordings.

## Privacy and data

OpenUsage reads existing tool credentials and session files without modifying those credentials or logs. Claude credentials come from Keychain; other integrations read the relevant tool's existing credential file or local session database. Live Claude, Cursor, Gemini, and OpenCode Go integrations make authenticated requests to their respective providers.

Token logs are processed locally. Preferences and observed limit-hit history are stored locally, and limit-hit history begins with observations made by OpenUsage. Logs evicted to iCloud may need to download before they appear in totals.

## Development

[`project.yml`](project.yml) is the XcodeGen project definition; the generated `.xcodeproj` is ignored by Git.

| Path | Contents |
| --- | --- |
| `Sources/OpenUsage` | Menu bar app, windows, and presentation |
| `Sources/OpenUsageCore` | Providers, log parsers, aggregation, settings, and fixtures |
| `Tests/OpenUsageCoreTests` | Core unit tests |
| `Tests/Fixtures` | Synthetic provider responses and token logs |
| `design/reference` | UI design reference images |
| `docs` | Specification, implementation plan, and build history |

Run the core tests on Apple Silicon with the configured Xcode installation:

```sh
./scripts/test.sh
```

For a different Xcode installation or architecture, use the `DEVELOPER_DIR` selected above, generate the project, and run:

```sh
xcodebuild \
  -project OpenUsage.xcodeproj \
  -scheme OpenUsageCoreTests \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  test
```

### Known limitations

- Codex rollout files larger than 16 MiB are skipped, which can leave an older limit reading visible. An undated rate-limit event can also outrank a timestamped event.
- An iCloud log download completing near its timeout can cause a duplicate read during refresh. Totals remain correct, but the extra read is unnecessary work.
- Gemini live quota support remains unverified; OpenCode Zen (non-Go) live limits and Cursor token history are not yet supported, as noted above.

See [AGENTS.md](AGENTS.md) for contribution conventions and [docs/SPEC.md](docs/SPEC.md) for the product specification. Keep credentials, real account data, recordings, and GIFs out of Git.
