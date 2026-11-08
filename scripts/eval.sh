#!/bin/bash
# Build dictate-eval (release) and run it. Latency numbers are only meaningful from a release build.
# Usage: scripts/eval.sh [options] [config ...]   (see: scripts/eval.sh --help)
set -euo pipefail

swift build -c release --product dictate-eval >&2
"$(swift build -c release --show-bin-path)/dictate-eval" "$@"
