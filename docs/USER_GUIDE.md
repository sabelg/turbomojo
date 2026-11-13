# TurboMojo user guide

TurboMojo is an IDE for Mojo in the terminal, in the style of Borland's Turbo C++ 3.0.
This guide walks through it task by task. The keys are those of the **Modern** keymap,
the default; [KEYMAP.md](KEYMAP.md) has the Turbo (WordStar) and Emacs keymaps as well,
and inside the IDE **F1** shows the keys of the keymap you use.

## Contents

1. [Starting](#starting)
2. [The screen](#the-screen)
3. [Finding any command](#finding-any-command)
4. [Editing](#editing)
5. [Moving around a project](#moving-around-a-project)
6. [The language server](#the-language-server)
7. [Building, running and testing](#building-running-and-testing)
8. [Debugging](#debugging)
9. [Terminals and the REPL](#terminals-and-the-repl)
10. [Git](#git)
11. [Coding agents](#coding-agents)
12. [Help while you work](#help-while-you-work)
13. [Settings, themes and keymaps](#settings-themes-and-keymaps)
14. [Plugins and other languages](#plugins-and-other-languages)
15. [Your terminal](#your-terminal)
16. [When something goes wrong](#when-something-goes-wrong)

## Starting

    pixi run build
    pixi run ./build/tmide examples/hello.mojo

(or `tmide` if you installed the package - see the README). Name files to open them, or
a folder to choose from it. With no arguments TurboMojo restores the windows of your last
session. `tmide --help` lists the command-line options.

The project is the nearest folder at or above where TurboMojo started that has a
`pixi.toml` - or, without one, the folder it started in. The first time you build, run or start the
language server in a folder, TurboMojo asks whether you trust it: those run code the
folder decides on.

## The screen

The **menu bar** at the top: **F10**, or Alt and a menu's highlighted letter. Edit
windows overlap like papers on a desk, each with its number in the top right corner:
**F6** goes to the next window, **Alt-1** to **Alt-9** to a window by number, **F5**
zooms one, **Alt-F3** closes it. Window > Tiled layout puts them side by side in panes
with tabs instead (**Alt-\\** splits, **Alt-F6** moves between panes).

The **bottom panel** has three pages: Message (the output of builds and programs),
Search (results and lists of places) and Problems (from the language server, the last
build and failed tests). Left and Right switch pages; Enter goes to the place a line names.
At the left the **file explorer** (**Ctrl-E**); at the right the **outline** (**Ctrl-F12**),
the test explorer, the docs pane or the agent panel.

The **status line** at the bottom shows the keys that matter where you are, messages,
and on the right the file's line endings and indentation, LSP while a language server
runs, and items from plugins.

## Finding any command

**Ctrl-P** opens the palette: start with `>` for commands (every one, by name), `@` for
the functions of this file, `#` for those of the whole project, `:` and a number for a
line, `?` to search the documentation - or just type a file's name. **Alt-G** opens it on
the files.

A command you choose from a menu or the palette names its key on the status line for a
while ("Next time: Ctrl-D") until you have used the key a few times. After the first key
of a two-key sequence (Ctrl-K in the Turbo keymap), a pause shows the keys that may
follow. A tip comes, once, when you do something the slow way - paging to a function,
twenty arrow presses in a row; Help > No more tips stops them.

## Editing

The usual keys work: **Ctrl-C**, **Ctrl-X**, **Ctrl-V**, **Ctrl-Z** and **Ctrl-Y**, Shift
with the arrows to select, **Ctrl-A** for all. Some that save time:

- **Ctrl-D** duplicates the line, **Ctrl-K** deletes it, **Alt-Up** and **Alt-Down** move it.
- **Ctrl-/** comments the selected lines in and out; Tab and Shift-Tab indent them.
- **Alt-D** adds a cursor at the next occurrence of the selection; **Ctrl-Alt-Down** adds
  one on the line below. Type, delete or paste and every cursor does it.
- **Alt--** folds the block the cursor is in, **Alt-=** opens every fold.
- **Ctrl-Space** completes the word (with the language server: what fits there).
- **Ctrl-F5** records a macro, **Ctrl-F6** plays it back.
- **Alt-Z** soft-wraps long lines.

**Ctrl-F** finds, **Ctrl-R** replaces (both with regular expressions if you tick it),
**Ctrl-L** finds the next one again, **Shift-F3** searches every file of the project.
**Ctrl-G** goes to a line, **Ctrl-]** to the matching bracket.

**F2** saves. Unsaved work is safe without saving: it is copied to a recovery file a
moment after each change, and after a crash or a lost terminal the next start offers it
back. Undo history is kept between sessions.

## Moving around a project

**Alt-G** finds a file by a few letters of its name, the ones you open often first.
**Ctrl-T** goes to a function, struct or trait of this file by name, **Alt-F12** to one
anywhere in the project. **Alt-,** and **Alt-.** go back and forward through the places you
jumped from. The breadcrumbs in the window's title show which struct and function the
cursor is in; when the start of a long function has scrolled away, its first line stays
pinned at the top.

## The language server

**F7** starts Mojo's language server for the file in front (F7 again stops it). From then
on, problems appear as you type - underlined in the code, and on the Problems page - and:

- **Alt-I** describes the name at the cursor, **Alt-P** shows a call's parameters;
- **F12** goes to the definition, **Shift-F12** lists every use, **Shift-F2** renames;
- **Alt-Enter** offers the server's quick fixes for the problem at the cursor;
- **Ctrl-F1** shows the documentation of the name at the cursor (Help > Docs pane keeps
  it beside the code, following the cursor).

## Building, running and testing

**F9** builds the file in front in the background: you keep editing, the output streams
into the Message page under the exact command (`$ ...`, ready to paste into a shell), **Ctrl-F2** cancels. Each `file:line` there is a terminal link
(Shift- or Ctrl-Shift-click, as your terminal has it). After a second the status line shows the
time; after ten a box at the bottom right shows the output so far. Its errors are on the Problems page too: Enter
goes to one, **F1** on it explains the message. **Ctrl-F9** runs the program in the Run
window at the bottom, where it can read what you type. Run > Arguments sets its command
line; Run > Run configurations keeps several.

Run > Test explorer lists the project's test files (programs that run a `std.testing`
TestSuite) and their tests; it runs all of them, one file or one test, and a failure
takes you to the assertion. **Shift-F9** runs one of the project's pixi tasks.

## Debugging

**Ctrl-F8** sets a breakpoint (or click a line number), **Shift-F5** starts debugging.
While the program is stopped: **F7** steps into, **F8** steps over, **Shift-F8** steps
out, **F4** runs to the cursor, **Shift-F5** continues. **Ctrl-F3** shows the call stack
and the variables, **Ctrl-F7** adds a watch, **Ctrl-F4** evaluates a name, **Alt-F2** opens
the CPU window (machine code, registers, memory). **Ctrl-F2** ends the session.

## Terminals and the REPL

**Alt-F11** opens your shell in a window at the bottom, in the project folder; everything
you type goes to it, and **Alt-F11** again returns to the code (the shell keeps running).
Run > Mojo REPL starts `mojo repl`; **Ctrl-F10** sends the selected lines (or the line at
the cursor) to it.

## Git

In a git repository the gutter marks lines changed since the last commit (**Alt-N** and
**Alt-B** go to the next and previous change) and the explorer colours files by their
state. File > Diff shows a file's changes, where you stage, revert or unstage one change
at a time; File > Commit, Branch and Blame do what they say.

## Coding agents

**Ctrl-F11** opens the agent panel for a coding agent that speaks the Agent Client
Protocol - set `agent = "claude-agent-acp"` (or another) under `[tools]`. It asks before
every change to a file and every command, unless you allow one for the session; a
change it proposes opens in the diff view to accept or reject. **Shift-F11** mentions the
selection in your prompt. Help > Ask agent about this error (or this code) sends it the
code with TurboMojo's explanation of the error and the documentation that fits, and
checks the imports of its answer against your Mojo.

## Help while you work

- **F1** on a problem explains Mojo's message beside the code: what it means, how to fix
  it, a program before and after. Help > Error messages has them all.
- **Ctrl-F1** documentation of the name at the cursor; **Shift-F1** Modular's manual and
  library reference (Help > Download documentation fetches it once); **Alt-F1** searches
  it - names, `List.append`, or a pasted error line.
- Help > Coming from Python: what is different in Mojo, and the keys next to VS Code's.
- Help > Exercises: small programs that are wrong until you fix them.
- Help > Cheat sheet, Keyboard reference (**F1** elsewhere), Tutorial, What's new.
- Notifications that come while you type wait for a pause; **Shift-F10** lists them and
  what is running. Nothing that happens in the background takes the keyboard: when the
  agent asks something while you are in the editor, a notice says so and **Ctrl-F11**
  goes to it.

## Settings, themes and keymaps

The Options menu changes the common settings and writes them to
`~/.config/turbomojo/config.toml`; a project can have its own `.turbomojo.toml`. Options >
Colour theme picks a theme (Turbo Classic, Midnight Neon, Amber CRT, Paper Light, High
Contrast, Hacker Matrix, Terminal ANSI - your terminal's own colours -, Terminal Mono, or
`auto` to follow the terminal's light or dark; `NO_COLOR` starts Terminal Mono); your own
themes are TOML files in `~/.config/turbomojo/themes/`. Options > Keys picks the keymap -
Modern, Turbo (WordStar, as in Turbo C++) or Emacs - and `[keys]` in the config file
changes single keys. Options > Screen-reader mode gives a plain screen with the cursor on
what has the focus. The README lists every setting.

## Plugins and other languages

Plugins are programs in any language in `~/.config/turbomojo/plugins/`: they add commands
to the ≡ menu, status items and panels ([PLUGINS.md](PLUGINS.md); try
`examples/plugins/wordcount`). A language server for another language is a few lines in
the config file:

    [lsp.python]
    command = "ruff server"
    extensions = [".py"]

and **F7** on such a file starts it.

## Your terminal

TurboMojo works best in a terminal with 24-bit colour and SGR mouse support (kitty, WezTerm, iTerm2,
GNOME Terminal, Windows Terminal and others). Colour depth is taken from `$COLORTERM` and
`$TERM`, and the IDE falls back to 256 or 16 colours where needed; set
`TURBOMOJO_COLORS=truecolor|256|16` to override. At start-up the IDE also asks the terminal
(DECRQSS) whether a 24-bit colour it set took, and (XTGETTCAP) whether it draws coloured,
curly underlines; a yes adds to what the environment says, a no or no answer takes nothing
away, and your override always wins. Inside tmux the answers come from tmux itself and are
believed; without one you get 256 colours unless `COLORTERM=truecolor` is passed through.
Under GNU screen these two questions are not asked (screen passes such requests on badly).
Replies that arrive late are swallowed, never typed into the editor. To see what your
terminal reports:

```bash
pixi run ./build/tmide --caps
```

## When something goes wrong

- The language server stops: it is started again by itself, up to three times a minute;
  then **F7** tries again.
- TurboMojo crashes: your terminal is put back, the next start offers your unsaved work,
  and `~/.local/state/turbomojo/crash.log` says what happened.
- The colours look wrong: `tmide --caps` shows what your terminal reports;
  `TURBOMOJO_COLORS=256` (or 16) forces fewer colours.
- Mistakes in the config file are listed when TurboMojo starts.
