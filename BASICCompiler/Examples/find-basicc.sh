# find-basicc.sh — which compiler and runtime an example uses.
#
# Sourced by each example's run.sh, after it sets PKG to the BASICCompiler
# package. BASICC and BASICC_RT_LIB still win when they are set.
#
# The examples live in this tree and show what this tree's compiler can do,
# so they use this tree's builds, not a `basicc` that happens to be on PATH.
# An installed copy is whatever was current the day it was installed: one
# from before Swift framework imports existed reports
# "IMPORT could not find ActiveUI" and looks like the example is broken.
#
# Between the two in-tree build directories, the newer file wins. Both are
# real builds, and "the one built most recently" is what a person running
# an example after a change expects.

newest() {
    newest_path=""
    for candidate in "$@"; do
        [ -f "$candidate" ] || continue
        if [ -z "$newest_path" ] || [ "$candidate" -nt "$newest_path" ]; then
            newest_path="$candidate"
        fi
    done
    printf '%s' "$newest_path"
}

if [ -z "${BASICC:-}" ]; then
    BASICC=$(newest "$PKG/.build/debug/basicc" "$PKG/.build-claude/debug/basicc" \
                    "$PKG/.build/release/basicc" "$PKG/.build-claude/release/basicc")
    if [ -z "$BASICC" ]; then
        BASICC=$(command -v basicc || true)
        [ -n "$BASICC" ] || {
            echo "no basicc: build one with  swift build --package-path $PKG" >&2
            exit 1
        }
        echo "==> no in-tree build; using $BASICC from PATH" >&2
    fi
fi

if [ -z "${BASICC_RT_LIB:-}" ]; then
    BASICC_RT_LIB=$(newest "$PKG/.build/release/libBASICRTHost.a" "$PKG/.build-claude/release/libBASICRTHost.a")
fi
export BASICC BASICC_RT_LIB

echo "==> basicc: $BASICC" >&2
