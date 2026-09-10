#!/bin/sh
# The dialect performance gate (R2.4).
#
# Runs each benchmark under both dialects and reports Rev 2's time as a ratio
# of Rev 1's. **Relative, not absolute**: a wall-clock budget would pass or
# fail on how busy the machine is, while the ratio between two binaries built
# from the same source in the same run is a property of the compiler.
#
#   Scripts/dialect-bench.sh              # report
#   MAX_RATIO=1.5 Scripts/dialect-bench.sh   # fail if Rev 2 is >1.5x Rev 1
#
# Correctness is checked in the same run: both binaries must print the same
# checksum, because a dialect that is fast and wrong is not fast.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
pkg="$root/BASICCompiler"
BASICC=${BASICC:-$pkg/.build-claude/debug/basicc}
: "${BASICC_RT_LIB:=$pkg/.build-claude/release/libBASICRTHost.a}"
export BASICC_RT_LIB
MAX_RATIO=${MAX_RATIO:-0}
REPEATS=${REPEATS:-3}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# Best of N: the minimum is the least contaminated by whatever else the
# machine was doing, which is the number that reflects the compiler.
best() {
    prog=$1; best=""
    i=0
    while [ "$i" -lt "$REPEATS" ]; do
        start=$(python3 -c 'import time;print(time.perf_counter())')
        "$prog" > "$out/run.txt" 2>&1
        end=$(python3 -c 'import time;print(time.perf_counter())')
        d=$(python3 -c "print($end-$start)")
        if [ -z "$best" ]; then best=$d; else best=$(python3 -c "print(min($best,$d))"); fi
        i=$((i+1))
    done
    echo "$best"
}

status=0
printf '%-12s %10s %10s %8s  %s\n' benchmark rev1 rev2 ratio checksum
for f in "$pkg"/Tests/Benchmarks/*.bas; do
    n=$(basename "$f" .bas)
    "$BASICC" build "$f" -o "$out/t-$n" --dialect traditional > "$out/$n.tb" 2>&1 || { echo "$n: rev1 build failed"; status=1; continue; }
    "$BASICC" build "$f" -o "$out/s-$n" --dialect swift       > "$out/$n.sb" 2>&1 || { echo "$n: rev2 build failed"; status=1; continue; }
    t1=$(best "$out/t-$n"); c1=$("$out/t-$n")
    t2=$(best "$out/s-$n"); c2=$("$out/s-$n")
    ratio=$(python3 -c "print(f'{$t2/$t1:.2f}')")
    same=same
    if [ "$c1" != "$c2" ]; then same="DIFFERS"; status=1; fi
    printf '%-12s %9.3fs %9.3fs %7sx  %s\n' "$n" "$t1" "$t2" "$ratio" "$same"
    if [ "$MAX_RATIO" != "0" ]; then
        over=$(python3 -c "print(1 if $ratio > $MAX_RATIO else 0)")
        [ "$over" = "1" ] && { echo "  FAIL: $n is ${ratio}x Rev 1, over the $MAX_RATIO limit"; status=1; }
    fi
done
exit $status
