#!/bin/bash
#
# pack-userdocs.sh — build UserDocs.zip from the manual's source directory.
#
# The pages in Code/BASICStudio/UserDocs are the source of truth and stay
# ordinary files: they are edited, reviewed and diffed as text. This packs
# them into the single archive the applications ship, which is what gets
# copied into a bundle and read by DocumentArchive at run time.
#
# Run it after changing a page. The archive is checked in, because a build
# that regenerates it on every run rewrites a binary file on every build and
# makes every branch conflict with every other one.
#
# Usage: Code/Scripts/pack-userdocs.sh

set -euo pipefail

# This script lives in Code/Scripts; CODE is the repository root.
cd "$(dirname "$0")/.."
CODE="$PWD"
SOURCE="$CODE/BASICStudio/UserDocs"
[ -d "$SOURCE" ] || { echo "pack-userdocs: no pages at $SOURCE" >&2; exit 1; }

COUNT="$(find "$SOURCE" -name '*.md' | wc -l | tr -d ' ')"
[ "$COUNT" -gt 0 ] || { echo "pack-userdocs: $SOURCE has no pages in it" >&2; exit 1; }

# Every destination that ships one. The shell reads it out of its SwiftPM
# resource bundle; Studio reads it out of its application bundle.
DESTINATIONS=(
    "$CODE/BASICShell/Sources/BASICShell/Resources/UserDocs.zip"
    "$CODE/BASICStudio/Sources/BASICStudio/Resources/UserDocs.zip"
)

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Zipped from inside the directory so entries are bare page names with no
# leading folder, and -X so no extended attributes ride along: the archive
# should differ between commits only when a page does.
( cd "$SOURCE" && zip -q -X -9 "$STAGE/UserDocs.zip" ./*.md )

for destination in "${DESTINATIONS[@]}"; do
    mkdir -p "$(dirname "$destination")"
    cp "$STAGE/UserDocs.zip" "$destination"
    echo "packed $COUNT pages -> ${destination#$CODE/}"
done
