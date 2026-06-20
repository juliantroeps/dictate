# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is this

**dictate** - macOS menu bar app for hold-to-dictate voice transcription. Hold Fn/Globe key, speak, release - text is injected at cursor. On-device transcription via WhisperKit.

## Build & Run

```sh
swift build                    # build (first build fetches WhisperKit deps, slow)
.build/debug/dictate           # run (do NOT use `swift run` - it rebuilds and invalidates TCC)
swift test                     # run unit tests (Tests/)
scripts/check.sh               # build + test + swiftlint --strict + swift-format lint
```

## Release

```sh
VERSION=x.y.z scripts/package.sh   # build + sign + DMG in dist/ (bundles install.sh)
scripts/tag-release.sh              # commit, tag, push, gh release
```

`scripts/install.sh` is bundled into the DMG for end-user installation. It copies the app to `/Applications`, strips quarantine, and ejects the DMG.

## Architecture

SPM executable + test target, macOS 14+, Swift 6 strict concurrency. `Sources/` grouped: `App/` `Features/` `Infrastructure/` `Support/` `UI/`.

**Core flow:** `DictationCoordinator` orchestrates dictation. Fn key press (via `KeyListener` CGEventTap) triggers `AudioCaptureManager` recording. On release, audio goes through `EngineCoordinator` -> `TranscriptionEngine` (WhisperKit), then `TextInjector` places text at cursor. `AppDelegate` is thin wiring (status item, popover, builds coordinators).

Key components (by directory):
- `App/AppDelegate` - wiring: status item, popover, builds `EngineCoordinator` + `DictationCoordinator`
- `Features/Dictation/` - `DictationCoordinator` (key callbacks -> record -> transcribe -> inject) + `DictationRuntimeState`
- `Features/Settings/` - `SettingsView`, `SettingsRefreshController`
- `Infrastructure/Input/` - `KeyListener` (CGEventTap on `flagsChanged` for Fn/Globe `maskSecondaryFn`; a11y on the *terminal*, not the binary), `TextInjector` (+ `TextInjectionHelpers`): 3-strategy cascade AXSelectedText splice -> AXValue splice -> clipboard+Cmd+V, cursor verification catches apps that silently ignore AX writes (terminals, Electron)
- `Infrastructure/Audio/` - `AudioCaptureManager` (AVAudioEngine tap -> 16kHz mono Float32), `AudioDeviceCoordinator`/`AudioDevicePolicy`/`AudioCaptureEvent` (mid-recording device-change handling), `SystemAudioController` (CoreAudio mute/unmute default output)
- `Infrastructure/Transcription/` - `EngineCoordinator`, `TranscriptionEngine` protocol + `WhisperKitEngine` (pinned `0.9.0..<0.16.0`; 0.16.0 broken on macOS 15 SDK), `PromptProvider` (vocabulary hints from `~/.dictate/prompt.txt`)
- `Infrastructure/Permissions/` - `AccessibilityPermission`, `MicrophonePermission`
- `Support/` - `AppLogger`, `Settings` (`@Observable` singleton backed by UserDefaults)
- `UI/Overlay/` - `OverlayController`/`RecordingOverlayView`/`OverlayState`: floating borderless window (level `.screenSaver`) showing recording/processing/error states

## Transcription / model storage

- Inference is **on-device** (WhisperKit + CoreML); recorded audio never leaves the machine.
- **First run downloads the model** from HuggingFace (`argmaxinc/whisperkit-coreml`) - needs network once. Subsequent runs are fully offline.
- Models cache at `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<model>/`; `WhisperKitEngine.cachedModelFolder()` reuses it when an `.mlmodelc` is present.
- Default model `openai_whisper-tiny.en`, overridable via `Settings.whisperModel` (changing it calls `EngineCoordinator.reload`).
- Load is lazy on launch: 3 attempts w/ backoff, "loading" overlay after a 1s grace.

## Key gotchas

- **Accessibility permission** must be granted to Terminal.app (or whichever terminal), not to the compiled binary
- **`swift run` invalidates TCC** - always `swift build` then run binary directly
- **WhisperKit 0.16.0** uses `MLMultiArrayDataType.int8` requiring macOS 26 SDK - hence the upper bound pin
- **`AVAudioApplication.requestRecordPermission()`** crashes on macOS 15 with Swift 6 async/await - use ObjC-style callback (`AVCaptureDevice.requestAccess(for:) { granted in ... }`)
- **`@MainActor` + Timer callbacks** - use `MainActor.assumeIsolated` instead of async bridging
- Overlay window uses `.screenSaver` level + `.fullScreenAuxiliary` collection behavior to appear above full-screen apps
