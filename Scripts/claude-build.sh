#!/bin/sh
# Build or test a package in a PRIVATE scratch directory.
#
# SwiftPM takes an exclusive lock on a build directory, so two builds of one
# package serialise and the one that waits looks hung. This gives an agent its
# own --scratch-path so it cannot collide with a build you started yourself.
#
# It is NOT a licence to run two builds at once: overlapping invocations from
# one agent contend with each other just as well, and that is the usual cause.
# The other usual cause is `basicc`, which shells out to a second SwiftPM to
# build libBASICRTHost unless BASICC_RT_LIB points at a prebuilt archive.
#
#   Scripts/claude-build.sh BASICCompiler build
#   Scripts/claude-build.sh BASICCompiler test --filter DialectParityTests
#
# Never kill a SwiftPM to take its lock — wait, or use a scratch path. Even
# when the process is your own, killing it is fixing the symptom.
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
