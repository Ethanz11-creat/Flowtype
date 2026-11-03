#!/bin/bash
set -euo pipefail
[ "$#" -eq 4 ] && [ "$1" = --app ] && [ "$3" = --output ] && [[ "$2" = /* ]] && [[ "$4" = /* ]] || exit 64
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
mkdir -p "$ROOT/build"
TOOLS=$(mktemp -d "$ROOT/build/.m5-tools-XXXXXX")
trap 'rm -rf "$TOOLS"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
/usr/bin/swiftc "$ROOT/scripts/verification/BoundedProcess.swift" "$ROOT/scripts/verification/ArtifactPackaging.swift" "$ROOT/scripts/verification/ArtifactPackagingCLI.swift" -o "$TOOLS/m5-artifact-tool"
"$TOOLS/m5-artifact-tool" check "$ROOT" "$@"
