#!/bin/bash
set -euo pipefail

swift build
swift test

swiftlint_bin="$(command -v swiftlint || true)"
if [[ -z "$swiftlint_bin" ]]; then
    swiftlint_prefix="$(brew --prefix swiftlint 2>/dev/null || true)"
    if [[ -n "$swiftlint_prefix" && -x "$swiftlint_prefix/bin/swiftlint" ]]; then
        swiftlint_bin="$swiftlint_prefix/bin/swiftlint"
    fi
fi

if [[ -n "$swiftlint_bin" ]]; then
    "$swiftlint_bin" lint --strict
else
    echo "swiftlint not found, skipping lint"
fi

swift_format_bin="$(command -v swift-format || true)"
if [[ -z "$swift_format_bin" ]]; then
    swift_format_prefix="$(brew --prefix swift-format 2>/dev/null || true)"
    if [[ -n "$swift_format_prefix" && -x "$swift_format_prefix/bin/swift-format" ]]; then
        swift_format_bin="$swift_format_prefix/bin/swift-format"
    fi
fi

if [[ -n "$swift_format_bin" ]]; then
    "$swift_format_bin" lint --configuration .swiftformat -r Sources Tests
else
    echo "swift-format not found, skipping format lint"
fi
