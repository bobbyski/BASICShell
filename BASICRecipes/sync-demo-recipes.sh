#!/bin/sh
# Copies the demo projects that are also recipes into their recipe folders,
# then writes the catalog again. The demos are the originals: change the
# contact book or the gallery there, then run this.
#
#   Code/BASICRecipes/sync-demo-recipes.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
demos="$here/../basicPrograms/demos"
sync() { # sync <demo project> <recipe folder>
    rm -rf "$here/Recipes/$2/src"
    mkdir -p "$here/Recipes/$2/src"
    (cd "$demos/$1" && find . -name '*.bas' -not -path '*.build/*' | while read -r file; do
        mkdir -p "$here/Recipes/$2/src/$(dirname "$file")"
        cp "$file" "$here/Recipes/$2/src/$file"
    done)
}
sync apps/contacts.basproj 06-contacts
sync tui/gallery.basproj 07-gallery
cd "$here" && swift run basic-recipe-catalog
