#!/bin/bash
# Build dictate-eval (release) and run it. Latency numbers are only meaningful from a release build.
# Same -no-whole-module-optimization workaround as build.sh (swiftly 6.2.3 + WhisperKit).
# Usage: scripts/eval.sh [options] [config ...]   (see: scripts/eval.sh --help)
set -euo pipefail

swift build -c release --product dictate-eval -Xswiftc -no-whole-module-optimization >&2
"$(swift build -c release --show-bin-path)/dictate-eval" "$@"
