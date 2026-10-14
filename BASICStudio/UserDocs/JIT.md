# JIT Command

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Compiles the current program and runs the compiled binary. `RUN` interprets; `JIT` is the same program, compiled first.

On arithmetic that is worth about a hundred times the speed. Everything else about it is meant to be identical: the compiler is held to the interpreter's output byte for byte, so choosing between `RUN` and `JIT` is a speed decision rather than a change of meaning. Anything the compiler cannot yet do is refused at compile time, naming the construct, rather than behaving differently at run time.

```basic
10 print "HELLO"
20 end
jit
```

Give it a file name to compile that file without disturbing the program you have loaded.

```basic
jit "mathbench.bas"
```

In BASICStudio, type it at the console, as in the shell, or use the toolbar's ⚡ or the Run menu's **JIT** (Cmd-Shift-R). Settings ▸ "⚡ builds with" chooses what Studio builds: LLVM, a native program (the Mac's default), or WebAssembly, run inside Studio, which is the only choice on iPhone and iPad. `JIT SWIFT` needs LLVM.

## What it needs

For a native program, `basicc`, the compiler, must be on your `PATH`; a WebAssembly build in Studio needs nothing installed. It is run as a program, not linked in — a host without it says so and carries on interpreting. Set `BASICC` in the environment to point at a particular build instead.

The program is compiled from the file it was loaded from when it has one, so `IMPORT` resolves against the directory it lives in, exactly as it does under `RUN`.

## What is different

A native `JIT` run has no debugger in Studio or the shell: breakpoints do not apply to it. Use `RUN` to step through a program and `JIT` to see it go fast. In Studio, a `JIT` built as WebAssembly does stop at breakpoints, and a native build can be debugged with `lldb`, since `basicc` writes debug information by default.

Compilation is at `-O0`. A `JIT` is asked for interactively, and the optimizer buys a few percent for a noticeably longer wait.

Interrupting a `JIT` run with Ctrl-C stops the compiled program and returns to the prompt, as it does under `RUN`.
