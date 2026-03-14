# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is this

**dictate** - macOS menu bar app for hold-to-dictate voice transcription. Hold Fn/Globe key, speak, release - text is injected at cursor. On-device transcription via WhisperKit.

## Build & Run

```sh
swift build                    # build (first build fetches WhisperKit deps, slow)
.build/debug/dictate           # run (do NOT use `swift run` - it rebuilds and invalidates TCC)
```

No tests exist. No linter configured.

## Release

```sh
VERSION=x.y.z scripts/package.sh   # build + sign + DMG in dist/
scripts/tag-release.sh              # commit, tag, push, gh release
```

## Architecture

Single-target SPM executable (`Sources/`), macOS 14+, Swift 6 strict concurrency. No test target.

**Core flow:** `AppDelegate` orchestrates everything. Fn key press (via `KeyListener` CGEventTap) triggers `AudioCaptureManager` recording. On release, audio goes to `TranscriptionEngine` (WhisperKit), then `TextInjector` places text at cursor.

Key components:
- `AppDelegate` - central coordinator: status item, popover, key callbacks, engine lifecycle, audio mute
- `KeyListener` - CGEventTap on `flagsChanged` for Fn/Globe (`maskSecondaryFn`). Requires Accessibility permission on the *terminal*, not the binary
- `AudioCaptureManager` - AVAudioEngine tap, converts to 16kHz mono Float32
- `TranscriptionEngine` - protocol; `WhisperKitEngine` impl. WhisperKit pinned to `0.9.0..<0.16.0` (0.16.0 broken on macOS 15 SDK)
- `TextInjector` - 3-strategy cascade: AXSelectedText splice -> AXValue splice -> clipboard+Cmd+V fallback. Cursor verification detects apps that silently ignore AX writes (terminals, Electron)
- `OverlayController` / `RecordingOverlayView` / `OverlayState` - floating borderless window (level `.screenSaver`) showing recording/processing/error states
- `SystemAudioController` - CoreAudio mute/unmute default output
- `Settings` - `@Observable` singleton backed by UserDefaults
- `PromptProvider` - reads vocabulary hints from `~/.dictate/prompt.txt`

## Key gotchas

- **Accessibility permission** must be granted to Terminal.app (or whichever terminal), not to the compiled binary
- **`swift run` invalidates TCC** - always `swift build` then run binary directly
- **WhisperKit 0.16.0** uses `MLMultiArrayDataType.int8` requiring macOS 26 SDK - hence the upper bound pin
- **`AVAudioApplication.requestRecordPermission()`** crashes on macOS 15 with Swift 6 async/await - use ObjC-style callback (`AVCaptureDevice.requestAccess(for:) { granted in ... }`)
- **`@MainActor` + Timer callbacks** - use `MainActor.assumeIsolated` instead of async bridging
- Overlay window uses `.screenSaver` level + `.fullScreenAuxiliary` collection behavior to appear above full-screen apps
