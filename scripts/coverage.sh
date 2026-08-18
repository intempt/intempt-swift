#!/usr/bin/env bash
# Line coverage over Sources/Intempt, from the profile `swift test` already emits.
#
# This repo had no coverage of any kind. Not a low number — no number: no
# `--enable-code-coverage`, no llvm-cov, no floor, nothing to read. The
# mutation gate is a strictly stronger signal than coverage on the fifteen
# behaviours it plants defects in, and it says nothing whatsoever about the
# other ~2,700 lines. This reports which of those the suite never touches.
#
# DELIBERATELY DOES NOT GATE BY DEFAULT.
#
# A floor invented before anyone has seen the real figure is a number pulled
# from the air, and the first PR it blocks teaches everyone to route around it.
# So: measure first, land the floor second, set to whatever CI actually reports
# minus a little headroom. Export COVERAGE_MIN=<percent> to turn on enforcement
# once that number exists.
#
# Usage: scripts/coverage.sh            report only
#        COVERAGE_MIN=70 scripts/coverage.sh   report, then fail under 70%
set -euo pipefail

cd "$(dirname "$0")/.."

MIN="${COVERAGE_MIN:-0}"

# Tests, the build directory and the resource-bundle shim are not the SDK.
# Counting them inflates the figure with code nobody ships.
IGNORE='(Tests|\.build|resource_bundle_accessor)'

bin_path="$(swift build --show-bin-path)"
profdata="$bin_path/codecov/default.profdata"

if [ ! -f "$profdata" ]; then
    echo "no profile at $profdata" >&2
    echo "run: swift test --enable-code-coverage" >&2
    exit 1
fi

# The test bundle layout differs by platform: a .xctest bundle on macOS, a bare
# executable on Linux. Resolve it rather than hard-coding either.
binary=""
for candidate in \
    "$bin_path"/*.xctest/Contents/MacOS/* \
    "$bin_path"/*.xctest; do
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
        binary="$candidate"
        break
    fi
done

if [ -z "$binary" ]; then
    echo "could not find the test binary under $bin_path" >&2
    exit 1
fi

echo "profile: $profdata"
echo "binary:  $binary"
echo

xcrun llvm-cov report \
    "$binary" \
    -instr-profile "$profdata" \
    --ignore-filename-regex="$IGNORE"

# The per-file table above is for a human reading the log. This is the single
# number, taken from llvm-cov's own JSON rather than scraped off that table --
# the table's column layout has changed between LLVM releases before.
summary="$(xcrun llvm-cov export \
    "$binary" \
    -instr-profile "$profdata" \
    --ignore-filename-regex="$IGNORE" \
    -summary-only)"

read -r lines_pct functions_pct regions_pct <<EOF
$(printf '%s' "$summary" | python3 -c '
import json, sys
t = json.load(sys.stdin)["data"][0]["totals"]
print(t["lines"]["percent"], t["functions"]["percent"], t["regions"]["percent"])
')
EOF

printf '\n'
printf 'line coverage:     %.2f%%\n' "$lines_pct"
printf 'function coverage: %.2f%%\n' "$functions_pct"
printf 'region coverage:   %.2f%%\n' "$regions_pct"

# Surfaced on the run's summary page so the number is visible without opening
# the log, which is where a figure nobody reads goes to die.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### Coverage"
        echo
        echo "| Metric | Percent |"
        echo "| --- | ---: |"
        printf '| Lines | %.2f%% |\n' "$lines_pct"
        printf '| Functions | %.2f%% |\n' "$functions_pct"
        printf '| Regions | %.2f%% |\n' "$regions_pct"
        echo
        if [ "$MIN" = "0" ]; then
            echo "_Reporting only — no floor is enforced yet. See scripts/coverage.sh._"
        else
            echo "_Floor: ${MIN}%._"
        fi
    } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$MIN" = "0" ]; then
    printf '\nno floor enforced (COVERAGE_MIN unset) — reporting only\n'
    exit 0
fi

python3 -c "
import sys
actual, minimum = float('$lines_pct'), float('$MIN')
if actual + 1e-9 < minimum:
    print(f'\nline coverage {actual:.2f}% is under the {minimum:.2f}% floor', file=sys.stderr)
    sys.exit(1)
print(f'\nline coverage {actual:.2f}% meets the {minimum:.2f}% floor')
"
