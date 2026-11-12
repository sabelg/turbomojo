# What's new

## 1.8 (in progress)

- **Themes as files**: Paper Light, High Contrast and Hacker Matrix besides Turbo
  Classic, Midnight Neon and Amber CRT; your own in `~/.config/turbomojo/themes/`;
  `theme = "auto"` follows the terminal's (or GNOME's) light or dark.
- **Notifications**: toasts when a build, tests, a commit or the agent finish while you
  are elsewhere; Help > Notifications (Shift-F10) shows what is running. Toasts that
  come while you type wait for a pause, a save or the debugger stopping; your own
  build, tests and commits come at once and first.
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
