#!/usr/bin/env python3
# check-async-tutorial.py — runs every step of the async tutorial in
# BASICShell, in a scratch folder, and checks each prints in the order the
# page shows. BASICStudio's side is a test (AsyncTutorialTests).
#
# BASICShell comes from PATH, or from BASICSHELL.
#
# Usage: Code/Scripts/check-async-tutorial.py
import os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(HERE, "..", "BASICStudio", "UserDocs", "TUTORIAL_ASYNC.md")
SHELL = os.environ.get("BASICSHELL") or shutil.which("BASICShell")
if not SHELL:
    sys.exit("check-async-tutorial: BASICShell is not on PATH — install it, or set BASICSHELL")

# Per program on the page, in order: what it must print, from the start.
# Step 7 needs the network, so either of its two outcomes will do.
EXPECTED = [
    ["Wait for it...\nTwo seconds later.\n"],
    ["Putting the kettle on.\nWhile it boils, getting out a cup.\nThe kettle has boiled.\nPouring the tea.\n"],
    ["Putting the kettle on, and the bread in the toaster.\nBoth are going. Setting the table.\n"
     "The toast has popped up.\nThe kettle has boiled.\nBreakfast: toast and tea.\n"],
    ["Just started: RUNNING\nWhile it boils: SUSPENDED\nOnce it has boiled: COMPLETED\nA second kettle, switched off: CANCELLED\n"],
    ["Carrying on without waiting.\nDing dong!\nDone.\n"],
    ["Wrote 10 bytes.\nThe list says:\nBread\nTea\n"],
    ["Asking for the page...\nStatus: 200\n", "Asking for the page...\nCould not fetch the page."],
    ["Inside the task, cups is 2\nCups poured: 0\n"],
]

source = open(PAGE, encoding="utf-8").read()
programs = re.findall(r"```basic\n(.*?)```", source, re.S)
if len(programs) != len(EXPECTED):
    sys.exit(f"check-async-tutorial: the page has {len(programs)} programs; this script knows {len(EXPECTED)}")

failed = 0
with tempfile.TemporaryDirectory() as folder:
    for number, (program, choices) in enumerate(zip(programs, EXPECTED), start=1):
        path = os.path.join(folder, f"program{number}.bas")
        with open(path, "w", encoding="utf-8") as file:
            file.write(program)
        result = subprocess.run([SHELL, os.path.basename(path)], cwd=folder, capture_output=True, text=True, timeout=60)
        ok = any(result.stdout.startswith(choice) for choice in choices)
        print(f"program {number}: " + ("ok" if ok else "FAILED, printed:\n" + result.stdout + result.stderr))
        failed += not ok
sys.exit(1 if failed else 0)
