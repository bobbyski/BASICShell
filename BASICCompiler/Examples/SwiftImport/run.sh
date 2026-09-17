#!/bin/sh
# Builds the BASIC program that imports the Swift framework, and runs it.
#
#   ./run.sh
#   BASICC=/path/to/basicc ./run.sh
set -e
cd "$(dirname "$0")/Program"

# Program/ -> SwiftImport/ -> Examples/ -> the BASICCompiler package.
PKG=$(cd ../../.. && pwd)
. ../../find-basicc.sh

echo "==> what the framework gives the program"
"$BASICC" import-report main.bas | sed 's/^/    /'

echo
echo "==> compiling (Package.swift selects the Swift dialect)"
"$BASICC" build main.bas -o Build/shapes-demo

echo
echo "==> running"
./Build/shapes-demo
