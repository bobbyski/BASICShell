#!/bin/bash
# CIBuild-BASICStudio.sh — the release build of BASICStudio.app: Xcode (xcodebuild) on
# the package, output outside the source tree. What CodeBuilder's job runs.
#
#   Scripts/CIBuild-BASICStudio.sh [--output DIR]     default: ~/tmp/BASICStudio/CIBuild
#
# It changes nothing in the project: `swift run` in BASICStudio, and the committed
# BASICStudio.xcodeproj, work as they did. Named for the product rather than plain
# CIBuild.sh, the usual name elsewhere, because this repository builds several.
#
# **The package, not project.yml.** The spec describes an Xcode *application* target, and
# the sources reach their demos, fonts and UserDocs.zip through `Bundle.module` — which
# exists only for a SwiftPM target. Built from the spec, `Bundle.module` in
# UserDocumentationPane.swift resolves to SwiftTerm's internal one and the build stops
# ("'module' is inaccessible due to 'internal' protection level"). Built from the
# package, every target gets its own accessor, and Xcode's looks in Contents/Resources,
# where a signed app keeps its bundles — unlike the one `swift build` generates, which
# looks beside the executable and at the absolute build path of the Mac that built it.
#
# **Its dependencies are its own.** Unlike the ActiveUI apps, BASICStudio takes nothing
# from the Freebird staging: BASICCore and DocumentArchive sit beside it here, and
# SwiftTerm, VectorTerminalSDK and MarkdownUI are resolved by SwiftPM from their
# repositories, which needs the network.
#
# Signed ad-hoc here; CodeBuilder signs with Developer ID and notarizes.
set -euo pipefail
shopt -s nullglob

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/BASICStudio"
OUTPUT="$HOME/tmp/BASICStudio/CIBuild"
while [ $# -gt 0 ]; do
    case "$1" in
        --output) OUTPUT="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# **The project file is moved aside for the build, and put back afterwards.**
# `xcodebuild -scheme` in a directory holding a project builds *the project*, so pointing
# it at BASICStudio/ built the spec's app target — the thing this script exists to avoid.
# Copying the package elsewhere is not an option either: BASICCore names RichSwift,
# TUIKit, TUIBoards, TUIDiagram and CodeWatchLint by paths that climb out of this
# repository, and a copy at another depth cannot find any of them. So the project is
# moved for the duration and restored on the way out, however this script ends.
PROJECT="$PACKAGE/BASICStudio.xcodeproj"
ASIDE="$OUTPUT/BASICStudio.xcodeproj.aside"
restore() {
    if [ -d "$ASIDE" ] && [ ! -d "$PROJECT" ]; then
        rm -rf "$PROJECT"
        mv "$ASIDE" "$PROJECT"
    fi
}
trap restore EXIT INT TERM
if [ -d "$PROJECT" ]; then
    mkdir -p "$OUTPUT"
    rm -rf "$ASIDE"
    mv "$PROJECT" "$ASIDE"
fi

DERIVED="$OUTPUT/DerivedData"
PRODUCTS="$DERIVED/Build/Products/Release"
echo "Building BASICStudio (Release) with xcodebuild…"
(cd "$PACKAGE" && /usr/bin/xcodebuild build -scheme BASICStudio -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
    SYMROOT="$DERIVED/Build/Products" OBJROOT="$DERIVED/Build/Intermediates.noindex" \
    -skipMacroValidation -skipPackagePluginValidation CLANG_COVERAGE_MAPPING=NO \
    SWIFT_SUPPRESS_WARNINGS=NO CODE_SIGNING_ALLOWED=NO ARCHS=arm64 \
    LD_RUNPATH_SEARCH_PATHS='@executable_path/../Frameworks' -quiet)
# xcodebuild deletes a tracked Package.resolved it does not need; put any back.
git -C "$ROOT" checkout -- $(git -C "$ROOT" ls-files --deleted -- '*Package.resolved') 2>/dev/null || true

# The bundle. The package builds an executable, so the app is assembled here, with the
# version settings the spec carries so the two describe one app.
setting() { /usr/bin/sed -n "s/^ *$1: \"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$ROOT/BASICStudio/project.yml" | head -1; }
APP="$OUTPUT/BASICStudio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$PRODUCTS/BASICStudio" "$APP/Contents/MacOS/BASICStudio"
for icon in "$ROOT"/BASICStudio/Sources/BASICStudio/Resources/AppIcon.icns "$ROOT"/BASICStudio/Sources/BASICStudio/Resources/Assets/AppIcon.icns; do
    [ -f "$icon" ] && cp "$icon" "$APP/Contents/Resources/AppIcon.icns" && break
done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>BASICStudio</string>
<key>CFBundleDisplayName</key><string>BASICStudio</string>
<key>CFBundleIdentifier</key><string>$(setting PRODUCT_BUNDLE_IDENTIFIER)</string>
<key>CFBundleExecutable</key><string>BASICStudio</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$(setting MARKETING_VERSION)</string>
<key>CFBundleVersion</key><string>$(git -C "$ROOT" rev-list --count HEAD)</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>LSMinimumSystemVersion</key><string>16.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# Resource bundles, where Xcode's accessor looks for them.
for bundle in "$PRODUCTS"/*.bundle; do
    /usr/bin/ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done
# Every dynamic product the app loads, and every one those load, each once: an app that
# leaves one in the build folder runs here and nowhere else.
for framework in "$PRODUCTS"/PackageFrameworks/*.framework; do
    /usr/bin/ditto "$framework" "$APP/Contents/Frameworks/$(basename "$framework")"
done
for library in "$PRODUCTS"/*.dylib; do
    cp -f "$library" "$APP/Contents/Frameworks/$(basename "$library")"
done
install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/BASICStudio" 2>/dev/null || true

missing=
for loaded in $(otool -L "$APP/Contents/MacOS/BASICStudio" | sed -n 's|^[[:space:]]*@rpath/\([^ ]*\) (.*|\1|p'); do
    name="${loaded%%/*}"
    case "$name" in libswift*) continue ;; esac
    [ -e "$APP/Contents/Frameworks/$name" ] || missing="$missing $name"
done
[ -z "$missing" ] || { echo "error: BASICStudio loads, but does not carry:$missing" >&2; exit 1; }

# Ad-hoc, inside out.
for item in "$APP"/Contents/Frameworks/*; do codesign --force --sign - "$item"; done
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
