#!/usr/bin/env python3
# check-tuikit-tutorial.py — runs every step of the TUIKit tutorial in
# BASICShell, in a pseudo-terminal, pressing the keys the tutorial tells the
# reader to press, and checks each step ends the way the page says.
#
# BASICStudio's side is a test (TUIKitTutorialTests); BASICShell has no test
# target and a TUIKit program needs a terminal, hence a script.
#
# BASICShell comes from PATH, or from BASICSHELL. No build directory is
# written down here: that would be a guess about somebody's machine.
#
# Usage: Code/Scripts/check-tuikit-tutorial.py
import fcntl, os, pty, re, select, shutil, struct, sys, tempfile, termios, time

HERE = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(HERE, "..", "BASICStudio", "UserDocs", "TUTORIAL_TUIKIT.md")
SHELL = os.environ.get("BASICSHELL") or shutil.which("BASICShell")
if not SHELL:
    sys.exit("check-tuikit-tutorial: BASICShell is not on PATH — install it, or set BASICSHELL")

TAB, RETURN, ESC = "\t", "\r", "\x1b"
# Per step: the keys the tutorial says to press, and text that must appear.
STEPS = [
    ([ESC], ["The program has ended."]),
    ([ESC + "f", "q"], ["The program has ended."]),
    ([ESC], ["Esc quits", "The program has ended."]),
    ([ESC, ESC], ["Press the button.", "The program has ended."]),
    ([TAB, RETURN, ESC, ESC], ["Hello from BASIC.", "The program has ended."]),
    ([TAB, "Ada", TAB, RETURN, ESC, ESC], ["Hello, Ada.", "The program has ended."]),
]

def run(program, keys):
    """The program's whole output, with the terminal's escape codes removed."""
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execv(SHELL, [SHELL, program])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    out = b""

    def read_for(seconds):
        nonlocal out
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.05)
            if ready:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    return
                if not data:
                    return
                out += data

    read_for(2.0)
    for key in keys:
        os.write(fd, key.encode())
        read_for(0.8)
    read_for(1.5)
    try:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
    except (ProcessLookupError, ChildProcessError):
        pass
    plain = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][A-Z0-9]|\x1b_[^\x1b]*\x1b\\\\", b"", out)
    return plain.decode("utf-8", "replace")

source = open(PAGE, encoding="utf-8").read()
programs = [block for block in re.findall(r"```basic\n(.*?)```", source, re.S) if block.strip().endswith("Main()")]
if len(programs) != len(STEPS):
    sys.exit(f"check-tuikit-tutorial: the page has {len(programs)} steps; this script knows {len(STEPS)}")

failed = 0
with tempfile.TemporaryDirectory() as scratch:
    for number, (program, (keys, expected)) in enumerate(zip(programs, STEPS), start=1):
        path = os.path.join(scratch, f"step{number}.bas")
        with open(path, "w", encoding="utf-8") as file:
            file.write(program)
        output = run(path, keys)
        missing = [text for text in expected if text not in output]
        print(f"step {number}: " + ("ok" if not missing else "MISSING " + ", ".join(missing)))
        failed += bool(missing)
sys.exit(1 if failed else 0)
