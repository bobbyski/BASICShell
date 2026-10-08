#!/usr/bin/env python3
# check-basicrc-tutorial.py — follows the BASICrc tutorial in BASICShell with
# a scratch home folder: types what the page tells the reader to type, writes
# each version of the startup file the page shows, starts a new shell after
# each, and checks the shell answers what the page says. The first version is
# typed into nano, as the reader does; the rest are written straight in.
#
# HOME points at the scratch folder, so nothing here reads or writes your own
# ~/.BASICrc. BASICShell comes from PATH, or from BASICSHELL; the page's
# `#!/usr/bin/env basicshell` line finds whichever `basicshell` the system's
# shell finds first.
#
# Usage: Code/Scripts/check-basicrc-tutorial.py
import os, pty, re, select, shutil, stat, struct, sys, tempfile, termios, time, fcntl

HERE = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(HERE, "..", "BASICStudio", "UserDocs", "TUTORIAL_BASICRC.md")
SHELL = os.environ.get("BASICSHELL") or shutil.which("BASICShell")
if not SHELL:
    sys.exit("check-basicrc-tutorial: BASICShell is not on PATH — install it, or set BASICSHELL")
SHELL = os.path.abspath(SHELL)
ESCAPES = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b_[^\x1b]*\x1b\\|\x1b[()][A-Z0-9]|\x1b[=>]")


class Shell:
    """One BASICShell, in a pseudo-terminal, with HOME set to the scratch folder."""

    def __init__(self, home, tools, *arguments):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(home)
            environment = {"HOME": home, "USER": os.environ.get("USER", "reader"), "TERM": "xterm-256color",
                           "PATH": tools + ":/usr/bin:/bin:/usr/sbin:/sbin"}
            os.execve(SHELL, [SHELL, *arguments], environment)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
        self.raw = ""
        self.status = None

    @property
    def text(self):
        return ESCAPES.sub("", self.raw).replace("\r", "")

    def pump(self, seconds=0.05):
        end = time.time() + seconds
        while time.time() < end and self.status is None:
            ready, _, _ = select.select([self.fd], [], [], 0.02)
            if ready:
                try:
                    data = os.read(self.fd, 65536)
                except OSError:
                    data = b""
                self.raw += data.decode(errors="replace")
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.status = os.waitstatus_to_exitcode(status)

    def until(self, what, condition, seconds=15):
        end = time.time() + seconds
        while not condition():
            if time.time() > end:
                raise AssertionError(f"gave up waiting for {what}; the screen ends:\n{self.text[-500:]}")
            if self.status is not None:
                raise AssertionError(f"BASICShell ended waiting for {what}; the screen ends:\n{self.text[-500:]}")
            self.pump()

    def at_prompt(self, prompt, text=None):
        """Whether the screen ends at the prompt, with nothing typed after it.
        The default prompt has a symbol after its Ready, hence the \\W*."""
        last = (self.text if text is None else text).rstrip().rsplit("\n", 1)[-1]
        return re.search(re.escape(prompt.strip()) + r"\W*$", last) is not None

    def ready(self, prompt):
        self.until(f"the prompt {prompt!r}", lambda: self.at_prompt(prompt))

    def send(self, keys):
        os.write(self.fd, keys.encode())
        self.pump(0.1)

    def ask(self, line, prompt, *expected):
        """Types `line`, waits for the next prompt, and checks the answer holds each of `expected`."""
        start = len(self.text)
        self.send(line + "\r")
        self.until(f"the answer to {line!r}", lambda: "\n" in self.text[start:]
                   and self.at_prompt(prompt, self.text[start:]))
        answer = self.text[start:]
        for text in expected:
            assert text in answer, f"{line!r} answered {answer!r}, without {text!r}"
        return answer

    def quit(self):
        self.send("QUIT\r")
        end = time.time() + 10
        while self.status is None and time.time() < end:
            self.pump()
        assert self.status == 0, f"QUIT ended with {self.status}"

    def close(self):
        if self.status is None:
            os.kill(self.pid, 9)
            os.waitpid(self.pid, 0)
        os.close(self.fd)


source = open(PAGE, encoding="utf-8").read()
blocks = re.findall(r"```basic\n(.*?)```", source, re.S)
startup = [block for block in blocks if block.startswith("' Read by BASICShell")]
hello = [block for block in blocks if block.startswith("#!")]
if len(startup) != 4 or len(hello) != 1:
    sys.exit(f"check-basicrc-tutorial: the page has {len(startup)} startup files and {len(hello)} commands; this script knows 4 and 1")
hello = hello[0]
DEFAULT, BASIC = "Ready", "BASIC> "

failures = 0


def check(name, body):
    global failures
    try:
        body()
        print(f"{name}: ok")
    except AssertionError as problem:
        print(f"{name}: FAILED: {problem}")
        failures += 1


with tempfile.TemporaryDirectory() as scratch:
    scratch = os.path.realpath(scratch)
    home = os.path.join(scratch, "home")
    tools = os.path.join(scratch, "tools")
    os.makedirs(home)
    os.makedirs(tools)
    os.symlink(SHELL, os.path.join(tools, "basicshell"))
    rc = os.path.join(home, ".BASICrc")

    def write(path, text):
        with open(path, "w", encoding="utf-8") as file:
            file.write(text)

    def shell(*arguments, prompt=BASIC):
        started = Shell(home, tools, *arguments)
        started.ready(prompt)
        return started

    def on_page(line):
        assert line in source, f"the page does not show {line!r}"

    def getting_started():
        s = shell(prompt=DEFAULT)
        try:
            assert "Type HELP for commands. Type QUIT to exit." in s.text
            s.ask("print 2 + 2", DEFAULT, "4")
            s.ask("date", DEFAULT, time.strftime("%Y"))
            s.ask('which "ls"', DEFAULT, "/bin/ls")
            s.quit()
        finally:
            s.close()

    def step1():
        # Typed into nano, as the page says: Control-X, Y, Return.
        on_page("nano ~/.BASICrc")
        s = shell(prompt=DEFAULT)
        try:
            s.send("nano ~/.BASICrc\r")
            s.until("nano", lambda: "^X" in s.text)
            s.pump(0.5)
            for line in startup[0].splitlines():
                s.send(line + "\r")
            s.send("\x18")
            s.pump(0.5)
            s.send("y")
            s.pump(0.5)
            s.send("\r")
            s.ready(DEFAULT)
            s.quit()
        finally:
            s.close()
        saved = open(rc, encoding="utf-8").read()
        assert saved.strip() == startup[0].strip(), f"nano saved {saved!r}"
        s = shell()
        s.quit()
        s.close()

    def step2():
        write(rc, startup[1])
        s = shell()
        try:
            s.ask("ll", BASIC, ".BASICrc", "total")
            s.ask("alias", BASIC, "alias ll='ls -la'")
            s.quit()
        finally:
            s.close()

    def step3():
        write(rc, startup[2])
        s = shell()
        try:
            s.ask('print ENVIRON$("HOME")', BASIC, home)
            s.ask('print ENVIRON$("EDITOR")', BASIC, "nano")
            s.quit()
        finally:
            s.close()

    def step4():
        s = shell()
        try:
            s.ask('print ENVIRON$("PATH")', BASIC, ":/usr/bin:")
            on_page("mkdir ~/bin")
            s.ask("mkdir ~/bin", BASIC)
            assert os.path.isdir(os.path.join(home, "bin"))
            write(os.path.join(home, "bin", "hello"), hello)
            on_page("chmod +x ~/bin/hello")
            s.ask("chmod +x ~/bin/hello", BASIC)
            assert os.stat(os.path.join(home, "bin", "hello")).st_mode & stat.S_IXUSR
            s.ask("hello", BASIC, "hello: command not found")
            s.quit()
        finally:
            s.close()
        write(rc, startup[3])
        s = shell()
        try:
            s.ask("hello", BASIC, "Hello from my own command.")
            s.ask('which "hello"', BASIC, "/bin/hello")
            s.ask("ll", BASIC, "bin")
            s.quit()
        finally:
            s.close()

    PATH_LINE = 'setenv "PATH", ENVIRON$("PATH") + ":" + ENVIRON$("HOME") + "/bin"'

    def mistake(old, new, *questions):
        """The finished file with `old` changed to `new`, and each (line, expected...) asked."""
        on_page(new)
        assert old in startup[3]
        write(rc, startup[3].replace(old, new))
        s = shell()
        try:
            for line, *expected in questions:
                s.ask(line, BASIC, *expected)
            s.quit()
        finally:
            s.close()

    def dollar():
        mistake(PATH_LINE, 'setenv "PATH", "$PATH:" + ENVIRON$("HOME") + "/bin"',
                ('print ENVIRON$("PATH")', "$PATH:" + home + "/bin"), ('which "ls"', "ls not found"))

    def tilde():
        mistake(PATH_LINE, 'setenv "PATH", ENVIRON$("PATH") + ":~/bin"',
                ('print ENVIRON$("PATH")', ":~/bin"), ('which "hello"', "hello not found"))

    def alias():
        mistake('alias ll="ls -la"', 'alias ll="sl -la"', ("ll", "/bin/sh: sl: command not found"))

    def comma():
        on_page('setenv "EDITOR" "nano"')
        write(rc, startup[3].replace('setenv "EDITOR", "nano"', 'setenv "EDITOR" "nano"'))
        s = shell()
        try:
            assert "/bin/sh: setenv: command not found" in s.text, s.text[-300:]
            s.ask('print "[" + ENVIRON$("EDITOR") + "]"', BASIC, "[]")
            s.quit()
        finally:
            s.close()

    def shellmode():
        on_page("option shellmode off")
        write(rc, startup[3] + "option shellmode off\n")
        s = shell()
        try:
            s.ask("date", BASIC, "Syntax error: Expected =")
            s.quit()
        finally:
            s.close()

    def quitting():
        write(rc, startup[3] + "quit\n")
        s = Shell(home, tools)
        try:
            end = time.time() + 15
            while s.status is None and time.time() < end:
                s.pump()
            assert s.status == 0, f"BASICShell is still running, or ended with {s.status}"
        finally:
            s.close()
        on_page("basicshell --no-rc")
        s = shell("--no-rc", prompt=DEFAULT)
        try:
            s.ask("hello", DEFAULT, "hello: command not found")
            s.quit()
        finally:
            s.close()
        write(rc, startup[3])

    for name, body in [("getting started", getting_started), ("step 1, typed into nano", step1),
                       ("step 2", step2), ("step 3", step3), ("step 4", step4),
                       ("mistake: $PATH in quotes", dollar), ("mistake: ~ in quotes", tilde),
                       ("mistake: misspelled alias", alias), ("mistake: a missing comma", comma),
                       ("mistake: shell mode off", shellmode), ("mistake: quit, and --no-rc", quitting)]:
        check(name, body)

sys.exit(1 if failures else 0)
