#!/bin/sh
# Builds sprite.bas into a Swift class, then a Swift program that inherits
# from it, and runs the result.
#
#   ./run.sh          uses the basicc on PATH
#   BASICC=... ./run.sh
set -e
cd "$(dirname "$0")"

BASICC=${BASICC:-basicc}
PACKAGE=$(cd ../.. && pwd)
BUILD=Build
SWIFTC=$(xcrun --find swiftc)
SDK=$(xcrun --show-sdk-path)
TARGET=$("$SWIFTC" -print-target-info | sed -n 's/.*"triple": "\([^"]*\)".*/\1/p' | head -1)

rm -rf "$BUILD" && mkdir -p "$BUILD"

echo "==> basicc: sprite.bas -> a Swift class"
"$BASICC" swift-class sprite.bas -o "$BUILD"

echo
echo "==> the interface basicc generated for Swift to compile against"
sed 's/^/    /' "$BUILD/sprite.swiftinterface"

echo "==> the root class BASIC classes descend from"
# The *module* only, not a library: BASICRTSwift is already inside the runtime
# archive linked below, and building a second copy as a dylib put two
# BASICObject classes in one process — which the ObjC runtime warns about and
# which makes dynamic casts unreliable.
"$SWIFTC" -emit-module -module-name BASICRTSwift -sdk "$SDK" -target "$TARGET" \
    "$PACKAGE/Sources/BASICRTSwift/BASICObject.swift" \
    -emit-module-path "$BUILD/BASICRTSwift.swiftmodule"

echo "==> compiling the generated interface into a module"
"$SWIFTC" -frontend -compile-module-from-interface "$BUILD/sprite.swiftinterface" \
    -o "$BUILD/sprite.swiftmodule" -I "$BUILD" -module-name sprite \
    -target "$TARGET" -sdk "$SDK"

echo "==> the Swift program, which subclasses the BASIC class"
# The runtime archive too: a BASIC class carries the runtime's own printing,
# defaults and type registration with it, so linking the class means linking
# the runtime — the same archive `basicc build` links into a program.
RT=${BASICC_RT_LIB:-$PACKAGE/.build-claude/release/libBASICRTHost.a}
if [ ! -f "$RT" ]; then
    echo "run.sh: no runtime archive at $RT — set BASICC_RT_LIB" >&2
    exit 1
fi
"$SWIFTC" -I "$BUILD" -target "$TARGET" -sdk "$SDK" \
    main.swift "$BUILD/sprite.o" "$RT" -o "$BUILD/demo"

echo
echo "==> running"
"$BUILD/demo"
