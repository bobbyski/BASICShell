#!/bin/bash
#
# emit-gallery-template.sh — turn the TUIKit gallery into project templates.
#
# The gallery in basicPrograms/demos/gallery is the reference TUIKit program:
# eleven files, every control, and the only BASIC in the tree that shows
# IMPORT carrying a program across files. Both IDEs offer it as a project you
# can create and cut down, which means both need the source inside them —
# neither can assume this repository is on the machine.
#
# So it is copied, and copying is what this script exists to make safe. The
# Swift it writes is generated, never edited: change a gallery file, run this,
# and both copies are exactly the gallery again. Editing the generated file by
# hand puts the copy and the original quietly out of step, which is the whole
# failure this is meant to prevent.
#
# Usage:
#   Code/Scripts/emit-gallery-template.sh
#   FREEBIRD=/path/to/SwiftyTextEditor OMEGA=/path/to/OmegaCLIDE Code/Scripts/emit-gallery-template.sh

set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$PWD"
SOURCE="$ROOT/basicPrograms/demos/gallery"

FREEBIRD="${FREEBIRD:-/Users/bobby/AIResearch/SwiftyTextEditor}"
OMEGA="${OMEGA:-/Users/bobby/AIResearch/OmegaCLIDE}"

FREEBIRD_OUT="$FREEBIRD/Code/ProjectGenerator/Sources/ProjectGenerator/BASICGalleryTemplate.swift"
OMEGA_OUT="$OMEGA/Code/OmegaCLIDE/Sources/IDECore/Recipes/Recipes+BASICGallery.swift"

[ -d "$SOURCE" ] || { echo "emit-gallery-template: no gallery at $SOURCE" >&2; exit 1; }

# main.bas first: it is the file the Makefile builds and the one a reader
# should open, so it should be first in any list the IDE shows.
FILES=("main.bas")
for path in "$SOURCE"/*.bas; do
    name="$(basename "$path")"
    [ "$name" = "main.bas" ] || FILES+=("$name")
done

# A raw Swift literal (#"""…"""#) takes the BASIC through untouched: no
# backslash escapes and no \( interpolation, which BASIC source is full of.
# Checked rather than assumed, because a delimiter collision would produce
# Swift that does not compile and BASIC that is silently wrong.
for name in "${FILES[@]}"; do
    if grep -q '"""#' "$SOURCE/$name"; then
        echo "emit-gallery-template: $name contains the raw-string delimiter; widen it" >&2
        exit 1
    fi
done

python3 - "$SOURCE" "$FREEBIRD_OUT" "$OMEGA_OUT" "${FILES[@]}" <<'PYTHON'
import os, sys

source, freebird_out, omega_out, *names = sys.argv[1:]

def literal(text, indent):
    pad = " " * indent
    # The closing delimiter's indentation is what Swift strips from every
    # line, so the body is emitted at that same indentation and the BASIC's
    # own leading spaces survive.
    body = "\n".join(pad + line if line else "" for line in text.split("\n"))
    return '#"""\n' + body + "\n" + pad + '"""#'

files = [(name, open(os.path.join(source, name), encoding="utf-8").read()) for name in names]

banner = """//
//  {basename}
//
//  GENERATED — do not edit.
//
//  Written by Code/Scripts/emit-gallery-template.sh in the AIBasic repo from
//  basicPrograms/demos/gallery, which is the original. Change a gallery file
//  there and run that script; edits made here are lost the next time it runs
//  and, until then, are a copy that no longer matches what it copies.
//
"""

with open(freebird_out, "w", encoding="utf-8") as out:
    out.write(banner.format(basename=os.path.basename(freebird_out)))
    out.write("""
/// The TUIKit gallery's source, one entry per file.
///
/// Written into a generated project's `src/`, where `main.bas` IMPORTs the
/// rest by name — which is why they land in one directory and why `main.bas`
/// is first.
enum BASICGalleryTemplate {

    /// Every file of the gallery, `main.bas` first.
    static let files: [(name: String, contents: String)] = [
""")
    for name, text in files:
        out.write('        ("%s", %s),\n' % (name, literal(text, 8)))
    out.write("    ]\n}\n")

with open(omega_out, "w", encoding="utf-8") as out:
    out.write(banner.format(basename=os.path.basename(omega_out)))
    out.write("""
/// The TUIKit gallery as a project you can make and cut down.
///
/// The same eleven files FreebirdStudio's `BASICProjectGenerator` writes, so
/// the gallery is the same project wherever it was born.
extension BuiltInRecipes {

    static let basicGallery = Recipe(
        RecipeDefinition(
            identifier: "basic.gallery",
            name: "BASIC — TUIKit Gallery",
            language: "BASIC",
            summary: "Every TUIKit control, in eleven files that show IMPORT; compiled by basicc.",
            postNote: "created — build with: make (needs basicc; see the Makefile)"
        ),
        files: [
""")
    for name, text in files:
        out.write('            RecipeFile("src/%s", %s),\n' % (name, literal(text, 12)))
    out.write("""            RecipeFile("Makefile", basicMakefile),
            RecipeFile(".gitignore", basicGitignore),
        ]
    )
}
""")

print("gallery files: %d" % len(files))
print("  -> %s" % freebird_out)
print("  -> %s" % omega_out)
PYTHON
