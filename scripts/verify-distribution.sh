#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$ROOT"
for DIRECTORY in "$ROOT/build" "$ROOT/build/tools"; do
    if [ -L "$DIRECTORY" ] || { [ -e "$DIRECTORY" ] && [ ! -d "$DIRECTORY" ]; }; then exit 1; fi
done
mkdir -p "$ROOT/build/tools"
TEMP=$(mktemp -d "$ROOT/build/tools/.distribution-XXXXXX")
trap 'rm -rf "$TEMP"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
/usr/bin/swiftc -parse-as-library \
    "$ROOT/scripts/verification/BoundedProcess.swift" \
    "$ROOT/scripts/verification/ArtifactPackaging.swift" \
    "$ROOT/scripts/verification/VerificationReport.swift" \
    "$ROOT/scripts/verification/ManualValidation.swift" \
    "$ROOT/scripts/verification/ModelCenterAcceptance.swift" \
    "$ROOT/scripts/verification/DistributionVerification.swift" \
    "$ROOT/scripts/verification/DistributionVerificationSelfTests.swift" \
    "$ROOT/scripts/verification/DistributionVerificationCLI.swift" \
    -o "$TEMP/flowtype-distribution"
"$TEMP/flowtype-distribution" "$@"
