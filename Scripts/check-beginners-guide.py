#!/usr/bin/env python3
# check-beginners-guide.py — runs every example in the Beginner's Guide in
# BASICShell, as a reader does: the one-liners typed at the prompt, the
# programs loaded and RUN, each INPUT answered when it asks, Guess the Number
# played to the end by halving, and each mistake to try made and checked for
# the message the page quotes. One interactive BASICShell, in a pseudo-
# terminal, with a scratch folder for HOME and for the program files.
#
# BASICStudio's side is a test (BeginnersGuideTests). BASICShell comes from
# PATH, or from BASICSHELL.
#
# Usage: Code/Scripts/check-beginners-guide.py
import fcntl, os, pty, re, select, shutil, struct, sys, tempfile, termios, time

HERE = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(HERE, "..", "BASICStudio", "UserDocs", "TUTORIAL_BEGINNERS.md")
SHELL = os.environ.get("BASICSHELL") or shutil.which("BASICShell")
if not SHELL:
    sys.exit("check-beginners-guide: BASICShell is not on PATH — install it, or set BASICSHELL")
SHELL = os.path.abspath(SHELL)
ESCAPES = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b_[^\x1b]*\x1b\\|\x1b[()][A-Z0-9]|\x1b[=>]")
READY = re.compile(r"Ready\W*$")


class Shell:
    """An interactive BASICShell in a pseudo-terminal."""

    def __init__(self, folder):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(folder)
            os.execve(SHELL, [SHELL], {"HOME": folder, "TERM": "xterm-256color", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
        self.raw = ""
        self.status = None
        self.until("the prompt", self.ready)

    @property
    def text(self):
        return ESCAPES.sub("", self.raw).replace("\r", "")

    def ready(self, since=0):
        """Whether the screen, from `since` on, ends at the prompt. The prompt
        has a symbol after its Ready, hence the \\W*."""
        return READY.search(self.text[since:].rstrip().rsplit("\n", 1)[-1]) is not None

    def pump(self, seconds=0.05):
        end = time.time() + seconds
        while time.time() < end and self.status is None:
            ready, _, _ = select.select([self.fd], [], [], 0.02)
            if ready:
                try:
                    self.raw += os.read(self.fd, 65536).decode(errors="replace")
                except OSError:
                    pass
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.status = os.waitstatus_to_exitcode(status)

    def until(self, what, condition, seconds=20):
        end = time.time() + seconds
        while not condition():
            if time.time() > end or self.status is not None:
                raise AssertionError(f"gave up waiting for {what}; the screen ends:\n{self.text[-400:]}")
            self.pump()

    def type(self, line):
        os.write(self.fd, (line + "\r").encode())

    def say(self, line):
        """Types a line at the prompt and answers what it printed, once the prompt is back."""
        start = len(self.text)
        self.type(line)
        self.until(f"the answer to {line!r}", lambda: "\n" in self.text[start:] and self.ready(start))
        return self.text[start:]

    def answer(self, question, line):
        """Waits for a program's question, then types the answer."""
        self.until(f"the question {question!r}", lambda: self.text.endswith(question))
        self.type(line)

    def finish(self, start):
        self.until("the program to end", lambda: self.ready(start))
        return self.text[start:]

    def close(self):
        if self.status is None:
            self.type("QUIT")
            self.pump(1)
        if self.status is None:
            os.kill(self.pid, 9)
            os.waitpid(self.pid, 0)
        os.close(self.fd)


source = open(PAGE, encoding="utf-8").read()
examples = re.findall(r"```basic\n(.*?)```", source, re.S)
if len(examples) != 13:
    sys.exit(f"check-beginners-guide: the page has {len(examples)} examples; this script knows 13")

failures = 0


def check(name, body):
    global failures
    try:
        body()
        print(f"{name}: ok")
    except AssertionError as problem:
        print(f"{name}: FAILED: {problem}")
        failures += 1


with tempfile.TemporaryDirectory() as folder:
    shell = Shell(folder)

    def program(text, answers=(), name="program.bas"):
        """Loads and runs `text`, answering each (question, line); answers what it printed."""
        with open(os.path.join(folder, name), "w", encoding="utf-8") as file:
            file.write(text)
        shell.say(f'load "{name}"')
        start = len(shell.text)
        shell.type("run")
        for question, line in answers:
            shell.answer(question, line)
        return shell.finish(start)

    def expect(printed, *texts):
        for text in texts:
            assert text in printed, f"{text!r} is not in what it printed:\n{printed}"

    def changed(index, old, new):
        assert old in examples[index], f"example {index} has no {old!r}"
        return examples[index].replace(old, new)

    def say_hello():
        expect(shell.say(examples[0].strip()), "\nHello, world!\n")
        expect(shell.say(examples[1].strip()), "\n14\n")
        expect(shell.say("print (2 + 3) * 4"), "\n20\n")

    def programs():
        for index, output in [(2, "Hello!\nThis is my first program.\n2 + 2 =4\n"),
                              (3, "Ada is 36 years old.\nNext year Ada will be 37\n"),
                              (7, "1 squared is 1\n2 squared is 4\n3 squared is 9\n4 squared is 16\n5 squared is 25\n"),
                              (8, "3...\n2...\n1...\nLiftoff!\n"),
                              (9, "0: apple\n1: banana\n2: cherry\n"),
                              (10, "42\nHello, Ada!\nHello, Grace!\n"),
                              (11, "\n12\n")]:
            assert "```text\n" + output.lstrip("\n") + "```" in source, f"the page does not show {output!r}"
            expect(program(examples[index]), output)

    def joining():
        program(examples[3])
        expect(shell.say(examples[4].strip()), "\nHello, Ada!\n")

    def questions():
        expect(program(examples[5], [("What is your name? ", "Grace")]), "Hello, Grace!\n")
        expect(program(examples[6], [("How old are you? ", "20")]), "You can vote.\n")
        expect(program(examples[6], [("How old are you? ", "12")]), "Not old enough to vote yet.\n")

    def guess_the_number():
        with open(os.path.join(folder, "guess.bas"), "w", encoding="utf-8") as file:
            file.write(examples[12])
        shell.say('load "guess.bas"')
        start = len(shell.text)
        shell.type("run")
        low, high, tries = 1, 100, 0
        while True:
            guess = (low + high) // 2
            shell.answer("Your guess? ", str(guess))
            tries += 1
            mark = len(shell.text)
            shell.until(f"an answer to {guess}", lambda: any(word in shell.text[mark:] for word in ("Higher!", "Lower!", "You got it in")))
            said = shell.text[mark:]
            if "You got it in" in said:
                break
            if "Higher!" in said:
                low = guess + 1
            else:
                high = guess - 1
            assert tries < 7, "halving finds any number from 1 to 100 in seven tries"
        printed = shell.finish(start)
        expect(printed, "I'm thinking of a number from 1 to 100.\n", f"You got it in {tries} tries!")

    def syntax_errors():
        quote = program(changed(2, 'print "Hello!"\n', 'print "Hello!\n'))
        expect(quote, "Line 1, column 7: Syntax error: Unterminated string")
        assert "This is my first program." not in quote
        expect(program(changed(2, 'print "This is my first program."', 'pirnt "This is my first program."')),
               "Line 2, column 7: Syntax error: Expected =")
        assert "Line 1, column 7: Syntax error: Unterminated string" in source

    def no_next():
        printed = program(changed(7, "next i\n", ""))
        expect(printed, "1 squared is 1\n")
        assert "2 squared" not in printed and "error" not in printed.lower(), printed

    def endless():
        with open(os.path.join(folder, "endless.bas"), "w", encoding="utf-8") as file:
            file.write(changed(8, "    count = count - 1\n", ""))
        shell.say('load "endless.bas"')
        start = len(shell.text)
        shell.type("run")
        shell.until("the loop to go round", lambda: shell.text[start:].count("3...") > 10)
        os.write(shell.fd, b"\x03")
        printed = shell.finish(start)
        assert re.search(r"3\.\.\.\nBreak at [234]\n", printed), printed[-200:]

    def past_the_end():
        expect(program(changed(9, "for i = 0 to 2", "for i = 0 to 3")),
               "0: apple\n1: banana\n2: cherry\n", "Runtime error: fruit$ subscript out of range at 6")

    def type_errors():
        expect(program(changed(10, "print Double(21)", "print Double(2.5)")),
               "Type error: Cannot assign non-integer value to n at 1")
        expect(program(changed(10, "print Double(21)", "Greet(42)")), "Cannot assign non-string value to who")

    try:
        for name, body in [("say hello", say_hello), ("the programs", programs), ("joining strings", joining),
                           ("questions and decisions", questions), ("guess the number", guess_the_number),
                           ("mistakes: quote and PRINT", syntax_errors), ("mistake: no NEXT", no_next),
                           ("mistake: endless WHILE", endless), ("mistake: past the end", past_the_end),
                           ("mistakes: wrong kinds", type_errors)]:
            check(name, body)
    finally:
        shell.close()

sys.exit(1 if failures else 0)
