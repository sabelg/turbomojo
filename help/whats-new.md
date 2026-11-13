# What's new

## 2.1 (in progress)

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
