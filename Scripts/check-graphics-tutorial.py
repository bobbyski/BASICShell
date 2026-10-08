#!/usr/bin/env python3
# check-graphics-tutorial.py — runs every step of the graphics tutorial in
# BASICShell, in a pseudo-terminal that answers the way a VTG terminal (such
# as VGTerm) does, pressing the keys and clicking the buttons the page tells
# the reader to, and checks each step draws and answers what the page says.
#
# What a step draws is read from the VTG commands BASICShell sends; a click is
# sent back as the terminal would send it, naming the hit region it landed in.
# Words drawn with vectorPrint are read back by matching each letter's strokes
# against the alphabet, drawn once first.
#
# BASICStudio's side is a test (GraphicsTutorialTests); BASICShell has no test
# target and a graphics program needs a terminal, hence a script. BASICShell
# comes from PATH, or from BASICSHELL.
#
# Usage: Code/Scripts/check-graphics-tutorial.py
import fcntl, os, pty, re, select, shutil, struct, sys, tempfile, termios, time

HERE = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(HERE, "..", "BASICStudio", "UserDocs", "TUTORIAL_GRAPHICS.md")
SHELL = os.environ.get("BASICSHELL") or shutil.which("BASICShell")
if not SHELL:
    sys.exit("check-graphics-tutorial: BASICShell is not on PATH — install it, or set BASICSHELL")

APC = re.compile(rb"\x1b_VTG;([^\x1b]*)\x1b\\")
ANSWERS = {
    "capabilities": "capabilities,version=1",
    "canvas": "canvas,width=1000,height=700",
    "currentCanvas": "currentCanvas,width=1000,height=700",
    "size": "size,width=1000,height=700",
    "glyphSize": "glyphSize,character=W,width=10,height=20",
    "graphicsVisible": "graphicsVisible,visible=1",
}


class Terminal:
    """One BASICShell program, in a pseudo-terminal that draws."""

    def __init__(self, folder, source):
        path = os.path.join(folder, "program.bas")
        with open(path, "w", encoding="utf-8") as file:
            file.write(source)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(folder)
            os.environ["TERM"] = "xterm-256color"
            os.execv(SHELL, [SHELL, "program.bas"])
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 35, 100, 1000, 700))
        self.pending = b""
        self.stream = ""
        self.text = ""
        self.shapes = {}
        self.hits = {}
        self.status = None

    def pump(self, seconds=0.05):
        end = time.time() + seconds
        while time.time() < end and self.status is None:
            ready, _, _ = select.select([self.fd], [], [], 0.02)
            if ready:
                try:
                    data = os.read(self.fd, 65536)
                except OSError:
                    data = b""
                if data:
                    self.take(data)
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.status = os.waitstatus_to_exitcode(status)

    def take(self, data):
        self.pending += data
        while True:
            match = APC.search(self.pending)
            if not match:
                break
            self.text += self.pending[:match.start()].decode(errors="replace")
            self.apply(match.group(1).decode(errors="replace"))
            self.pending = self.pending[match.end():]
        # Text after the last command is text too, unless a command has begun.
        start = self.pending.find(b"\x1b_")
        cut = len(self.pending) if start < 0 else start
        self.text += self.pending[:cut].decode(errors="replace")
        self.pending = self.pending[cut:]

    def apply(self, command):
        self.stream += command + "\n"
        head = command.split(";", 1)[0]
        name = head.split(",", 1)[0]
        fields = dict(part.split("=", 1) for part in head.split(",")[1:] if "=" in part)
        if name.endswith("?"):
            answer = ANSWERS.get(name[:-1], name[:-1])
            os.write(self.fd, b"\x1b_VTG;" + answer.encode() + b"\x1b\\")
        elif name == "clear":
            self.shapes.clear()
        elif name == "delete":
            self.shapes.pop(fields.get("id"), None)
        elif name == "hit":
            self.hits[fields["id"]] = fields
        elif "id" in fields:
            self.shapes[fields["id"]] = command

    def until(self, what, condition, seconds=10):
        end = time.time() + seconds
        while not condition():
            if time.time() > end or self.status is not None:
                raise AssertionError(f"gave up waiting for {what}")
            self.pump()

    def key(self, key):
        os.write(self.fd, key.encode())
        self.pump(0.2)

    def click(self, id):
        region = self.hits[id]
        x = int(region["x"]) + int(region["w"]) // 2
        y = int(region["y"]) + int(region["h"]) // 2
        for kind in ("down", "up"):
            os.write(self.fd, f"\x1b_VTG;mouse,type={kind},button=0,x={x},y={y},hit={id}\x1b\\".encode())
            self.pump(0.05)

    def press(self, id):
        """Clicks a calculator button and waits for its display to be drawn again."""
        drawn = self.stream.count("draw,id=number-0-0,")
        self.click(id)
        self.until(f"the display after {id}", lambda: self.stream.count("draw,id=number-0-0,") > drawn)

    def letters(self, id):
        """The strokes of each letter vectorPrint drew under id: it names them id-letter-stroke."""
        found = {}
        for name, command in self.shapes.items():
            match = re.fullmatch(re.escape(id) + r"-(\d+)-(\d+)", name)
            if match:
                points = [tuple(map(int, point.split(","))) for point in command.split(";", 1)[1].split()]
                found.setdefault(int(match.group(1)), {})[int(match.group(2))] = points
        return [[found[letter][stroke] for stroke in sorted(found[letter])] for letter in sorted(found)]

    def read(self, id):
        return "".join(ALPHABET.get(signature(letter), "?") for letter in self.letters(id)).upper()

    def finish(self):
        """Presses a key: the program ends, cleanly, with its board cleared."""
        self.key("q")
        end = time.time() + 10
        while self.status is None and time.time() < end:
            self.pump()
        assert self.status == 0, f"the program ended with {self.status}: {self.text[-300:]}"
        assert not self.shapes, f"the board is not clear: {sorted(self.shapes)}"
        assert "error" not in self.text.lower(), self.text[-300:]

    def close(self):
        if self.status is None:
            os.kill(self.pid, 9)
            os.waitpid(self.pid, 0)
        os.close(self.fd)


def signature(letter):
    """A letter's strokes, measured from its first point: the same wherever it is drawn."""
    if not letter:
        return ""
    ox, oy = letter[0][0]
    return "|".join(" ".join(f"{x - ox},{y - oy}" for x, y in stroke) for stroke in letter)


ALPHABET = {}


def learn_alphabet(folder):
    every = "".join(chr(c) for c in range(33, 127))
    terminal = Terminal(folder, """all$ = ""
FOR c = 33 TO 126
    all$ = all$ + CHR$(c)
NEXT c
vtg = VectorTerminal()
vtg.vectorPrint("big", 0, 0, 21, all$, "#ffffff", 2)
vtg.vectorPrint("small", 0, 100, 14, all$, "#ffffff", 1)
key$ = INPUT$(1)
""")
    try:
        terminal.until("the alphabet", lambda: len(terminal.letters("small")) == len(every))
        for id in ("big", "small"):
            for character, letter in zip(every, terminal.letters(id)):
                ALPHABET.setdefault(signature(letter), character)  # capitals before lowercase
    finally:
        terminal.close()


def step1(t):
    t.until("the circle", lambda: "circle," in t.stream)
    assert "Press any key to finish." in t.text
    for line in ("x1=40,y1=60,x2=240,y2=60", "x1=240,y1=60,x2=240,y2=180", "x1=240,y1=180,x2=40,y2=180", "x1=40,y1=180,x2=40,y2=60"):
        assert any(s.startswith("line,") and line in s for s in t.shapes.values()), line
    assert any(s.startswith("circle,") and "cx=140,cy=120,r=40" in s for s in t.shapes.values())


def step2(t):
    t.until("the ball", lambda: "ball" in t.shapes)
    assert "rect,id=box,x=40,y=60,w=200,h=120,stroke=#22c55e,fill=#0f172a,width=2" in t.shapes["box"]
    assert "cx=140,cy=120,r=40,stroke=#60a5fa,fill=#60a5fa" in t.shapes["ball"]


def step3(t):
    for x in (80, 120, 160, 200):
        t.until(f"the ball at {x}", lambda: f"cx={x}," in t.shapes.get("ball", ""))
        assert sorted(t.shapes) == ["ball", "box"], sorted(t.shapes)
        t.key("m")
    t.until("the ball to go", lambda: "The ball has gone." in t.text)
    assert sorted(t.shapes) == ["box"]


def step4(t):
    t.until("the hit region", lambda: "button-hit" in t.hits)
    assert t.read("caption") == "PRESSME", t.read("caption")
    region = t.hits["button-hit"]
    assert (region["x"], region["y"], region["w"], region["h"]) == ("40", "60", "200", "60")


def step5(t):
    t.until("the program to listen", lambda: "mouseEvents,enabled=1" in t.stream)
    for count in (1, 2):
        t.click("button-hit")
        t.until(f"Clicks: {count}", lambda: t.read("count") == f"CLICKS:{count}")


def step6(t):
    t.until("the program to listen", lambda: "mouseEvents,enabled=1" in t.stream and len(t.hits) == 11)
    assert t.read("number") == "0"
    for key, shown in (("key1", "1"), ("key2", "12"), ("key3", "123"), ("keyC", "0"), ("key7", "7")):
        t.press(key)
        assert t.read("number") == shown, f"{shown} after {key}, not {t.read('number')}"


def step7(t):
    t.until("the program to listen", lambda: "mouseEvents,enabled=1" in t.stream and len(t.hits) == 16)
    for key, shown in (("key1", "1"), ("key2", "12"), ("plus", "12"), ("key3", "3"), ("times", "15"),
                       ("key2", "2"), ("equals", "30"), ("divide", "30"), ("key4", "4"), ("equals", "7.5"),
                       ("minus", "7.5"), ("key9", "9"), ("equals", "-1.5")):
        t.press(key)
        assert t.read("number") == shown, f"{shown} after {key}, not {t.read('number')}"


source = open(PAGE, encoding="utf-8").read()
steps = re.findall(r"```basic\n(.*?)```", source, re.S)
checks = [step1, step2, step3, step4, step5, step6, step7]
if len(steps) != len(checks):
    sys.exit(f"check-graphics-tutorial: the page has {len(steps)} steps; this script knows {len(checks)}")

failed = 0
with tempfile.TemporaryDirectory() as folder:
    learn_alphabet(folder)
    for number, (program, check) in enumerate(zip(steps, checks), start=1):
        terminal = Terminal(folder, program)
        try:
            check(terminal)
            terminal.finish()
            print(f"step {number}: ok")
        except (AssertionError, KeyError) as problem:
            print(f"step {number}: FAILED: {problem}")
            failed += 1
        finally:
            terminal.close()
sys.exit(1 if failed else 0)
