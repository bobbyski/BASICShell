#!/bin/bash
#
# buildtosystem.sh — build BASICShell in release and install it system-wide.
#
# Usage:
#   ./buildtosystem.sh                 build, test, install to /usr/local
#   ./buildtosystem.sh --skip-tests    build and install without running tests
#   PREFIX=/opt/basic ./buildtosystem.sh
#
# A release build takes about 3-4 minutes from clean. Most of it is swift-syntax,
# which TUIKit's @Bound macro requires and which SwiftPM rebuilds for the release
# configuration; single files sit on screen for a minute at a time. It is slow,
# not stuck — a heartbeat prints every 15 seconds so you can tell the difference.
#
# Nothing is copied unless the build succeeds, and — unless you skip them — the
# tests pass. An install that half-works is worse than no install: the shell you
# just replaced was the one that worked.
#
# ## Why the tests are in another package
#
# BASICShell has no test target: `swift test` here fails with "no tests found".
# Everything worth testing lives in BASICCore, the package this one depends on
# by path, and that is where the 353 tests are. So the test step runs the
# dependency's suite. Skipping it because "this package has no tests" would mean
# installing an interpreter whose interpreter was never tested.
#
# ## Why not /bin
#
# macOS protects /bin with System Integrity Protection. It is marked
# `restricted`, which means *even root cannot write there* — `sudo cp` fails
# with "Operation not permitted" and no amount of permission-fixing helps. The
# conventional and writable location is /usr/local/bin, which is on the default
# PATH. Set PREFIX to override.
#
# ## Layout, and why the binary alone is not enough
#
# BASICShell reads its demo programs out of a SwiftPM resource bundle. SwiftPM's
# generated `Bundle.module` accessor looks for that bundle **beside the
# executable**, and if that fails falls back to an absolute path inside `.build`
# that is baked into the binary at compile time. That fallback is a trap: on the
# machine that did the build, a bundle-less install works perfectly — right up
# until someone deletes `.build`, at which point the shell dies with a Swift
# `fatalError` the moment it touches a demo. So the bundles are installed too:
#
#   $PREFIX/bin/basicshell
#   $PREFIX/bin/*.bundle                     -> symlinks into the directory below
#   $PREFIX/lib/basicshell/BASICShell_BASICShell.bundle/Demos/*.bas
#
# The compiler goes with it, in the layout its own buildAndInstall.sh uses:
#
#   $PREFIX/bin/basicc                       the compiler
#   $PREFIX/bin/basictest                    the conformance runner
#   $PREFIX/bin/basiclint                    the linter
#   $PREFIX/lib/libBASICRTHost.a             the runtime it links
#   $PREFIX/share/basicc/BASICRT/            runtime sources, the fallback
#
# The shell's JIT finds `basicc` on PATH, so a shell installed without one
# can interpret and not compile. Installing them together is what keeps
# `RUN` and `JIT` the same age — a JIT'd program carrying a months-old
# runtime behaves like a months-old build, and looks like a live bug.
#
# The payload lives under lib/ because /usr/local/bin is a directory of
# programs, not a place to unpack a tree of BASIC demos; the symlinks in bin/
# are what `Bundle.module` actually finds, and Foundation resolves them.
#
# The verify step at the end proves this properly — see the comment there.

set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/lib/basicshell"
SKIP_TESTS=0

# The product is `BASICShell`; the installed command is lowercase, because that
# is what the demos and SHELL.md put in their shebangs: #!/usr/bin/env basicshell
PRODUCT="BASICShell"
COMMAND_NAME="basicshell"

for argument in "$@"; do
    case "$argument" in
        --skip-tests) SKIP_TESTS=1 ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "buildtosystem.sh: unknown option $argument" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")"
PACKAGE_DIR="$PWD"
CORE_DIR="$PACKAGE_DIR/../BASICCore"

# Each clears the line first, because the ticker parks the cursor at column 0
# of a line it has already written on. Without the erase, a short message would
# leave the tail of a longer tick behind it.
clear_line() { [ -t 1 ] && printf '\r\033[K'; return 0; }
say() { clear_line; printf '\033[1;36m==>\033[0m %s\n' "$1"; }
note() { clear_line; printf '    \033[2m%s\033[0m\n' "$1"; }
fail() { clear_line; printf '\033[1;31mfailed:\033[0m %s\n' "$1" >&2; exit 1; }

# A heartbeat, so a slow step is visibly alive.
#
# SwiftPM's progress line can sit unchanged on `[47/56] Compiling …` for a
# minute at a time, which is indistinguishable from a hang, and the reasonable
# thing for anyone watching to do is press Ctrl-C.
#
# On a terminal it rewrites **one line**: carriage return, the text, then erase
# to end of line. The erase matters as much as the return — without it a shorter
# tick leaves the tail of a longer one on screen (`1m00s` over `59m45s` reads
# `1m00s5s`).
#
# Redirected, it does the opposite: a carriage return means nothing to a file,
# so `\r` would run every tick into one enormous line. There it prints ordinary
# lines, four times less often, which keeps a log readable while still showing
# that something is alive.
TICKER_PID=""
if [ -t 1 ]; then TICKER_INTERVAL=15; else TICKER_INTERVAL=60; fi

start_ticker() {
    local label="$1"
    # Asked once, not per tick: a resize mid-build is not worth a subprocess
    # every fifteen seconds, and a stale width only means padding that stops a
    # column or two short.
    local width=80
    if [ -t 1 ]; then width="$( (tput cols 2>/dev/null) || echo 80 )"; fi
    [ "$width" -gt 1 ] 2>/dev/null || width=80
    width=$((width - 1))

    ( trap 'exit 0' TERM
      local seconds=0
      local tick
      while true; do
          sleep "$TICKER_INTERVAL"
          seconds=$((seconds + TICKER_INTERVAL))
          if [ -t 1 ]; then
              # Erase, write **padded to the full width**, and park the cursor
              # back at column 0.
              #
              # The trailing `\r` is what keeps SwiftPM's next line from
              # arriving wearing a `building… 0m15s` prefix: left sitting after
              # its own text, everything printed next would append to it.
              #
              # The padding covers the other half. Parked at column 0, a *short*
              # line printed next overwrites only its first few columns and
              # leaves the tail of the tick showing — `short` over
              # `    testing… 0m03s` reads `shortng… 0m03s`. Padding with spaces
              # means there is nothing left to show.
              printf -v tick '    %s… %dm%02ds' \
                  "$label" $((seconds / 60)) $((seconds % 60))
              printf '\r\033[K\033[2m%-*s\033[0m\r' "$width" "$tick"
          else
              printf '    %s… %dm%02ds\n' "$label" $((seconds / 60)) $((seconds % 60))
          fi
      done ) &
    TICKER_PID=$!
}

stop_ticker() {
    if [ -n "$TICKER_PID" ]; then
        kill "$TICKER_PID" 2>/dev/null || true
        wait "$TICKER_PID" 2>/dev/null || true
        TICKER_PID=""
        # Erase whatever the last tick left. It has no newline, so anything
        # printed next would otherwise begin on the same line as `testing… 4m15s`.
        [ -t 1 ] && printf '\r\033[K'
    fi
    # Not decoration. Redirected to a file `[ -t 1 ]` is false, which makes that
    # `&&` list — and so this function — return 1, and under `set -e` the caller
    # is killed. The script then stopped dead after a successful build with no
    # message at all, but only when its output was piped.
    return 0
}

# One cleanup handler, not several.
#
# `trap ... EXIT` *replaces* the previous EXIT trap rather than adding to it, so
# a second `trap` installed halfway down the script silently disables the first.
# Everything that needs undoing registers here instead, and the variables are
# empty until the step that sets them runs.
STAGE=""
HIDDEN_BUNDLE=""
PROBE_DIR=""
cleanup() {
    stop_ticker
    # Restore the build-tree bundle the verify step moves aside, first and
    # unconditionally: leaving it hidden would break `swift run` afterwards.
    if [ -n "$HIDDEN_BUNDLE" ] && [ -e "$HIDDEN_BUNDLE" ]; then
        mv -f "$HIDDEN_BUNDLE" "${HIDDEN_BUNDLE%.hidden}" 2>/dev/null || true
    fi
    [ -n "$STAGE" ] && rm -rf "$STAGE"
    [ -n "$PROBE_DIR" ] && rm -rf "$PROBE_DIR"
    return 0
}
trap 'cleanup' EXIT INT TERM

# How long the suite may take before it is treated as hung. Generous — it runs
# in about half a minute including its debug build, and a slow machine is not a
# hang.
TEST_TIMEOUT="${TEST_TIMEOUT:-900}"

# Runs a command with a deadline, returning 124 if it ran out.
#
# `timeout(1)` is GNU coreutils and macOS does not ship it, so this is the
# portable equivalent: start the command, start a watchdog, and let whichever
# finishes first decide. The watchdog is killed on the normal path so it never
# outlives the run.
run_with_deadline() {
    local seconds="$1"; shift

    # A flag file rather than the watchdog's own liveness. Asking whether the
    # watchdog is still running races with it: having killed the command it is
    # still sitting in its grace-period sleep, so it looks alive and the timeout
    # reads as an ordinary failure — 143 rather than 124, which is the one thing
    # this function exists to tell apart.
    local flag; flag="$(mktemp)"

    "$@" &
    local command_pid=$!

    ( sleep "$seconds"
      printf 'fired' > "$flag"
      kill -TERM "$command_pid" 2>/dev/null
      sleep 5
      kill -KILL "$command_pid" 2>/dev/null ) 2>/dev/null &
    local watchdog_pid=$!

    local status=0
    wait "$command_pid" 2>/dev/null || status=$?

    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true

    if [ -s "$flag" ]; then
        rm -f "$flag"
        return 124
    fi
    rm -f "$flag"
    return "$status"
}

# ---------------------------------------------------------------- preflight
if [ ! -f Package.swift ] || ! grep -q 'name: "BASICShell"' Package.swift; then
    fail "run this from the BASICShell package directory"
fi

command -v swift >/dev/null 2>&1 || fail "no swift toolchain on PATH"

# The demo bundle is a symlink into the sibling basicPrograms checkout
# (Sources/BASICShell/Resources/Demos -> ../../../../../basicPrograms/demos).
# If that target is missing the build still succeeds and installs an empty
# Demos directory, so say so now rather than shipping a shell whose LOAD of
# every bundled program fails.
if [ ! -d Sources/BASICShell/Resources/Demos ]; then
    fail "Sources/BASICShell/Resources/Demos does not resolve — the
       basicPrograms checkout it links to is missing, and the install would
       ship an empty demo bundle."
fi

# A restricted destination cannot be written even by root, so say so now
# rather than after the build.
if [ -e "$BIN_DIR" ] && ls -lO "$BIN_DIR" 2>/dev/null | head -2 | grep -q restricted; then
    fail "$BIN_DIR is protected by System Integrity Protection — not even
       sudo can write there. Use PREFIX=/usr/local (the default), or disable
       SIP, which you should not do for this."
fi

# ---------------------------------------------------------------- build
say "building release"
note "3-4 minutes from clean, nearly all of it swift-syntax, which TUIKit's"
note "@Bound macro requires. Single files sit on screen for a minute at a time."
start_ticker "building"
# The **product**, not the package: a bare `swift build` compiles every target
# in every dependency whether or not anything depends on it, which here means
# SwiftTerm's fuzzer and the VectorTerminalSDK demo for no benefit.
swift build -c release --product "$PRODUCT" || { stop_ticker; fail "release build"; }
stop_ticker

# The compiler, from the sibling package. Built here rather than by calling
# its own buildAndInstall.sh, because that script installs as it builds and
# this one has to build as you and install as root: running the whole of it
# under sudo would leave a .build directory owned by root.
#
# Before anything is copied, so a compiler that will not build stops the
# install rather than half-finishing it.
COMPILER_DIR="$PACKAGE_DIR/../BASICCompiler"
COMPILER_BIN=""
if [ -d "$COMPILER_DIR" ]; then
    say "building basicc (release)"
    start_ticker "building basicc"
    for product in basicc basictest basiclint BASICRTHost; do
        swift build -c release --package-path "$COMPILER_DIR" --product "$product" \
            || { stop_ticker; fail "release build of $product"; }
    done
    stop_ticker
    COMPILER_BIN="$(swift build -c release --package-path "$COMPILER_DIR" --show-bin-path)"
else
    note "no BASICCompiler package beside this one — installing the shell alone"
    note "JIT will report that basicc is not installed; RUN still interprets"
fi

BUILD_DIR="$(swift build -c release --show-bin-path)"
BINARY="$BUILD_DIR/$PRODUCT"
[ -x "$BINARY" ] || fail "no binary at $BINARY"

# ---------------------------------------------------------------- test
if [ "$SKIP_TESTS" -eq 0 ]; then
    if [ ! -f "$CORE_DIR/Package.swift" ]; then
        fail "no BASICCore package at $CORE_DIR — this package depends on it by
       path, so its absence means the build you just did used something else.
       Pass --skip-tests if you know why."
    fi
    say "running BASICCore tests"
    note "a debug build of the dependency first, then ~2s of tests (353 of them)"
    # --no-parallel keeps the swift-testing output in one readable stream and
    # costs nothing: the suite is CPU-cheap and finishes in about two seconds.
    #
    # Bounded, because the heartbeat only proves something is *running*. A suite
    # that takes under a minute has no business running for twenty, and a bound
    # turns a hang into a failure someone can read.
    start_ticker "testing"
    # `|| status=$?` rather than a bare call followed by `status=$?`: under
    # `set -e` a function that returns non-zero as a simple command exits the
    # script before the next line ever runs, so the timeout branch below would
    # be unreachable and a failing suite would report nothing.
    status=0
    run_with_deadline "$TEST_TIMEOUT" \
        swift test --package-path "$CORE_DIR" --no-parallel || status=$?
    stop_ticker
    if [ "$status" -eq 124 ]; then
        fail "tests did not finish within ${TEST_TIMEOUT}s — nothing installed.
    That is a hang, not slowness. Re-run \`swift test --package-path $CORE_DIR
    --no-parallel\` on its own to see which test never returned, or pass
    --skip-tests to install anyway."
    fi
    [ "$status" -eq 0 ] || fail "BASICCore tests — nothing installed"
else
    say "skipping tests (--skip-tests)"
fi

# ---------------------------------------------------------------- stage
say "staging resource bundles"
STAGE="$(mktemp -d)"

bundle_count=0
for bundle in "$BUILD_DIR"/*.bundle; do
    [ -d "$bundle" ] || continue

    # Only bundles this binary can actually ask for.
    #
    # `.build` is shared between configurations and SwiftPM never removes stale
    # artifacts, so a bundle belonging to a dependency that has since been
    # *dropped* sits there forever — SwiftTerm's did, for one whole release
    # after TermKit was replaced by TUIKit, and a plain `*.bundle` loop shipped
    # it. The binary itself is the authority: SwiftPM bakes each bundle's name
    # into the accessor it generates, so a name that does not appear in the
    # executable is a bundle nothing can ever load.
    name="$(basename "$bundle")"
    if ! grep -aq "$name" "$BINARY"; then
        note "skipping $name — stale, this binary never asks for it"
        continue
    fi
    # -L, not a plain -R. SwiftPM's `.copy("Resources/Demos")` copied the
    # *symlink*, so the built bundle contains
    #   Demos -> ../../../../../basicPrograms/demos
    # a relative link that only resolves from inside .build. `cp -R` would
    # install that link verbatim and every bundled demo would be gone the
    # moment anyone looked for it. -L follows it and copies the real files.
    cp -RL "$bundle" "$STAGE/" || fail "staging $(basename "$bundle")"
    bundle_count=$((bundle_count + 1))
done
[ "$bundle_count" -gt 0 ] || fail "no resource bundles in $BUILD_DIR"

demo_count="$(find "$STAGE/${PRODUCT}_${PRODUCT}.bundle/Demos" -name '*.bas' 2>/dev/null | wc -l | tr -d ' ')"
[ "$demo_count" -gt 0 ] || fail "the staged demo bundle has no programs in it"
note "$bundle_count bundle$([ "$bundle_count" -eq 1 ] || echo s), $demo_count demo programs"

# ---------------------------------------------------------------- install
# Whether we need sudo is decided by the nearest directory that actually
# exists. Testing $PREFIX itself says "not writable" for any prefix we are about
# to create, which asks for a password to write into a temporary directory.
nearest_existing() {
    local path="$1"
    while [ ! -e "$path" ] && [ "$path" != "/" ]; do
        path="$(dirname "$path")"
    done
    printf '%s' "$path"
}

SUDO=""
if [ ! -w "$(nearest_existing "$BIN_DIR")" ]; then
    SUDO="sudo"
    say "installing to $PREFIX (needs sudo)"
else
    say "installing to $PREFIX"
fi

$SUDO mkdir -p "$BIN_DIR" "$LIB_DIR"

# The bundles go first. A binary that exists before its resources do is a shell
# that hits a Swift fatalError for anyone who runs a demo in between.
for bundle in "$STAGE"/*.bundle; do
    name="$(basename "$bundle")"
    $SUDO rm -rf "$LIB_DIR/$name"
    $SUDO cp -R "$bundle" "$LIB_DIR/$name"
    # The symlink is what Bundle.module finds: it looks beside the executable
    # and nowhere else. Relative, so moving or copying the whole prefix keeps
    # working.
    $SUDO rm -rf "$BIN_DIR/$name"
    $SUDO ln -s "../lib/basicshell/$name" "$BIN_DIR/$name"
done

# The manual `HELP` opens: Studio's markdown pages, installed rather than
# copied into this package, so there stays exactly one of them. An install
# without these is not broken — `HELP` falls back to the one-line command
# list — but it is a shell with no manual, which is worth failing loudly for
# rather than discovering later.
# The pages ride inside the resource bundle installed above, as one zip. It
# is also copied here on its own, so an install can be pointed at the manual
# without knowing the bundle's name.
USER_DOCS_ZIP="$PACKAGE_DIR/Sources/$PRODUCT/Resources/UserDocs.zip"
if [ -f "$USER_DOCS_ZIP" ]; then
    $SUDO cp "$USER_DOCS_ZIP" "$LIB_DIR/UserDocs.zip"
    note "help archive installed ($(($(stat -f%z "$USER_DOCS_ZIP") / 1024)) KB)"
else
    note "no UserDocs.zip — run Scripts/pack-userdocs.sh; HELP will fall back to the command list"
fi

# The compiler and its runtime, in the layout `RuntimeLibrary` looks for:
# the archive at <prefix>/lib, the sources at <prefix>/share/basicc,
# both found relative to the installed basicc rather than by any search path.
if [ -n "$COMPILER_BIN" ]; then
    $SUDO mkdir -p "$PREFIX/lib" "$PREFIX/share/basicc"
    for tool in basicc basictest basiclint; do
        $SUDO cp "$COMPILER_BIN/$tool" "$BIN_DIR/.$tool.new"
        $SUDO chmod 755 "$BIN_DIR/.$tool.new"
        $SUDO mv -f "$BIN_DIR/.$tool.new" "$BIN_DIR/$tool"
    done
    $SUDO cp "$COMPILER_BIN/libBASICRTHost.a" "$PREFIX/lib/libBASICRTHost.a"
    $SUDO chmod 644 "$PREFIX/lib/libBASICRTHost.a"
    $SUDO rm -rf "$PREFIX/share/basicc/BASICRT" "$PREFIX/share/basicc/BASICRTHostStubs"
    $SUDO cp -R "$COMPILER_DIR/Sources/BASICRT" "$PREFIX/share/basicc/BASICRT"
    $SUDO cp -R "$COMPILER_DIR/Sources/BASICRTHostStubs" "$PREFIX/share/basicc/BASICRTHostStubs"
    note "basicc, basictest and basiclint installed with their runtime"
fi

# Installed atomically: write beside the target, then rename over it. A shell
# being overwritten in place while someone is running it is a crash.
$SUDO cp "$BINARY" "$BIN_DIR/.$COMMAND_NAME.new"
$SUDO chmod 755 "$BIN_DIR/.$COMMAND_NAME.new"
$SUDO mv -f "$BIN_DIR/.$COMMAND_NAME.new" "$BIN_DIR/$COMMAND_NAME"

# Some demos are written `#!/usr/bin/env BASICShell`, in the product's casing.
# On a case-insensitive volume — the macOS default — that already resolves to
# the binary just installed and `-e` is true, so nothing happens. On a
# case-sensitive one it would not resolve at all, and this is the link that
# makes it.
[ -e "$BIN_DIR/$PRODUCT" ] || $SUDO ln -s "$COMMAND_NAME" "$BIN_DIR/$PRODUCT"

# ---------------------------------------------------------------- verify
say "verifying the installed shell"
INSTALLED="$BIN_DIR/$COMMAND_NAME"

PROBE_DIR="$(mktemp -d)"
printf 'print "ok"\n' > "$PROBE_DIR/smoke.bas"
printf '%s' "$("$INSTALLED" "$PROBE_DIR/smoke.bas" </dev/null 2>&1)" | grep -q '^ok$' \
    || fail "the installed shell cannot run a program"

# The compiler, with the environment cleared, so it is proven to find its own
# runtime rather than one that happens to be in this shell's environment.
#
# This is the check JIT depends on: `jit` shells out to whichever basicc is on
# PATH, and a compiler that cannot find its archive compiles nothing.
if [ -n "$COMPILER_BIN" ]; then
    printf 'PRINT "basicc ok"\n' > "$PROBE_DIR/probe.bas"
    if env -i PATH=/usr/bin:/bin HOME="$HOME" "$BIN_DIR/basicc" \
            build "$PROBE_DIR/probe.bas" -o "$PROBE_DIR/probe" >/dev/null 2>&1 \
       && [ "$("$PROBE_DIR/probe")" = "basicc ok" ]; then
        note "the installed basicc compiles and links against its own runtime"
    else
        fail "the installed basicc cannot build a program — check $PREFIX/lib"
    fi

    # And that the shell *finds* it, which is the whole point of installing the
    # two together: JIT looks for basicc on PATH and nowhere else, so this asks
    # the installed shell to resolve exactly that name the way JIT will.
    if PATH="$BIN_DIR:$PATH" "$INSTALLED" -c 'which "basicc"' 2>/dev/null | grep -q 'basicc'; then
        note "the installed shell resolves basicc on PATH — JIT will find it"
    else
        note "the installed shell cannot see basicc on PATH — JIT will decline"
        note "add $BIN_DIR to PATH, or set BASICC to point at it"
    fi
fi

# The check that matters — and it only means anything with the fallback gone.
#
# `Bundle.module` tries the path beside the executable *first* and the absolute
# `.build` path second. On this machine the second one exists, so an install
# that shipped no bundles at all would sail through this probe and fail on
# every other machine. Moving the build-tree bundle aside for the duration is
# what turns the probe into a test: with it hidden, a bundle-less install dies
# with `could not load resource bundle`, which is exactly the failure everyone
# else would have seen. The EXIT trap puts it back.
BUILD_BUNDLE="$BUILD_DIR/${PRODUCT}_${PRODUCT}.bundle"
if [ -d "$BUILD_BUNDLE" ]; then
    HIDDEN_BUNDLE="$BUILD_BUNDLE.hidden"
    mv -f "$BUILD_BUNDLE" "$HIDDEN_BUNDLE"
fi

# Run from an empty directory, so `hello.bas` cannot be found on disk and has
# to come out of the installed bundle. A check that the working directory can
# satisfy is not a check.
probe_output="$(cd "$PROBE_DIR" && "$INSTALLED" hello.bas </dev/null 2>&1 || true)"

if [ -n "$HIDDEN_BUNDLE" ]; then
    mv -f "$HIDDEN_BUNDLE" "$BUILD_BUNDLE"
    HIDDEN_BUNDLE=""
fi

if printf '%s' "$probe_output" | grep -q "BASICShell demo"; then
    say "bundled demos resolve from the installed layout"
    note "$demo_count demo programs under $LIB_DIR"
else
    echo "  warning: the installed shell could not load a bundled demo" >&2
    echo "           the shell runs; LOAD and RUN of the built-in programs will not" >&2
    printf '%s\n' "$probe_output" | sed 's/^/           /' >&2
fi

say "installed $COMMAND_NAME at $INSTALLED"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "  note: $BIN_DIR is not on your PATH" >&2 ;;
esac

# Scripts starting `#!/usr/bin/env basicshell` work as soon as the above is on
# PATH. To make it a login shell:
#   sudo sh -c "echo $INSTALLED >> /etc/shells"
#   chsh -s $INSTALLED
