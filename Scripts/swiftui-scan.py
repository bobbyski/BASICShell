#!/usr/bin/env python3
"""swiftui-scan.py — ACTIVEUI_TRANSITION.md's Category E scan.

For every type declared in a Swift file that imports SwiftUI, find its body by
brace matching and test whether it mentions any SwiftUI symbol. A type that
does not is a relocation candidate: it can move into framework-neutral code
without changing a line, because nothing in it is SwiftUI.

    Scripts/swiftui-scan.py [directory]     (default: BASICStudio's sources)

ActiveUI's own conversion record calls this the highest-value automation of
the whole exercise. It moved FreebirdStudio's portable share from 38% to 47%.

Why not count `import SwiftUI` lines? Every file in BASICStudio carries the
same copy-pasted import block, so an import proves nothing. This reads what
each type *uses*.

What counts as SwiftUI is the list below. `ObservableObject` and `@Published`
are Combine, not SwiftUI, so they are reported separately: a type using only
those is observable-but-neutral, which is exactly StudioModel's shape.
"""
import os
import re
import sys

SWIFTUI = [
    r"\bsome\s+View\b", r":\s*View\b", r"\bView\s*\{", r"@State\b", r"@Binding\b",
    r"@ObservedObject\b", r"@StateObject\b", r"@EnvironmentObject\b", r"@Environment\b",
    r"@AppStorage\b", r"\bBinding\s*<", r"@ViewBuilder\b", r"@FocusState\b", r"\bNSViewRepresentable\b",
    r"\bNSViewControllerRepresentable\b", r"\bNSHostingView\b", r"\bNSHostingController\b",
    r"\bWindowGroup\b", r"\bScene\b", r"\bCommandMenu\b", r"\bCommandGroup\b",
    r"\bCommands\b", r"\bVStack\b", r"\bHStack\b", r"\bZStack\b", r"\bLazyVStack\b",
    r"\bSpacer\s*\(", r"\bDivider\s*\(", r"\bText\s*\(", r"\bButton\s*\(", r"\bToggle\s*\(",
    r"\bPicker\s*\(", r"\bSlider\s*\(", r"\bStepper\s*\(", r"\bTextField\s*\(",
    r"\bForEach\b", r"\bList\s*[\(\{]", r"\bScrollView\b", r"\bGeometryReader\b",
    r"\bNavigationSplitView\b", r"\bTabView\b", r"\bForm\s*\{", r"\bSection\s*[\(\{]",
    r"\bGroupBox\b", r"\bLabel\s*\(", r"\bImage\s*\(", r"\bColor\b", r"\bFont\b",
    r"\bAnyView\b", r"\bEdgeInsets\b", r"\bPreviewProvider\b", r"#Preview\b",
    r"\.toolbar\b", r"\.sheet\b", r"\.alert\b", r"\.onAppear\b", r"\.onChange\b",
    r"\.frame\(", r"\.padding\((?!toLength)", r"\.font\(", r"\.foregroundStyle\(", r"\.background\(",
]
COMBINE = [r"\bObservableObject\b", r"@Published\b", r"\bobjectWillChange\b"]
DECLARATION = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|package|open|final|nonisolated)\s+)*"
    r"(class|struct|enum|extension|protocol|actor)\s+([A-Za-z_][\w.]*)"
)


def strip(text):
    """Code with comments and string literals blanked, lengths kept."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i)); i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", text[i:j])); i = j
        elif text.startswith('"""', i):
            j = text.find('"""', i + 3)
            j = n if j < 0 else j + 3
            out.append(re.sub(r"[^\n]", " ", text[i:j])); i = j
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] != '"' and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            out.append(" " * (j + 1 - i)); i = j + 1
        else:
            out.append(text[i]); i += 1
    return "".join(out)


def types_in(code, nested=False):
    """(kind, name, first line, last line, body) for each top-level type, or
    for each type one level inside `code` when `nested`."""
    if nested:
        # The body's own braces are not a level: drop them before scanning.
        open_brace = code.find("{")
        inner = code[open_brace + 1:code.rfind("}")]
        prefix = code.count("\n", 0, open_brace + 1)
        dedented = "\n".join(line[4:] if line.startswith("    ") else line for line in inner.split("\n"))
        return [(k, n, f + prefix, l + prefix, b) for k, n, f, l, b in types_in(dedented)]
    lines = code.split("\n")
    offsets, total = [], 0
    for line in lines:
        offsets.append(total); total += len(line) + 1
    found, depth, index = [], 0, 0
    while index < len(lines):
        line = lines[index]
        match = DECLARATION.match(line) if depth == 0 else None
        if match:
            start = offsets[index]
            brace = code.find("{", start)
            if brace >= 0:
                level, position = 0, brace
                while position < len(code):
                    if code[position] == "{": level += 1
                    elif code[position] == "}":
                        level -= 1
                        if level == 0: break
                    position += 1
                last = code.count("\n", 0, position)
                found.append((match.group(1), match.group(2), index + 1, last + 1, code[start:position + 1]))
                index = last + 1
                continue
        depth += line.count("{") - line.count("}")
        index += 1
    return found


def first_hit(body, patterns):
    for pattern in patterns:
        hit = re.search(pattern, body)
        if hit: return hit.group(0).strip()
    return None


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "BASICStudio", "Sources", "BASICStudio")
    rows, totals = [], {"swiftui": 0, "combine": 0, "neutral": 0}
    for directory, _, files in sorted(os.walk(root)):
        for name in sorted(files):
            if not name.endswith(".swift"): continue
            path = os.path.join(directory, name)
            text = open(path, encoding="utf-8").read()
            if not re.search(r"^\s*import\s+SwiftUI\b", text, re.M): continue
            for kind, type_name, first, last, body in types_in(strip(text)):
                size = last - first + 1
                swiftui = first_hit(body, SWIFTUI)
                combine = first_hit(body, COMBINE)
                pile = "swiftui" if swiftui else ("combine" if combine else "neutral")
                # A SwiftUI type may hold neutral types inside it — Monaco's
                # coordinator is most of its file. Those lines move out of
                # the SwiftUI pile and count on their own.
                if pile == "swiftui":
                    for inner_kind, inner_name, inner_first, inner_last, inner_body in types_in(body, nested=True):
                        if first_hit(inner_body, SWIFTUI): continue
                        inner_size = inner_last - inner_first + 1
                        inner_pile = "combine" if first_hit(inner_body, COMBINE) else "neutral"
                        size -= inner_size
                        totals[inner_pile] += inner_size
                        rows.append((os.path.relpath(path, root), f"  {inner_kind} {type_name}.{inner_name}",
                                     first + inner_first - 1, inner_size, inner_pile, ""))
                totals[pile] += size
                rows.append((os.path.relpath(path, root), f"{kind} {type_name}", first, size, pile, swiftui or combine or ""))
    width = max((len(r[0]) + len(r[1]) for r in rows), default=20) + 3
    print(f"{'type':<{width}} {'lines':>6}  verdict   first symbol")
    for path, declared, first, size, pile, symbol in rows:
        label = {"swiftui": "SwiftUI", "combine": "Combine", "neutral": "NEUTRAL"}[pile]
        print(f"{path + ': ' + declared:<{width}} {size:>6}  {label:<8}  {symbol}")
    whole = sum(totals.values()) or 1
    print()
    for pile, label in (("neutral", "Neutral: relocation candidates"), ("combine", "Combine only (observable, UI-neutral)"), ("swiftui", "Uses SwiftUI")):
        print(f"{label:<40} {totals[pile]:>6} lines  {100 * totals[pile] // whole:>3}%")


if __name__ == "__main__":
    main()
