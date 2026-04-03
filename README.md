# dictate

A macOS menu bar app that transcribes your voice and injects the result directly into any text field - system-wide and on-device.

Hold **Fn / Globe**, speak, release. Text appears at the cursor.

Transcription runs entirely on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit).

## Features

- Hold-to-record from anywhere
- On-device transcription (Whisper tiny/base/small/medium)
- Smart text injection - works in browsers, terminals, Electron apps, and native apps
- System audio mute while recording
- Customizable vocabulary hints for domain-specific terminology
- Menu bar settings UI

## Installation

### From DMG (recommended)

Download the latest DMG from [Releases](../../releases), open it, and run:

```sh
bash /Volumes/Dictate/install.sh
```

This copies `Dictate.app` to `/Applications` and removes the quarantine flag.

### From source

```sh
git clone https://github.com/juliantroeps/dictate.git
cd dictate
scripts/build.sh
cp -R dist/Dictate.app /Applications/
```

No quarantine stripping needed when building locally.

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon
- Swift 6.0 / Xcode 16+ (development only)

## Development

### Setup

```sh
xcode-select --install
```

### Build

```sh
swift build
```

SPM fetches WhisperKit and dependencies automatically. First build takes a while.

### Validate

```sh
./scripts/check.sh
```

The script runs `swift build`, `swift test`, `swiftlint lint --strict`, and `swift-format lint --configuration .swiftformat -r Sources Tests` when the tools are installed.

### Code Quality Guardrails

- Keep persisted preferences in `Settings`. Session-only state lives in `DictationRuntimeState` and is owned by the coordinator layer.
- Use `AppLogger` for diagnostics instead of `print` so log categories and privacy choices stay explicit.
- Prefer narrow helpers over broad utility types when extracting shared behavior, especially in audio capture and text injection.
- Run `swift build` and `swift test` for the fast loop, then `./scripts/check.sh` before merging when the lint tools are available.

### Run

```sh
.build/debug/dictate
```

### Permissions

Two permissions are required on first launch:

**Accessibility** - for the global Fn key listener (CGEventTap) and text injection via the Accessibility API.
Grant to the *terminal* launching the binary (Terminal.app, iTerm2, etc.), not to the binary itself.
Go to **System Settings → Privacy & Security → Accessibility** and enable the entry.

**Microphone** - requested automatically on launch.

## Settings

Click the mic icon in the menu bar to open settings.


| Setting           | Default           | Description                                                 |
| ----------------- | ----------------- | ----------------------------------------------------------- |
| Model             | tiny.en (~75 MB)  | Whisper model size. Larger = more accurate, slower to load and takes up more RAM. |
| No text field     | Copy to clipboard | Fallback when no focused text field is found.               |
| Mute system audio | On                | Mutes speaker output while recording.                       |


Model files are downloaded by WhisperKit and cached in `~/Library/Caches/`.

### Source layout

`Sources/` stays rooted at the package target so the refactor can move code into nested directories without changing the manifest. The planned split is:

- `Sources/App`
- `Sources/Features`
- `Sources/Infrastructure`
- `Sources/UI`
- `Sources/Support`

`Tests/` now holds the unit-test target that exercises shared policy and utility code.

## Vocabulary hints

WhisperKit supports prefix prompts to bias the decoder toward specific terms and casing. A default prompt tuned for software engineering is included.

To override it, create `~/.dictate/prompt.txt`:

```sh
mkdir -p ~/.dictate
echo "Your custom vocabulary here." > ~/.dictate/prompt.txt
```

The file is read once at engine load time. Restart the app or change the model to pick up edits. Max 224 tokens.

## Release


| Script                    | Purpose                                               |
| ------------------------- | ----------------------------------------------------- |
| `scripts/build.sh`        | Build `Dictate.app` into `dist/`                      |
| `scripts/sign.sh`         | Sign the app (ad-hoc unless `DEVELOPER_ID` is set)    |
| `scripts/package.sh`      | build + sign + create DMG (bundles `install.sh`)      |
| `scripts/install.sh`      | Install app to `/Applications`, strip quarantine      |
| `scripts/tag-release.sh`  | commit version bump, tag, push, create GitHub release |


Build, sign, and package into a DMG, then tag and publish:

```sh
VERSION=0.2.0 scripts/package.sh
scripts/tag-release.sh
```

`tag-release.sh` commits the version bump, creates a git tag, pushes, and - if `gh` is installed and authenticated - creates a GitHub release and uploads the dmg file.
