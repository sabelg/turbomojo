# What's new

## 2.3 (in progress): a vim interface

- Options > Keys: Vim (`keymap = "vim"`) gives the editor vim's modes. Normal mode
  (NORMAL in the status line, a block cursor) has vim's motions (w b e, 0 ^ $, gg G,
  f t ; ,, %, { } and the rest), its operators with motions, counts and text objects
  (dw, 3dd, cw, yy, di(, ci", dap), x r J p P, `.` to repeat a change, u and Ctrl-R,
  and Visual mode with v and V; Esc goes back from Insert mode (a bar cursor). Ctrl
  and Alt keys, the F-keys and the menus stay TurboMojo's in every mode. / ? n N * #
  search with vim's patterns, and `:` opens vim's command line on the status row -
  :w :q :wq :x :e :42 :%s/a/b/g and TurboMojo's own commands by name (:build, :run).
  Registers too: "a to "z ("A adds), "0 the last copy, "_ none, and "+ the clipboard,
  which reaches the terminal's clipboard over SSH as well.
- A Vim preset (Options > Presets, and **Vim start** in the first run's question): the
  Modern look with vim's keys and relative line numbers. Options > Relative numbers
  (`editor.relative_numbers`) shows each line's distance from the cursor's line in the
  gutter, for 5j and 3dk. F10 and Alt still open the menus.
- Documentation & Help upgrades: instant warm disk cache for the 1,600+ page offline
  Mojo library (`tmide --warm-docs`), full syntax colouring on fenced blocks with
  attributes (`mojo no-test`, `title="..."`) and in the Docs & Error Explanation panes,
  dotted module search (`std.collections.list`), receiver-aware method lookup
  (`items.append`), in-page search (`Ctrl-F` / `F3`), heading jump (`G`), collapsible
  chapter headings, `C` / `T` to copy or try any code block, Mojo 1.2 legacy-syntax
  banners on older course pages, 27 built-in Mojo 1.2 error pages, 13 interactive
  exercises, and one-click background `pixi install` for the Mojo GPU Puzzles.
- Coding agent upgrades: `auto`, `accept-edits`, and `ask` permission modes (`Alt-M`),
  model & thinking selectors (`Alt-O`, `Alt-T`), `@file` Tab-completion, `Alt-Up` /
  `Alt-Down` prompt history, persistent sessions, Send diagnostics to agent, and a
  built-in MCP workspace server (`scripts/mcp_server.py`).

## 2.2: ready for other people
- A program that uses a library which is not installed (`unable to locate module
  'max'`, `No module named 'numpy'`): TurboMojo finds its package on the project's
  channels and offers to install it with `pixi add`, then builds or runs again; with no
  `pixi.toml` it offers to make the project first. Nothing is installed without a yes.
- F1 on a name of a Python library your program imports (`np.zeros`) shows its
  documentation, from the project's own Python. The language server runs in the
  project's environment, so it knows the Mojo packages installed there (MAX and others),
  and starts again in another project's when one of its files comes to the front.
- `pixi run bundle` makes a tar file to copy to a server: TurboMojo and the libraries
  it needs, which runs there after unpacking, without pixi.
- Help > Exercise done? checks your answer to a Mojo GPU Puzzle too: it runs your copy
  in each of the puzzle's modes, as the course's own tests do.
- After Ctrl-F9 the Message window says how the run ended, how long it took and, for a
  program that uses the GPU, which GPU it ran on.
- Options > GPU in the status line shows the GPU your programs will run on (asked once
  from nvidia-smi or rocm-smi, in the background); `tmide --caps` names it, with its
  memory and driver.
- Help > Report a problem... writes a ready-to-file issue text (versions, the terminal,
  the last crash, your settings without secrets), copies it and opens it; nothing is
  sent.
- A guide to working on a remote machine over SSH and in tmux (the user guide: copying
  to your own clipboard, the mouse, colours, keys, pictures); copying through tmux with
  no X11, Wayland or clipboard program on the server is now tested.
- Options > Presets...: Turbo (the blue desktop, overlapping windows) or Modern (your
  terminal's colours, panes with tabs, the explorer open, the Modern keys) in one
  choice; the first run's theme question offers Modern at its top. `ui.explorer = true`
  opens the explorer at each start.
- Help > Check setup... lists what TurboMojo uses (Mojo and its release, pixi, the
  language server, the debugger, the docs, the terminal's colours and keys), marks what
  is missing, and Fix helps with it; the first start shows it when something is missing.
- File > New project... makes a Mojo project - a `pixi.toml` with Mojo, `hello.mojo` and
  a test - opens it and installs Mojo with `pixi install`; the first start in a folder
  with no project offers it.
- If the Mojo found is another release than the one TurboMojo was built with, the status
  line says so at start-up, instead of the language server or builds failing without
  saying why; `tmide --caps` shows both versions.
- `tmide --screenshot OUT.svg` draws the IDE without a terminal and saves the screen as
  an SVG picture (`--size`, `--theme`, `--command` to open the palette, the explorer...);
  it changes none of your settings.

## 2.1: UI clarity and calm

- The window with the focus is shown more ways (bold title); the others keep their
  selection and cursor, muted; the shown tab is in brackets.
- Problems are marked E, W or i in the gutter, and their underlines are wavy, dashed
  or dotted - not by colour alone.
- Terminal ANSI and Terminal Mono themes: your terminal's own colours; `NO_COLOR`
  is honoured.
- Okabe-Ito, a dark theme for colour-blind eyes: errors, warnings, notes, git markers
  and the main code colours stay apart with each of the three common kinds of colour
  blindness (checked in the tests).
- Themes look as designed in terminals with 256 or 16 colours too: every built-in theme
  keeps its text readable there (Amber CRT and Hacker Matrix lost it before). Theme
  files can set colours by role (`[roles]`) and for each depth (`[colors256]`,
  `[colors16]`).
- Every theme keeps errors, warnings, git markers and the main code colours apart for
  colour-blind eyes too; a few colours changed for it (Paper Light's errors are
  raspberry and its additions blue, Classic's strings light orange, Midnight's numbers
  pink and definitions yellow).
- Options > Quiet code colours: four code colours (text, comments, strings,
  definitions), so that errors and search hits stand out most.
- Turbo Muted, Turbo Classic in calm, less saturated colours; `theme = "auto"` follows
  terminals that only tell their background colour live too.
- Options > Colour theme shows each theme as you move through the list; the first run
  asks which one, once.
- Emoji line up in more terminals: the IDE measures at start-up how wide the terminal
  draws a few doubtful glyphs (shown by `tmide --caps`) and lays them out to match; a
  width it still gets wrong spoils one cell, no longer the rest of the line.
- Pictures in the Mojo documentation show as "[image: ...]" links that name the
  picture's file, and in kitty, Ghostty and other terminals with the kitty graphics
  protocol the PNGs themselves, also inside tmux (`[ui] images`); terminals with
  sixel (foot, xterm, tmux 3.4) get them as sixel.
- Translated menus can have hot letters in any script ("~Ф~айл", "~Ö~ffnen"):
  small or capital, they open the menu, choose the item and press the button.

## 2.0: release

- `tmide --version` and `tmide --help`; a conda package (`pixi run package`).
- A user guide, a keymap reference for all three keymaps and a changelog
  (docs/USER_GUIDE.md, docs/KEYMAP.md, CHANGELOG.md).
- Checked on every change: fuzzing of the key, JSON, text and terminal parsers,
  performance budgets (start-up, keys, a 1,000,000-line file, idle CPU) and a soak test
  of long editing that watches the memory.

## 1.9: help that keeps you working, plugins, other languages

- **Themes as files**: Paper Light, High Contrast and Hacker Matrix besides Turbo
  Classic, Midnight Neon and Amber CRT; your own in `~/.config/turbomojo/themes/`;
  `theme = "auto"` follows the terminal's (or GNOME's) light or dark.
- **Notifications**: toasts when a build, tests, a commit or the agent finish while you
  are elsewhere; Help > Notifications (Shift-F10) shows what is running. Toasts that
  come while you type wait for a pause, a save or the debugger stopping; your own
  build, tests and commits come at once and first.
- **Plugins and other languages**: plugins in `~/.config/turbomojo/plugins` add
  commands, status items and panels (docs/PLUGINS.md); `[lsp.<name>]` in the config
  file adds a language server for other files (F7 starts it).
- **Coming from Python**: Help > Coming from Python lists what is different in Mojo
  1.x, and the book has VS Code's keys next to TurboMojo's; explanations of Python
  habits link to it (P).
- **Exercises**: Help > Exercises - eight small Mojo programs that are wrong until
  you fix them; Help > Exercise done? checks yours. Opt-in; nothing starts by itself.
- **Tips when they help**: paging to a function, a long run of arrows or Backspace,
  or Find again and again brings one tip, once, at a pause; Help > No more tips stops
  them.
- **Ask the agent, with local help**: Help > Ask agent about this error / this code
  sends the code, the message, TurboMojo's explanation and the documentation pages
  that fit, and asks for an answer that names its pages; imports in the answer are
  built with your Mojo, and made-up ones are reported.
- **One search box**: Find in documentation (Alt-F1) takes a name, `List.append` or
  a pasted error line, answers in one line, and lists the commands that fit; `?`
  in the palette hands the text over.
- **Key boxes**: after a prefix key (Ctrl-K, Ctrl-Q, Emacs Ctrl-X), a pause shows
  the keys that may follow and their commands.
- **Docs pane**: Help > Docs pane shows the documentation of the name at the cursor
  beside the code and follows the cursor.
- **Error explanations**: F1 on a problem explains the Mojo message beside the code,
  with a program before and after the fix; Help > Error messages lists them.
- **Key echo**: a command picked from a menu or the palette names its key on the
  status line, until you have used the key a few times.
- **Help**: this book - the guide, the cheat sheet, a tutorial file, what's new - and
  the finder (/) searches it with the Mojo documentation.

## 1.7: coding agents

The agent panel (Ctrl-F11) for any agent that speaks the Agent Client Protocol (for
example Claude Code's `claude-agent-acp`): streamed answers, @file mentions, reads
through the editor, changes as proposals, commands after a yes, and a permission
prompt for everything, with an allow list for the session.

## 1.6: terminal, tests, git

Integrated terminals (a shell, the program you run, the Mojo REPL), the test
explorer, git markers in the gutter, the diff view with staging one change at a time,
commit, branches, blame, and one Problems page for the language server, builds and
tests.

## 1.5: debugger

Debugging with `mojo-lldb-dap`: breakpoints with conditions and log messages, stepping,
the Debug window, watches, Evaluate, the CPU window.

## 1.4 and before

The workspace (explorer, project search, sessions, folder trust, pixi tasks), the
language server, and the editor core: tiled panes, multiple cursors, folding, macros,
keymaps, large files, recovery after a crash.
