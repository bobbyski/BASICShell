#!/bin/sh
# Builds the BASIC program whose class inherits a resilient Swift class, and
# runs it.
#
#   ./run.sh
#   BASICC=/path/to/basicc ./run.sh
set -e
cd "$(dirname "$0")/Program"

# Program/ -> SwiftResilient/ -> Examples/ -> the BASICCompiler package.
PKG=$(cd ../../.. && pwd)
. ../../find-basicc.sh

echo "==> compiling (Package.swift selects the Swift dialect)"
"$BASICC" build main.bas -o Build/panel-demo

echo
echo "==> running"
./Build/panel-demo
