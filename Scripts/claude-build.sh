#!/bin/sh
# Build or test a package in a PRIVATE scratch directory.
#
# SwiftPM takes an exclusive lock on a build directory, so two people — or two
# agents — building the same package at once serialise, and the one that waits
# looks hung. Giving each its own --scratch-path removes the contention
# entirely, at the cost of not sharing compiled artifacts.
#
#   Scripts/claude-build.sh BASICCompiler build
#   Scripts/claude-build.sh BASICCompiler test --filter DialectParityTests
#
# Never kill another SwiftPM to take its lock: it may not be yours.
set -e
package=${1:?usage: claude-build.sh <package-dir> <build|test|run> [args...]}
shift
action=${1:?usage: claude-build.sh <package-dir> <build|test|run> [args...]}
shift

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root/$package"

# Skip the runtime archive rebuild, which is a second SwiftPM invocation and
# the usual reason a build appears to stall.
if [ -z "$BASICC_RT_LIB" ] && [ -f "$root/BASICCompiler/.build-claude/release/libBASICRTHost.a" ]; then
    BASICC_RT_LIB="$root/BASICCompiler/.build-claude/release/libBASICRTHost.a"
    export BASICC_RT_LIB
fi

exec swift "$action" --scratch-path .build-claude "$@"
