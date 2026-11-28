# Homebrew distribution

OpenUsage is a macOS application, so Homebrew installs it with a cask.
The packaging script builds both Apple Silicon and Intel architectures, checks
the app signature, and generates a cask with the archive's exact SHA-256 hash.
It does not publish anything or change your installed app.

## Prepare a release

On a Mac with Xcode (Swift 6) and XcodeGen installed:

```sh
./scripts/package-release.sh 0.1.0
```

The script respects `DEVELOPER_DIR`. If it is unset, it uses the project's
Xcode 26.6.0 installation when available, otherwise the system-selected Xcode.
Alternatively, run **Package release** in GitHub Actions with the version number
and download the `OpenUsage-release` artifact. The workflow packages the selected
branch or commit; it does not create a tag or publish a release.
The hosted workflow explicitly selects Xcode 26.6 on the macOS 26 runner,
matching the locally verified toolchain. Xcode 16.4 and 26.3 reject the current
Keychain cancellation code during Swift concurrency checking. The app still
targets macOS 14 and later.

The local output directory is `build/release/0.1.0/`:

- `OpenUsage-0.1.0-universal.zip`: the application to upload to GitHub Releases.
- `SHA256SUMS`: the archive checksum.
- `openusage.rb`: the matching Homebrew cask.

Launch the locally packaged app in demo mode before publishing:

```sh
build/release/0.1.0/OpenUsage.app/Contents/MacOS/OpenUsage --demo --open accounts
```

For the Actions artifact, unzip the downloaded artifact first, then extract
the app ZIP inside it and launch that copy:

```sh
ditto -x -k OpenUsage-0.1.0-universal.zip preview
preview/OpenUsage.app/Contents/MacOS/OpenUsage --demo --open accounts
```

These builds are **ad-hoc signed, not Apple-notarized**. They are suitable for
personal distribution with manual macOS approval. A Homebrew installation does
not remove Gatekeeper checks. For public distribution without that approval,
add Developer ID Application signing and notarization, staple the ticket to the
app, then archive it and generate the checksum from the final archive. An Apple
Development certificate is not a Developer ID Application certificate.

## Publish and install

1. Publish a GitHub Release in `jabreeflor/OpenUsage` tagged `v0.1.0`, pointing
   at the commit used to build the app. Upload the ZIP and `SHA256SUMS`.
2. Create a GitHub repository named `jabreeflor/homebrew-tap` if it does not
   already exist. Copy the generated `openusage.rb` into `Casks/openusage.rb`
   in that repository and commit it. Do not edit the ZIP after generating
   the cask: its checksum must match the published download.
3. Once the release and tap are published, install with:

   ```sh
   brew install --cask jabreeflor/tap/openusage
   open -a OpenUsage
   ```

If macOS blocks the personal build, review the warning and use the approval
in **System Settings > Privacy & Security** if you trust the release.

Validate the published cask with:

```sh
brew audit --cask jabreeflor/tap/openusage
brew fetch --cask jabreeflor/tap/openusage
```

For updates, repeat packaging and publishing with a new version, then replace
the cask in the tap. Users update with:

```sh
brew update
brew upgrade --cask jabreeflor/tap/openusage
```

Uninstall with `brew uninstall --cask jabreeflor/tap/openusage`. The cask does
not delete preferences or any provider's credentials or session logs.
