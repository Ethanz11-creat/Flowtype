#!/bin/bash
# Run from this worktree only, after final review/fixes. Avoid Python entirely.
set -e
python3() { return 1; }
export -f python3
bash scripts/build-app.sh
