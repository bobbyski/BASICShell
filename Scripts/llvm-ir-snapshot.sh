#!/bin/bash
#
# llvm-ir-snapshot.sh — the LLVM IR basicc emits for every conformance
# program and every demo, written to one folder, so two snapshots can be
# diffed: the gate that keeps work on other back ends (BASIC-42) from
# changing a byte of the LLVM path.
#
# Usage: Code/Scripts/llvm-ir-snapshot.sh <basicc> <output-folder>
#        diff -r <before> <after>
#
# A program basicc refuses is recorded with its diagnostics, so a change in
# what is refused shows up too.

set -uo pipefail

BASICC="${1:?usage: llvm-ir-snapshot.sh <basicc> <output-folder>}"
OUT="${2:?usage: llvm-ir-snapshot.sh <basicc> <output-folder>}"
cd "$(dirname "$0")/.."
CODE="$PWD"
mkdir -p "$OUT"

count=0
while IFS= read -r source; do
    name="${source#$CODE/}"
    name="${name//\//__}"
    "$BASICC" build "$source" --emit-llvm -g0 > "$OUT/$name.ll" 2>&1
    count=$((count + 1))
done < <(
    find "$CODE/BASICCompiler/Tests/Programs" -name '*.bas'
    find -L "$CODE/basicPrograms/demos" -name '*.bas' 2>/dev/null
)
echo "llvm-ir-snapshot: $count programs -> $OUT"
