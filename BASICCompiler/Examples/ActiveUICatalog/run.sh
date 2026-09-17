#!/bin/sh
# Builds the ActiveUI catalog written in BASIC, and runs it.
#
#   ./run.sh              build, print the API tour, and open the catalog window
#   ./run.sh --report     what ActiveUI gives a BASIC program, and what it does not
#   ./run.sh --probe      the coverage gate: every shim compiled, every thunk emitted
#
# The Swift original is `cd ActiveUI/Code/ActiveUICatalog && swift run
# ActiveUICatalog`. This is its counterpart, and the whole claim is what is
# *not* here: no bindings, no shim layer, no generated wrapper to re-sync.
# `IMPORT "ActiveUI"` reads the framework's own symbol graph, so a fix in
# ActiveUI's core arrives on the next build with no BASIC changed.
set -e
cd "$(dirname "$0")/Program"

# Program/ -> ActiveUICatalog/ -> Examples/ -> the BASICCompiler package.
PKG=$(cd ../../.. && pwd)
. ../../find-basicc.sh

case "${1:-}" in
    --report) exec "$BASICC" import-report main.bas ;;
    --probe)  exec "$BASICC" import-probe main.bas ;;
esac

echo "==> compiling (Package.swift selects the Swift dialect)"
"$BASICC" build main.bas -o Build/catalog

echo
echo "==> running (the window stays up until you close it or press Cmd-Q)"
./Build/catalog
