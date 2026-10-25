# dictate-eval

Offline transcription eval. Runs the app's exact `WhisperKitEngine` (same `DecodingOptions`, same prompt
handling) over a corpus of recorded clips, once per config, and compares the results. Use it to judge model,
prompt and decoding changes with numbers instead of feel.

Everything here except this README, `configs/` and `terms.example.txt` is gitignored: clips, references,
`terms.txt` and `out/` hold personal audio and text.

## Layout

```
eval/
  clips/NNN.wav        16 kHz mono preferred (anything AVFoundation reads is resampled)
  clips/NNN.ref.txt    hand-corrected reference text for NNN.wav
  terms.txt            optional jargon list (see terms.example.txt), case-sensitive, one per line
  configs/*.json       what to compare (committed samples C0..C7)
  out/<timestamp>/     results.csv + summary.md per run
```

## 1. Record a corpus

Real dictations beat synthetic ones. Run the app with captures on (off by default, nothing leaves the machine):

```sh
DICTATE_SAVE_CAPTURES=1 .build/debug/dictate
```

For a release build use the binary inside the bundle, with the menu bar instance quit
(`DICTATE_SAVE_CAPTURES=1 dist/Dictate.app/Contents/MacOS/dictate`). Like any run from Terminal, this needs the
Accessibility grant on the terminal, and only builds that contain this feature honor the flag.

Every dictation (also empty results and errors; not a wedged engine that never returns) is saved to `~/.dictate/captures/` as `<stamp>.wav` (exact
`[Float]` handed to `transcribe()`, 32-bit float) plus `<stamp>.json` (input device, Bluetooth flag, model,
the app's hypothesis, error). Dictate normally for a while, then pick 25-30 clips. Aim for: at least 3 clips
under 1.5 s, 3-10 s, 15-30 s, jargon-heavy, quiet/noisy, and a few on Bluetooth.

Copy a pick into the corpus and seed the reference with the app's hypothesis, then fix it by hand:

```sh
mkdir -p eval/clips
cp ~/.dictate/captures/20261025-101112-123.wav eval/clips/001.wav
jq -r '.hypothesis // ""' ~/.dictate/captures/20261025-101112-123.json > eval/clips/001.ref.txt
```

Write the reference as what you actually said, with the casing and spelling you want ("Next.js", "pnpm").
Synthetic smoke clips work too: `say -o eval/clips/001.wav --data-format=LEI16@16000 "Yes, thanks."`.

Delete captures you do not need: `rm ~/.dictate/captures/*`.

## 2. Run configs

```sh
scripts/eval.sh C0 C1            # build release + run the named configs from eval/configs
scripts/eval.sh --runs 3 C0 C5b  # 3 timed decodes per clip, median latency
scripts/eval.sh --help
```

`scripts/eval.sh` runs `swift build -c release --product dictate-eval -Xswiftc -no-whole-module-optimization`
(the same workaround as `scripts/build.sh`; swiftly 6.2.3 trips over whole-module optimization with
WhisperKit) and then the binary. Latency is only meaningful from the release build. A debug build works for
functional checks: `swift build && .build/debug/dictate-eval C0`.

Running with no config names runs every `*.json` in `eval/configs`, which downloads every model (medium.en is
~1.5 GB). Name the configs you want. The first config is the baseline for paired deltas. Models are cached in
`~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/` like the app's; first load of a model can take
10-20 s (CoreML compile).

### Config format

```json
{
  "name": "C5b",
  "model": "openai_whisper-large-v3-v20240930_547MB",
  "prompt": false,
  "options": { "temperatureFallbackCount": 1, "firstTokenLogProbThreshold": null }
}
```

- `model`: WhisperKit model id.
- `prompt`: `true` (default) uses the app's default vocabulary prompt, `false` disables it. `promptText` or
  `promptFile` replace the text. `~/.dictate/prompt.txt` is never read implicitly; set
  `"promptFile": "~/.dictate/prompt.txt"` to mimic your install.
- `options`: overrides on top of the app's options, by WhisperKit `DecodingOptions` property name. `null`
  clears an optional. Unknown keys fail fast.

### Configs from the improvement assessment

| Config | What | Notes |
|---|---|---|
| C0 | small.en + prompt, app options | Current behavior, includes `windowClipTime = 0` since #37 |
| C1 | small.en, no prompt | Prompt costs ~0.5 s per dictation; shows what it buys |
| C2 | C0 with `windowClipTime = 1.0` | The "stopgap" shipped in C0; this re-creates the old bug (clips <= 1 s come back empty) as a regression check |
| C3 | C0 after the WhisperKit 1.1.x upgrade | No file: rerun C0 once the package is upgraded |
| C4a / C4b | `temperatureFallbackCount` 3 / 5 | C0 is 1; 5 is WhisperKit's default |
| C5a / C5b | large-v3 turbo 547 MB, prompt on / off | WhisperKit 0.15 returns empty with prompt (EOT bug); C5a should show 100% empty |
| C5c | large-v3 626 MB, prompt off | Non-turbo large-v3 variant |
| C5d | large-v3 turbo 632 MB, prompt off | Basis for the picker entry: 4.8% nWER, 11/12 terms, p50 0.44 s on 24 real clips |
| C5e | large-v3 turbo 632 MB, prompt on | Empty on WhisperKit 0.15 (EOT bug); on 1.1.1: 3.4% nWER but p50 0.88 s |
| C6 | distil-large-v3 + prompt | Not benched yet; may hit the same empty bug |
| C6b | distil-large-v3, prompt off | |
| C7 | medium.en + prompt | |

Not covered here: Parakeet (C8) needs an engine behind `TranscriptionEngine` first.
Note `large-v3_turbo_954MB` in old caches is full large-v3, not turbo.

## 3. Read the results

`out/<timestamp>/summary.md` has one row per config; `results.csv` has one row per config and clip
(references, hypotheses, per-clip errors, temperatures) for digging in.

| Metric | Meaning |
|---|---|
| nWER | WER after Whisper-style normalization (lowercase, no punctuation, contractions expanded, fillers and bracketed text dropped, number words to digits). Corpus-level: total errors / total reference words |
| nWER excl. empty | Same, ignoring clips where the model returned nothing |
| cased WER | Whitespace tokens, outer punctuation trimmed, case kept: catches "next.js" vs "Next.js" |
| term recall | Terms from `terms.txt` that appear in the reference and are reproduced exactly (case-sensitive, word-boundary) |
| empty | Share of clips (with a reference) that returned no text |
| halluc. | Hypothesis longer than 2x the reference (words) |
| fallback | Clips where WhisperKit settled on a segment temperature above 0 (a re-decode happened); per-segment temperatures are in the CSV |
| lat p50 / p95 | Per-clip wall time of `transcribe` (median over `--runs`), after one untimed warm-up decode |
| RTF | Total latency / total audio |

The normalizer approximates Whisper's `EnglishTextNormalizer`: no British to American spelling table and no
ordinal/currency number forms. It runs on reference and hypothesis alike, so comparisons between configs
hold, but absolute numbers will not match published ones exactly.

Statistics: 25 clips is roughly 400 words, so 1-2 WER points are noise. Look at the paired per-clip deltas
(better / worse / same, plus the biggest moves) and treat empty outputs as their own problem, not a WER
number.
