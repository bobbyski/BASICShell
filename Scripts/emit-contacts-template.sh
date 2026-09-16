#!/bin/bash
#
# emit-contacts-template.sh — turn the contact book into project templates.
#
# The contact book in basicPrograms/demos/contacts is the reference for how
# to WRITE BASIC: six files, no GOTO, a model that knows nothing about the
# screen, and a JSON file it opens and saves. Both IDEs offer it as a
# starter project, which means both need the source inside them — neither
# can assume this repository is on the machine.
#
# So it is copied, and copying is what this script exists to make safe. The
# Swift it writes is generated, never edited: change a contact-book file,
# run this, and both copies are exactly the contact book again. Editing the
# generated file by hand puts the copy and the original quietly out of step,
# which is the whole failure this is meant to prevent.
#
# The sibling of emit-gallery-template.sh, deliberately alike: two starters,
# two scripts, one shape, rather than one script with a mode switch.
#
# Usage:
#   Code/Scripts/emit-contacts-template.sh
#   FREEBIRD=/path/to/SwiftyTextEditor OMEGA=/path/to/OmegaCLIDE Code/Scripts/emit-contacts-template.sh

set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$PWD"
SOURCE="$ROOT/basicPrograms/demos/contacts"

FREEBIRD="${FREEBIRD:-/Users/bobby/AIResearch/SwiftyTextEditor}"
OMEGA="${OMEGA:-/Users/bobby/AIResearch/OmegaCLIDE}"

FREEBIRD_OUT="$FREEBIRD/Code/ProjectGenerator/Sources/ProjectGenerator/BASICContactsTemplate.swift"
OMEGA_OUT="$OMEGA/Code/OmegaCLIDE/Sources/IDECore/Recipes/Recipes+BASICContacts.swift"

[ -d "$SOURCE" ] || { echo "emit-contacts-template: no contact book at $SOURCE" >&2; exit 1; }

# Reading order, not alphabetical order: main.bas explains the program and
# names the rest, and each file after it is the next thing to understand.
# Both IDEs list the files in the order they are written, so this is the
# order a person meets them in.
FILES=(
    "main.bas"
    "ContactModel.bas"
    "ContactStorage.bas"
    "ContactWindow.bas"
    "ContactApp.bas"
    "ContactDialogs.bas"
)

# Every .bas in the directory has to be in that list. A file added to the
# contact book and not to this one would be left out of both IDEs, and the
# starter would half-work in a way nobody would connect to this script.
for path in "$SOURCE"/*.bas; do
    name="$(basename "$path")"
    listed=0
    for known in "${FILES[@]}"; do
        [ "$known" = "$name" ] && listed=1
    done
    [ "$listed" = 1 ] || { echo "emit-contacts-template: $name is not in FILES; add it in reading order" >&2; exit 1; }
done

for name in "${FILES[@]}"; do
    [ -f "$SOURCE/$name" ] || { echo "emit-contacts-template: $name is listed but missing" >&2; exit 1; }
done

# A raw Swift literal (#"""…"""#) takes the BASIC through untouched: no
# backslash escapes and no \( interpolation, which BASIC source is full of.
# Checked rather than assumed, because a delimiter collision would produce
# Swift that does not compile and BASIC that is silently wrong.
for name in "${FILES[@]}"; do
    if grep -q '"""#' "$SOURCE/$name"; then
        echo "emit-contacts-template: $name contains the raw-string delimiter; widen it" >&2
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
//  Written by Code/Scripts/emit-contacts-template.sh in the AIBasic repo from
//  basicPrograms/demos/contacts, which is the original. Change a contact-book
//  file there and run that script; edits made here are lost the next time it
//  runs and, until then, are a copy that no longer matches what it copies.
//
"""

summary = "A contact book on TUIKit in six files: JSON save and load, menus, toolbar, and an unsaved-changes dialog."

with open(freebird_out, "w", encoding="utf-8") as out:
    out.write(banner.format(basename=os.path.basename(freebird_out)))
    out.write("""
/// The contact book's source, one entry per file.
///
/// Written into a generated project's `src/`, where `main.bas` IMPORTs the
/// rest by name — which is why they land in one directory and why `main.bas`
/// is first.
enum BASICContactsTemplate {

    /// Every file of the contact book, in reading order.
    static let files: [(name: String, contents: String)] = [
""")
    for name, text in files:
        out.write('        ("%s", %s),\n' % (name, literal(text, 8)))
    out.write("    ]\n}\n")

with open(omega_out, "w", encoding="utf-8") as out:
    out.write(banner.format(basename=os.path.basename(omega_out)))
    out.write("""
/// The contact book as a project you can make and change.
///
/// The same six files FreebirdStudio's `BASICProjectGenerator` writes, so the
/// contact book is the same project wherever it was born.
extension BuiltInRecipes {

    static let basicContacts = Recipe(
        RecipeDefinition(
            identifier: "basic.contacts",
            name: "BASIC — Contact Book",
            language: "BASIC",
            summary: "%s",
            postNote: "created — build with: make (needs basicc; see the Makefile)"
        ),
        files: [
""" % summary)
    for name, text in files:
        out.write('            RecipeFile("src/%s", %s),\n' % (name, literal(text, 12)))
    out.write("""            RecipeFile("Makefile", basicMakefile),
            RecipeFile(".gitignore", basicGitignore),
        ]
    )
}
""")

print("contact book files: %d" % len(files))
print("  -> %s" % freebird_out)
print("  -> %s" % omega_out)
PYTHON
