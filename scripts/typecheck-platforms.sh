#!/usr/bin/env bash
#
# Type-checks every source file against every supported platform SDK.
#
# `swift test` runs on the macOS host, where all `#if os(iOS)` code is excluded
# from the build entirely. Without this gate, UIKit code could be arbitrarily
# broken and the suite would still be green — which is exactly the hole the
# audit flagged as BLOCK-5.
#
# Uses `swiftc -typecheck` rather than `xcodebuild`, deliberately: xcodebuild
# needs the full platform components (several GB per platform, downloaded
# separately), while the SDKs that ship with Xcode are enough to prove the code
# compiles. Faster in CI and it works on a machine that has not run
# `xcodebuild -downloadPlatform`.
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

if [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

SOURCES=$(find Sources/Intempt -name '*.swift')
if [ -z "$SOURCES" ]; then
    echo "no sources found"
    exit 1
fi

# sdk-name:target-triple — the deployment floors from Package.swift.
PLATFORMS=(
    "iphoneos:arm64-apple-ios15.0"
    "iphonesimulator:arm64-apple-ios15.0-simulator"
    "appletvos:arm64-apple-tvos15.0"
    "watchos:arm64_32-apple-watchos8.0"
    "macosx:x86_64-apple-macos12.0"
)

failed=0
skipped=0

for entry in "${PLATFORMS[@]}"; do
    sdk_name="${entry%%:*}"
    target="${entry#*:}"

    sdk_path=$(xcrun --sdk "$sdk_name" --show-sdk-path 2>/dev/null)
    if [ -z "$sdk_path" ] || [ ! -d "$sdk_path" ]; then
        # Skipping is reported, never silent: a platform that quietly stops
        # being checked is the same as not supporting it.
        printf '  %-18s %-34s SKIP (SDK not installed)\n' "$sdk_name" "$target"
        skipped=$((skipped + 1))
        continue
    fi

    log=$(mktemp)
    # shellcheck disable=SC2086
    xcrun swiftc -typecheck -sdk "$sdk_path" -target "$target" $SOURCES >"$log" 2>&1
    status=$?

    errors=$(grep -c 'error:' "$log")
    warnings=$(grep -c 'warning:' "$log")

    if [ "$status" -eq 0 ] && [ "$warnings" -eq 0 ]; then
        printf '  %-18s %-34s OK\n' "$sdk_name" "$target"
    else
        printf '  %-18s %-34s FAIL (%s errors, %s warnings)\n' \
            "$sdk_name" "$target" "$errors" "$warnings"
        grep -E 'error:|warning:' "$log" | head -20
        failed=$((failed + 1))
    fi
    rm -f "$log"
done

if [ "$skipped" -gt 0 ]; then
    echo "  ($skipped platform(s) skipped — not proof of support)"
fi

if [ "$failed" -gt 0 ]; then
    echo "FAILED on $failed platform(s)"
    exit 1
fi

echo "All checked platforms compile clean."
