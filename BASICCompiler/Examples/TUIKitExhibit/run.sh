#!/bin/sh
# Builds the BASIC program that drives TUIKit, and runs it.
#
#   ./run.sh
#   BASICC=/path/to/basicc ./run.sh
set -e
cd "$(dirname "$0")/Program"

PKG=$(cd ../../.. && pwd)
. ../../find-basicc.sh

echo "==> compiling (Package.swift selects the Swift dialect)"
"$BASICC" build main.bas -o Build/tuikit-exhibit

echo
echo "==> running"
./Build/tuikit-exhibit
