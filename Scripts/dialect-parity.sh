#!/bin/sh
# Compile every conformance program with both dialects, run both, and report
# which produce different bytes. The shell twin of DialectParityTests: faster
# to iterate on, and it shows the diff.
#
#   Scripts/dialect-parity.sh                 # uses .build-claude/debug/basicc
#   BASICC=/path/to/basicc Scripts/dialect-parity.sh
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
pkg="$root/BASICCompiler"
BASICC=${BASICC:-$pkg/.build-claude/debug/basicc}
: "${BASICC_RT_LIB:=$pkg/.build-claude/release/libBASICRTHost.a}"
export BASICC_RT_LIB
out=${PARITY_OUT:-/tmp/dialect-parity}
rm -rf "$out"; mkdir -p "$out"
same=0; total=0; differ=""; fails=""
for f in "$pkg"/Tests/Programs/*.bas; do
  n=$(basename "$f" .bas); total=$((total+1))
  if ! "$BASICC" build "$f" -o "$out/t-$n" --dialect traditional >"$out/$n.trad.build" 2>&1; then fails="$fails $n:traditional"; continue; fi
  if ! "$BASICC" build "$f" -o "$out/s-$n" --dialect swift       >"$out/$n.swift.build" 2>&1; then fails="$fails $n:swift"; continue; fi
  (cd "$pkg/Tests/Programs" && "$out/t-$n" >"$out/$n.trad" 2>&1; echo "exit $?" >>"$out/$n.trad")
  (cd "$pkg/Tests/Programs" && "$out/s-$n" >"$out/$n.swift" 2>&1; echo "exit $?" >>"$out/$n.swift")
  if cmp -s "$out/$n.trad" "$out/$n.swift"; then same=$((same+1)); else differ="$differ $n"; fi
done
echo "identical: $same/$total"
[ -n "$differ" ] && { echo "DIFFER:$differ"; for n in $differ; do echo "--- $n"; diff "$out/$n.trad" "$out/$n.swift" | head -8; done; }
[ -n "$fails" ] && { echo "BUILD FAILED:$fails"; for e in $fails; do n=${e%%:*}; d=${e#*:}; echo "--- $n ($d)"; head -4 "$out/$n.$d.build"; done; }
[ -z "$differ$fails" ]
