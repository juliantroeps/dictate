# dictate

A macOS app that transcribes your voice and injects the result directly into any text field — system-wide and on-device.

Hold the **Fn / Globe key**, speak, release. Text appears at the cursor.

Transcription runs entirely on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit). 

## Features

- Hold-to-record wherever you want
- On-device transcription (Whisper tiny/base/small/medium)
- Smart text injection in Browser, Terminal, and other apps
- System audio mute while recording
- Settings UI in the menu bar

## Requirements

| Requirement | Version |
|------------|---------|
| macOS | 14 Sonoma or later |
| Architecture | Apple Silicon only |
| Xcode Command Line Tools | 15+ (Swift 6 toolchain) |
| Swift | 6.0 |

Install tools if needed:

```sh
xcode-select --install
```

## Build & run

### 1. Clone

```sh
git clone <repo-url>
cd dictate
```

### 2. Build

```sh
# Debug (development)
swift build

# Release (optimised)
# WMO is disabled due to a compiler crash in the Tokenizers dependency
swift build -c release -Xswiftc -no-whole-module-optimization
```

WhisperKit and its transitive dependencies are fetched automatically by SPM. First build takes a while.

### 3. Run

**Do not use `swift run`.** It rebuilds the binary before launching, which invalidates the macOS TCC accessibility entry. Always run the compiled binary directly:

```sh
# Debug
.build/debug/dictate

# Release
.build/release/dictate
```

## Permissions

Two permissions are required. The app requests them on first launch.

### Accessibility

Required to listen for the Fn key globally (CGEventTap) and to inject text via the Accessibility API.

**Grant to the process that launches the binary**, not to the binary itself:
- Running from Terminal → grant to **Terminal.app**
- Running from iTerm2 → grant to **iTerm2.app**

Go to **System Settings → Privacy & Security → Accessibility** and enable the entry.

The app polls every 2 seconds and starts the key listener automatically once granted.

### Microphone

Requested automatically on launch. Grant it when prompted, or go to **System Settings → Privacy & Security → Microphone**.

## Settings

Click the **mic icon** in the menu bar to open the settings popover.

| Setting | Default | Description |
|---------|---------|-------------|
| Model | tiny.en (~75 MB) | Whisper model size. Larger = more accurate, slower to load |
| No text field | Copy to clipboard | What to do when no focused text field is found |
| Mute system audio | On | Mutes speaker output while recording |

Model downloads are handled by WhisperKit and cached in `~/Library/Caches/`. Changing the model triggers a live reload.

## Prompt conditioning

WhisperKit supports prefix prompts that bias the decoder toward specific terms and casing. The app ships a default prompt tuned for software engineering dictation.

To override it, create `~/.dictate/prompt.txt`:

```sh
mkdir -p ~/.dictate
echo "Your custom vocabulary hint here." > ~/.dictate/prompt.txt
```

The file is read once at engine load time. Restart the app (or change the model) to pick up edits. The prompt is tokenised and must fit within 224 tokens.

**Default prompt covers:** SSR, SSG, ISR, CI/CD, JWT, gRPC, tRPC, DNS, CDN, ORM, SDK, AWS, Next.js, Node.js, FastAPI, GraphQL, TypeScript, PostgreSQL, Tailwind CSS, Terraform, Kubernetes, React, Svelte, Deno, Bun, Supabase, Vite, Cursor, Claude, OpenAI, and more.

## Distribution (local) — step-by-step

Everything runs on your machine. Build and package the app, tag, push, then upload the DMG to a GitHub Release.

### Scripts reference

| Script | Purpose |
|--------|---------|
| `scripts/build.sh` | Build `Dictate.app` into `dist/` (optionally `VERSION=...` `BUILD_NUMBER=...`). |
| `scripts/sign.sh` | Sign the app in `dist/` (ad-hoc unless `DEVELOPER_ID` is set). |
| `scripts/package.sh` | Build + sign + create DMG (calls `build.sh` and `sign.sh`). |
| `scripts/tag-release.sh` | Read version from built app (run after package.sh), sync Info.plist, commit, tag, push. |

---

### Step 1: Build and package

From the repo root, run **one** of the following.

**Without Developer ID (ad-hoc signing)**
Users will need to right-click the app and click Open the first time. No Apple certificate required.

```sh
# With a specific version (recommended for releases)
VERSION=0.2.0 BUILD_NUMBER=2 scripts/package.sh

# With default version (0.1.0 / 1)
scripts/package.sh
```

**With Developer ID (notarized)**
Requires an Apple Developer account and `notarytool` configured. Gatekeeper will accept the app without "Open Anyway".

```sh
export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE="notarytool-profile"
VERSION=0.2.0 BUILD_NUMBER=2 scripts/package.sh
```

**Result:** `dist/Dictate.app` and `dist/Dictate-<version>.dmg` (e.g. `dist/Dictate-0.2.0.dmg`).

---

### Step 2: Tag and push

Run after Step 1 (script reads the version from the app you just built, then commits, tags, pushes):

```sh
scripts/tag-release.sh
```

Or manually: `git tag v0.2.0` then `git push origin v0.2.0`.

---

### Step 3: Create the GitHub release and upload the DMG

1. On GitHub: **Releases** > **Draft a new release**.
2. Choose the tag you pushed (e.g. `v0.2.0`).
3. Set the release title (e.g. `v0.2.0`) and add release notes.
4. Under assets, upload `dist/Dictate-0.2.0.dmg`.
5. Click **Publish release**.

That's it. Users download the DMG from the release page.

---

### End-to-end summary

| Step | Without Developer ID | With Developer ID |
|------|----------------------|-------------------|
| 1 | `VERSION=0.2.0 scripts/package.sh` | `export DEVELOPER_ID=...` then same |
| 2 | `scripts/tag-release.sh` (after package.sh) | Same |
| 3 | Upload DMG to GitHub release | Same |
