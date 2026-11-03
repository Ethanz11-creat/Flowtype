#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$ROOT"
fail() { printf 'FlowType evidence export: outputUnavailable\n' >&2; exit 1; }
[ "$#" -eq 1 ] || fail
for DIRECTORY in "$ROOT/build" "$ROOT/build/tools" "$ROOT/build/verification"; do
    [ ! -L "$DIRECTORY" ] && [ -d "$DIRECTORY" ] || fail
done
[ -f "$1" ] && [ ! -L "$1" ] || fail
# Consume the one safe report path emitted by this invocation; never search the verification root.
REPORT=$(awk '/^build\/verification\/[[:xdigit:]-]+\/(verify-report|bootstrap-failure)[.]json$/ { print; count++ } END { if (count != 1) exit 1 }' "$1") || fail
RUN_REL=${REPORT%/*}
RUN_ID=${RUN_REL##*/}
[[ "$RUN_ID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || fail
RUN="$ROOT/$RUN_REL"
[ -d "$RUN" ] && [ ! -L "$RUN" ] || fail
DEST="$ROOT/build/ci-evidence"
[ ! -L "$DEST" ] || fail
if [ -e "$DEST" ]; then
    [ -d "$DEST" ] && [ -z "$(ls -A "$DEST")" ] || fail
else
    mkdir "$DEST"
fi
if [ "${REPORT##*/}" = bootstrap-failure.json ]; then
    # This fallback also works when swiftc could not produce the tool. Compiler output is never uploaded.
    [ -f "$RUN/bootstrap-failure.json" ] && [ ! -L "$RUN/bootstrap-failure.json" ] || fail
    EXPECTED=$(mktemp "$ROOT/build/.bootstrap-XXXXXX")
    trap 'rm -f "$EXPECTED"' EXIT
    printf '{"schemaVersion":1,"status":"Fail","failureCode":"bootstrapFailed"}\n' > "$EXPECTED"
    cmp -s "$EXPECTED" "$RUN/bootstrap-failure.json" || fail
    cp "$EXPECTED" "$DEST/bootstrap-failure.json"
    printf 'FlowType verification: bootstrapFailed\n' > "$DEST/bootstrap.stderr"
else
    [ -x "$ROOT/build/tools/flowtype-verify" ] && [ ! -L "$ROOT/build/tools/flowtype-verify" ] || fail
    "$ROOT/build/tools/flowtype-verify" --export-evidence "$RUN" --output "$DEST"
fi
