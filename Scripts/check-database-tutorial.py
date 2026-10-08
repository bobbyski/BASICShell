#!/usr/bin/env python3
# check-database-tutorial.py — runs every step of the database tutorial in
# BASICShell, in order, in a scratch folder, answering each INPUT as the page
# tells the reader to, and checks each step prints what the page says.
#
# BASICStudio's side is a test (DatabaseTutorialTests); BASICShell has no test
# target, hence a script. BASICShell comes from PATH, or from BASICSHELL.
#
# Usage: Code/Scripts/check-database-tutorial.py
import os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(HERE, "..", "BASICStudio", "UserDocs", "TUTORIAL_DATABASE.md")
SHELL = os.environ.get("BASICSHELL") or shutil.which("BASICShell")
if not SHELL:
    sys.exit("check-database-tutorial: BASICShell is not on PATH — install it, or set BASICSHELL")

# Per run, in order: the step (counting from 1), what is typed, and text that
# must appear. Step 2 runs twice, and so do 5 and 7.
RUNS = [
    (1, "", ["The reading list is ready."]),
    (2, "", ["Books in the list: 1"]),
    (2, "", ["Books in the list: 2"]),
    (3, "", ["1815  Emma, by Jane Austen\n1815  Emma, by Jane Austen\n"]),
    (4, "Pride and Prejudice\nJane Austen\n1813\nDune\nFrank Herbert\n1965\n\n",
     ["1813  Pride and Prejudice, by Jane Austen\n1815  Emma, by Jane Austen\n1815  Emma, by Jane Austen\n1965  Dune, by Frank Herbert\n"]),
    (5, "Jane Austen\n", ["1813  Pride and Prejudice\n1815  Emma\n1815  Emma\n"]),
    (5, "Ada Lovelace\n", ["Nothing by Ada Lovelace in the list."]),
    (6, "Emma\nDune\n1966\n", ["Took out 2 books.", "Changed 1 books.", "1813  Pride and Prejudice, by Jane Austen\n1966  Dune, by Frank Herbert\n"]),
    (7, "", ["Saved Emma as book number 1", "Books on the shelf: 1"]),
    (7, "", ["Saved Emma as book number 2", "Books on the shelf: 2"]),
]

source = open(PAGE, encoding="utf-8").read()
steps = [block for block in re.findall(r"```basic\n(.*?)```", source, re.S) if "SqlDatabase(" in block]
if len(steps) != 7:
    sys.exit(f"check-database-tutorial: the page has {len(steps)} steps; this script knows 7")

failed = 0
with tempfile.TemporaryDirectory() as folder:
    for number, typed, expected in RUNS:
        path = os.path.join(folder, f"step{number}.bas")
        with open(path, "w", encoding="utf-8") as file:
            file.write(steps[number - 1])
        result = subprocess.run([SHELL, os.path.basename(path)], cwd=folder, input=typed,
                                capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        missing = [text for text in expected if text not in output]
        print(f"step {number}: " + ("ok" if not missing and result.returncode == 0 else f"FAILED (exit {result.returncode}) missing {missing}"))
        failed += bool(missing) or result.returncode != 0
    # Starting over, as the page says: the file goes.
    subprocess.run([SHELL], cwd=folder, input='File.Rm "books.sqlite"\n', capture_output=True, text=True,
                   timeout=30, env={**os.environ, "HOME": folder})
    gone = not os.path.exists(os.path.join(folder, "books.sqlite"))
    print("starting over: " + ("ok" if gone else "FAILED: books.sqlite is still there"))
    failed += not gone
sys.exit(1 if failed else 0)
