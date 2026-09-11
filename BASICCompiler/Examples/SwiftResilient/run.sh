#!/bin/sh
# Builds the BASIC program whose class inherits a resilient Swift class, and
# runs it.
#
#   ./run.sh
#   BASICC=/path/to/basicc ./run.sh
set -e
cd "$(dirname "$0")/Program"

BASICC=${BASICC:-basicc}
# Program/ -> SwiftResilient/ -> Examples/ -> the BASICCompiler package.
PKG=$(cd ../../.. && pwd)
: "${BASICC_RT_LIB:=$PKG/.build-claude/release/libBASICRTHost.a}"
[ -f "$BASICC_RT_LIB" ] || BASICC_RT_LIB="$PKG/.build/release/libBASICRTHost.a"
export BASICC_RT_LIB

echo "==> compiling (Package.swift selects the Swift dialect)"
"$BASICC" build main.bas -o Build/panel-demo

echo
echo "==> running"
./Build/panel-demo
