# dictate

Minimal macOS push-to-talk dictation. Menu bar only.

## Build

Requires Xcode Command Line Tools (`xcode-select --install`).

```sh
# Debug (development)
swift build
.build/debug/dictate

# Release (personal use)
# Note: WMO disabled due to a compiler crash in the Tokenizers dependency
swift build -c release -Xswiftc -no-whole-module-optimization
.build/release/dictate
```

> **Note:** Use the binary directly rather than `swift run` — running via `swift run` rebuilds the binary and invalidates the Accessibility permission entry in TCC.
