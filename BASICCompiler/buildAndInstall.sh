#!/bin/zsh
# Builds basicc in release and installs it, the same shape as ActivePascal's
# and COBOL's installers:
#
#   <prefix>/bin/basicc                  the compiler
#   <prefix>/bin/basictest               the conformance runner
#   <prefix>/share/basicc/BASICRT/       runtime sources (compiled once, cached)
#
# Usage:  ./buildAndInstall.sh [--prefix DIR] [--uninstall]
# Default prefix: /usr/local

set -euo pipefail
cd "$(dirname "$0")"

prefix=/usr/local
uninstall=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) prefix="$2"; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    *) echo "usage: $0 [--prefix DIR] [--uninstall]" >&2; exit 2 ;;
  esac
done

if [[ $uninstall -eq 1 ]]; then
  rm -f "$prefix/bin/basicc" "$prefix/bin/basictest"
  rm -rf "$prefix/share/basicc"
  echo "removed basicc from $prefix"
  exit 0
fi

echo "building basicc (release)…"
swift build -c release --product basicc 2>&1 | tail -1
swift build -c release --product basictest 2>&1 | tail -1
bin="$(swift build -c release --show-bin-path)"

mkdir -p "$prefix/bin" "$prefix/share/basicc"
install -m 755 "$bin/basicc" "$prefix/bin/basicc"
install -m 755 "$bin/basictest" "$prefix/bin/basictest"
rm -rf "$prefix/share/basicc/BASICRT"
cp -R Sources/BASICRT "$prefix/share/basicc/BASICRT"

# Probe: compile a program with the environment cleared, so the installed
# compiler is proven to find its own runtime.
probe="$(mktemp -d)"
printf 'PRINT "basicc ok"\n' > "$probe/probe.bas"
if env -i PATH=/usr/bin:/bin HOME="$HOME" "$prefix/bin/basicc" build "$probe/probe.bas" -o "$probe/probe" && [[ "$("$probe/probe")" == "basicc ok" ]]; then
  echo "installed basicc to $prefix/bin (runtime in $prefix/share/basicc)"
else
  echo "install probe failed" >&2
  exit 1
fi
rm -rf "$probe"
