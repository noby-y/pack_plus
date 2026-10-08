#!/bin/sh
# Every suite, in order. The three smoke tests install real plugins, so they
# share one scratch XDG tree and each one leaves state the next one wants.
set -e

cd "$(dirname "$0")/.."
scratch="${PACK_PLUS_SCRATCH:-/tmp/pack_plus_test}"
opt="$scratch/data/nvim/site/pack/core/opt"

nvim -l tests/spec_spec.lua

rm -rf "$scratch"
mkdir -p "$scratch/config" "$scratch/data"
export XDG_CONFIG_HOME="$scratch/config"
export XDG_DATA_HOME="$scratch/data"

nvim --headless -u tests/init_smoke.lua

# The update path needs a plugin that is both behind and dirty.
git -C "$opt/todo-comments.nvim" checkout -q HEAD~5
echo scratch >> "$opt/todo-comments.nvim/README.md"
nvim --headless -u tests/ui_smoke.lua

# Leave this one last: its `c` deletes everything the other suites installed.
nvim --headless -u tests/delete_smoke.lua

echo "all suites passed"
