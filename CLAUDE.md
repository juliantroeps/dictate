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
scripts/eval.sh C0 C1          # release build + dictate-eval over eval/clips (see eval/README.md)
```

## Release

```sh
VERSION=x.y.z scripts/package.sh   # build + sign + DMG in dist/ (bundles install.sh)
scripts/tag-release.sh              # commit, tag, push, gh release
```

`scripts/install.sh` is bundled into the DMG for end-user installation. It copies the app to `/Applications`, strips quarantine, and ejects the DMG.

## Architecture

SPM macOS 14+, Swift 6 strict concurrency. Targets: `DictateCore` (library: `Sources/DictateCore/` - `WhisperKitEngine`/`TranscriptionEngine`, `PromptProvider`, `AppLogger`; must not import Sentry or UI), `dictate` (app executable, rest of `Sources/`, excludes the other two dirs), `dictate-eval` (eval executable, `Sources/dictate-eval/`), `dictateTests`. App `Sources/` grouped: `App/` `Features/` `Infrastructure/` `Support/` `UI/`.

**Core flow:** `DictationCoordinator` orchestrates dictation. Fn key press (via `KeyListener` CGEventTap) triggers `AudioCaptureManager` recording. On release, audio goes through `EngineCoordinator` -> `TranscriptionEngine` (WhisperKit), then `TextInjector` places text at cursor. `AppDelegate` is thin wiring (status item, popover, builds coordinators).

Key components (by directory):
- `App/AppDelegate` - wiring: status item, popover, builds `EngineCoordinator` + `DictationCoordinator`
- `Features/Dictation/` - `DictationCoordinator` (key callbacks -> record -> transcribe -> inject) + `DictationRuntimeState`
- `Features/Settings/` - `SettingsView`, `SettingsRefreshController`
- `Infrastructure/Input/` - `KeyListener` (CGEventTap on `flagsChanged` for Fn/Globe `maskSecondaryFn`; a11y on the *terminal*, not the binary), `TextInjector` (+ `TextInjectionHelpers`): 3-strategy cascade AXSelectedText splice -> AXValue splice -> clipboard+Cmd+V, cursor verification catches apps that silently ignore AX writes (terminals, Electron); `PasteReceipt` (lazy pasteboard promise: consumer read = paste landed, restore prior clipboard; no read = keep dictation; "Copied to clipboard" pill on the no-target branch only)
- `Infrastructure/Audio/` - `AudioCaptureManager` (AVAudioEngine tap -> 16kHz mono Float32), `AudioDeviceCoordinator`/`AudioDevicePolicy`/`AudioCaptureEvent` (mid-recording device-change handling), `SystemAudioController` (CoreAudio mute/unmute default output)
- `Infrastructure/Transcription/` - `EngineCoordinator` (also the `DICTATE_SAVE_CAPTURES=1` hook: saves every `transcribe()` input via `Infrastructure/Audio/CaptureRecorder` to `~/.dictate/captures/` as float32 WAV + JSON sidecar; off by default, local only)
- `DictateCore/` - `TranscriptionEngine` protocol + `WhisperKitEngine` (argmax-oss-swift `1.1.x`, `upToNextMinor`; `WhisperKitEngine.decodingOptions` is the single source of the app's decode options, reused by the eval), `PromptProvider` (vocabulary hints from `~/.dictate/prompt.txt`), `AppLogger` (Sentry plugged in via `AppLogger.setReporter` from `SentryConfiguration.start`)
- `dictate-eval/` - offline eval CLI: `NNN.wav` + `NNN.ref.txt` x `eval/configs/*.json` -> `results.csv` + `summary.md` (WER, term recall, empty/halluc rate, latency). `eval/` is gitignored except README, configs, terms.example.txt
- `Infrastructure/Permissions/` - `AccessibilityPermission`, `MicrophonePermission`
- `Support/` - `AppLogger`, `Settings` (`@Observable` singleton backed by UserDefaults)
- `UI/Overlay/` - `OverlayController`/`RecordingOverlayView`/`OverlayState`: floating borderless window (level `.screenSaver`) showing recording/processing/error states

## Transcription / model storage

- Inference is **on-device** (WhisperKit + CoreML); recorded audio never leaves the machine.
- **First run downloads the model** from HuggingFace (`argmaxinc/whisperkit-coreml`) - needs network once. Subsequent runs are fully offline.
- Models cache at `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<model>/`; `WhisperKitEngine.cachedModelFolder()` reuses it only when `MelSpectrogram`, `AudioEncoder` and `TextDecoder` `.mlmodelc` are all present; a failed load from the cache retries once via a fresh download.
- Default model `openai_whisper-small.en`, overridable via `Settings.whisperModel` (changing it calls `EngineCoordinator.reload`).
- Picker: tiny.en, small.en, large-v3-turbo (turbo gets no vocabulary prompt, see `PromptProvider.supportsPrompt`). Retired ids (medium.en, distil-large-v3) stored by older versions map to small.en via `WhisperModels.resolve`.
- Load is lazy on launch: 3 attempts w/ backoff, "loading" overlay after a 1s grace.

## Key gotchas

- **Accessibility permission** must be granted to Terminal.app (or whichever terminal), not to the compiled binary
- **`swift run` invalidates TCC** - always `swift build` then run binary directly
- **argmax-oss-swift 1.1.x** guards `MLMultiArrayDataType.int8` with `#if compiler(>=6.2)`, but `.int8` needs the macOS 26 SDK. A 6.2 compiler on a macOS 15 SDK (e.g. swiftly 6.2.3 + Xcode 16.0) fails to build (`.int8` missing, `mach_task_self_` not concurrency-safe). Use Swift 6.1.x (Xcode 16.3+) or Xcode 26. `Tests/` use trailing commas in calls: need Swift 6.1+
- **`AVAudioApplication.requestRecordPermission()`** crashes on macOS 15 with Swift 6 async/await - use ObjC-style callback (`AVCaptureDevice.requestAccess(for:) { granted in ... }`)
- **`@MainActor` + Timer callbacks** - use `MainActor.assumeIsolated` instead of async bridging
- Overlay window uses `.screenSaver` level + `.fullScreenAuxiliary` collection behavior to appear above full-screen apps
