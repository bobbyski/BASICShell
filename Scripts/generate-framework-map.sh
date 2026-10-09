#!/bin/sh
# Regenerates BASICFrameworkMap (BASIC-45): R4's shims for every member of the
# frameworks BASICStudio contains, the entries that call them by name, and
# each framework's symbol graph for the compiler Studio carries.
#
#   Code/Scripts/generate-framework-map.sh [path to basicc]
#
# Run it when ActiveUI or TUIKit changes. Each framework is resolved from the
# example package that names it, as `basicc import-report` resolves it.
set -e
CODE=$(cd "$(dirname "$0")/.." && pwd)
BASICC=${1:-$CODE/BASICCompiler/.build/debug/basicc}
"$BASICC" framework-map "$CODE/BASICFrameworkMap/Sources/BASICFrameworkMap" \
    ActiveUI="$CODE/BASICCompiler/Examples/ActiveUICatalog/Program" \
    TUIKit="$CODE/BASICCompiler/Examples/TUIKitExhibit/Program"
