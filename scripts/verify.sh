#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$ROOT"
for DIRECTORY in "$ROOT/build" "$ROOT/build/tools" "$ROOT/build/verification"; do
    if [ -L "$DIRECTORY" ] || { [ -e "$DIRECTORY" ] && [ ! -d "$DIRECTORY" ]; }; then
        printf 'FlowType verification: outputUnavailable\n' >&2
        exit 1
    fi
done
mkdir -p "$ROOT/build/tools"
TEMP=$(mktemp -d "$ROOT/build/tools/.verify-XXXXXX")
trap 'rm -rf "$TEMP"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
# ArtifactPackaging.swift supplies the existing owned lock/journal recovery; its CLI/@main is excluded.
if /usr/bin/swiftc -parse-as-library \
    "$ROOT/scripts/verification/BoundedProcess.swift" \
    "$ROOT/scripts/verification/ArtifactPackaging.swift" \
    "$ROOT/scripts/verification/VerificationReport.swift" \
    "$ROOT/scripts/verification/ManualValidation.swift" \
    "$ROOT/scripts/verification/VerificationSelfTests.swift" \
    "$ROOT/scripts/verification/VerificationCLI.swift" \
    -o "$TEMP/flowtype-verify" > "$TEMP/compile.log" 2>&1; then
    mv "$TEMP/flowtype-verify" "$ROOT/build/tools/flowtype-verify"
else
    IDENTIFIER=$(/usr/bin/uuidgen)
    REPORT="$ROOT/build/verification/$IDENTIFIER"
    mkdir -p "$REPORT"
    cp "$TEMP/compile.log" "$REPORT/bootstrap-compile.log"
    printf '{"schemaVersion":1,"status":"Fail","failureCode":"bootstrapFailed"}\n' > "$REPORT/bootstrap-failure.json"
    printf 'Verification bootstrap: Fail\nbuild/verification/%s/bootstrap-failure.json\n' "$IDENTIFIER"
    printf 'FlowType verification: bootstrapFailed\n' >&2
    exit 1
fi
"$ROOT/build/tools/flowtype-verify" "$@"
