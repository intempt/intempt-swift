#!/usr/bin/env bash
# The SDK version lives in three places that CocoaPods resolves independently:
# the podspec, the Swift constant, and the git tag the podspec's :tag points at.
# When they drift, `pod trunk push` succeeds and ships a pod that reports a
# version it is not — which is invisible until someone debugs a support ticket
# against the wrong source.
set -euo pipefail

podspec=$(grep -E "^\s*s\.version\s*=" Intempt.podspec | sed -E "s/.*'([^']+)'.*/\1/")
swift=$(grep -E 'public static let sdkVersion' Sources/Intempt/Intempt.swift | sed -E 's/.*"([^"]+)".*/\1/')

echo "podspec: $podspec"
echo "swift:   $swift"

if [ "$podspec" != "$swift" ]; then
  echo "MISMATCH: Intempt.podspec says $podspec, Intempt.swift says $swift" >&2
  exit 1
fi

# The tag only has to exist once the version is released; a version bump lands
# before its tag, so a missing tag is reported rather than failed.
if git rev-parse "v$podspec" >/dev/null 2>&1; then
  echo "tag:     v$podspec present"
else
  echo "tag:     v$podspec NOT YET CREATED (expected before pod trunk push)"
fi

echo "version sources agree"
