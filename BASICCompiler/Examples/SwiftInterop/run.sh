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
"$SWIFTC" -emit-module -emit-library -module-name BASICRTSwift -sdk "$SDK" -target "$TARGET" \
    "$PACKAGE/Sources/BASICRTSwift/BASICObject.swift" \
    -o "$BUILD/libBASICRTSwift.dylib" \
    -emit-module-path "$BUILD/BASICRTSwift.swiftmodule" \
    -Xlinker -install_name -Xlinker "@rpath/libBASICRTSwift.dylib"

echo "==> compiling the generated interface into a module"
"$SWIFTC" -frontend -compile-module-from-interface "$BUILD/sprite.swiftinterface" \
    -o "$BUILD/sprite.swiftmodule" -I "$BUILD" -module-name sprite \
    -target "$TARGET" -sdk "$SDK"

echo "==> the Swift program, which subclasses the BASIC class"
"$SWIFTC" -I "$BUILD" -L "$BUILD" -lBASICRTSwift -target "$TARGET" -sdk "$SDK" \
    main.swift "$BUILD/sprite.o" -o "$BUILD/demo" \
    -Xlinker -rpath -Xlinker "$(cd "$BUILD" && pwd)"

echo
echo "==> running"
"$BUILD/demo"
