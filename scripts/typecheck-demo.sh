#!/usr/bin/env bash
#
# Type-checks the demo app and its UI tests against the iOS SDK.
#
# The demo is where autocapture, APNs and every `#if os(iOS)` branch actually
# RUN — none of that code is even compiled into the macOS `swift test` run. This
# script is the cheap half of that guarantee: it proves the app and its tests
# compile at the SDK's real deployment floor (iOS 15) without needing the
# multi-GB platform components that `xcodebuild` requires. CI runs the full
# `xcodebuild test` on a simulator; this runs anywhere Xcode is installed.
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

if [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

DEVICE_SDK=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)
SIM_PLATFORM=$(xcrun --sdk iphonesimulator --show-sdk-platform-path 2>/dev/null)

if [ -z "$DEVICE_SDK" ] || [ ! -d "$DEVICE_SDK" ]; then
    echo "  iOS SDK not installed — SKIP (not proof the demo builds)"
    exit 0
fi

module_dir=$(mktemp -d)
trap 'rm -rf "$module_dir"' EXIT

# The demo imports Intempt, so the module has to exist for iOS first.
echo "  building Intempt module for iOS..."
if ! xcrun swiftc -emit-module -module-name Intempt \
    -sdk "$DEVICE_SDK" -target arm64-apple-ios15.0 \
    -emit-module-path "$module_dir/Intempt.swiftmodule" \
    $(find Sources/Intempt -name '*.swift') 2>"$module_dir/module.log"; then
    echo "  FAILED to build the Intempt module for iOS"
    grep 'error:' "$module_dir/module.log" | head -20
    exit 1
fi

failed=0

echo "  type-checking IntemptDemo (iOS 15)..."
if xcrun swiftc -typecheck -sdk "$DEVICE_SDK" -target arm64-apple-ios15.0 \
    -I "$module_dir" IntemptDemo/IntemptDemo/*.swift 2>"$module_dir/app.log"; then
    echo "    OK"
else
    echo "    FAIL"
    grep 'error:' "$module_dir/app.log" | head -20
    failed=1
fi

if [ -n "$SIM_PLATFORM" ] && [ -d "$SIM_PLATFORM" ]; then
    echo "  type-checking IntemptDemoUITests (iOS 15 simulator)..."
    if xcrun swiftc -typecheck -sdk "$SIM_SDK" \
        -target arm64-apple-ios15.0-simulator \
        -F "$SIM_PLATFORM/Developer/Library/Frameworks" \
        -I "$SIM_PLATFORM/Developer/usr/lib" \
        IntemptDemo/IntemptDemoUITests/*.swift 2>"$module_dir/uitests.log"; then
        echo "    OK"
    else
        echo "    FAIL"
        grep 'error:' "$module_dir/uitests.log" | head -20
        failed=1
    fi
else
    echo "  simulator platform missing — UI tests SKIPPED"
fi

if [ "$failed" -gt 0 ]; then
    echo "Demo type-check FAILED"
    exit 1
fi

echo "Demo app and UI tests compile clean at iOS 15."
