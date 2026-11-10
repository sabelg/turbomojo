# TurboMojo

A text-mode IDE for [Mojo](https://www.modular.com/mojo), written entirely in Mojo and modelled on
Borland Turbo C++ 3.0 (1992). It has the blue desktop, double-line windows, drop shadows,
menus with highlighted hotkeys and the "Compiling… Press any key" box. Under that look it
adds a few modern features: truecolor themes, a mouse, a fuzzy command palette, grouped
undo/redo, word completion and OSC 52 system clipboard copy.

```
 ≡  File  Edit  Search  Run  Compile  Options  Window  Help                 02:31
╔═[■]════════════════════════ hello.mojo ══════════════════════════════1═[↑]═╗
║  1 """A tiny demo program for TurboMojo."""                                 ▲
║  2 from std.collections import List                                         ■
║  5 struct Counter(Copyable, Movable):                                       ▒
╚═ 7:1 ═══════════◄■▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒►╝
 F1 Help  F2 Save  F3 Open  ^P Commands  F9 Build  ^F9 Run  F10 Menu
```

## Build & run

```bash
pixi run build                         # -> build/tmide
pixi run ./build/tmide examples/hello.mojo
```

Start it through `pixi run` so that `mojo` is on `PATH`, because Build, Run, Format and Test call it.
To use a different compiler binary, set `TURBOMOJO_COMPILER` or change it under
**Compile ▸ Compiler command…**.

It works best in a terminal with 24-bit colour and SGR mouse support (kitty, WezTerm, iTerm2,
GNOME Terminal, Windows Terminal and others). Colour depth is taken from `$COLORTERM` and
`$TERM`, and the IDE falls back to 256 or 16 colours where needed; set
`TURBOMOJO_COLORS=truecolor|256|16` to override. Inside tmux you get 256 colours unless
`COLORTERM=truecolor` is passed through. To see what your terminal reports:

```bash
pixi run ./build/tmide --caps
```

## Configuration

Settings are read from `~/.config/turbomojo/config.toml`, then from a `.turbomojo.toml` in the
working directory or the nearest parent folder (the project file wins):

```toml
[ui]
theme = "midnight"          # classic | midnight | amber
line_numbers = true
highlight_line = true
clock = true
show_whitespace = false

[editor]
auto_indent = true

[tools]
compiler = "mojo"           # the TURBOMOJO_COMPILER environment variable overrides this

[keys]                      # command name = one key or a list of keys
"file.save" = ["F2", "Ctrl-S"]
"edit.duplicateLine" = "Alt-D"
```

Changing something in the Options menu writes just that setting back to your user file and
leaves the rest of the file, including comments, alone. Command names for `[keys]` are listed in
`src/commands.mojo` (`file.open`, `compile.build`, `search.find`, ...). Mistakes in a config file
are shown in the status line at startup and written to the log; the IDE still starts.

## Features

| Area | What you get |
|---|---|
| Desktop | Overlapping windows with drag-to-move (title bar), drag-to-resize (bottom-right corner), zoom (F5), tile/cascade, Alt-1…9 window numbers, a window list (Alt-0) and drop shadows |
| Editor | Mojo syntax colouring (keywords, types, builtins, strings and docstrings, numbers, decorators, def names), line numbers, current-line highlight, bracket matching, smart Home, auto-indent (indents after `:`), Tab/Shift-Tab block indent, toggle comment, duplicate/delete line, insert/overwrite modes (underline or block cursor) |
| Undo | Grouped undo/redo. Typing a word undoes as one step, and so does Replace-all or Format |
| Search | Find, Replace / Change all, Search again, Go to line, **Go to symbol** (fuzzy list of `def`/`struct`/`trait`/`comptime`) |
| Command palette | Ctrl-P fuzzy-searches every menu command |
| Completion | Ctrl-Space completes identifiers from the buffer plus Mojo keywords, types and builtins |
| Compile | F9 runs `mojo build` **in the background**: you keep editing while a spinner and timer show progress, output streams into the Message window, and Ctrl-F2 cancels. When it finishes you get the Turbo-style result box. In the Message window, Enter or Alt-F8/F7 jumps to the error's line and column |
| Run | Ctrl-F9 / F8 runs `mojo run` on the user screen and then returns. Alt-F5 shows the user screen again. Run ▸ Test runs the file's `std.testing` TestSuite, and program arguments can be set |
| Format | Alt-F9 runs `mojo format` in the background and reloads the file as one undo step. If you edit the buffer while it runs, the buffer is left alone |
| Files | Tabs are kept as real tab characters (shown 4 columns wide; Options ▸ Show whitespace marks them). Tab-indented files are detected and the Tab key and auto-indent follow suit. CRLF line endings and a missing final newline are preserved; the status bar shows `LF`/`CRLF` and `Tabs`/`Spaces`, and both can be toggled in Options |
| Unicode | Full UTF-8 with display widths: CJK and emoji take two columns and combining accents attach to their base letter, so cursor, selection, mouse clicks and the right border stay aligned |
| Clipboard | Internal clipboard mirrored to the system clipboard via OSC 52. Bracketed paste is supported |
| Themes | Turbo Classic (CGA), Midnight Neon, Amber CRT |
| Robustness | Resizing is picked up instantly; `kill`, closing the terminal window or logging out saves every unsaved buffer to `~/.local/state/turbomojo/recovered/` (never over your files) and restores the terminal; `kill -TSTP` / `fg` suspends and resumes cleanly. If the IDE itself crashes, the terminal is restored and a stack trace goes to `~/.local/state/turbomojo/crash.log`. An idle IDE uses no CPU |
| Rendering | Double-buffered diff renderer with 24-bit colour and synchronized output (no tearing) |

Press **F1** inside the IDE for the full keyboard reference.

## Source layout (all Mojo, no dependencies)

| File | Purpose |
|---|---|
| `src/term.mojo` | termios raw mode via FFI, window size, key / SGR mouse / bracketed-paste parser |
| `src/screen.mojo` | Cell buffer, box drawing, shadows, truecolor diff renderer, text dump for tests |
| `src/buffer.mojo` | Codepoint line buffer with grouped undo/redo records |
| `src/highlight.mojo` | Mojo tokenizer with multi-line string state |
| `src/window.mojo` | Editor/message window state, movement and editing commands |
| `src/window_search.mojo`, `src/window_draw.mojo` | Find/replace/bracket matching and window drawing (extend `Window`) |
| `src/commands.mojo` | Command registry: ids, titles, hints, default keys, menu layout |
| `src/menu.mojo` | Menu structures and drawing (contents generated from the registry) |
| `src/dialog.mojo` | Turbo Vision-style dialogs: input lines, check boxes, list boxes, buttons |
| `src/palette.mojo` | Colour themes |
| `src/appstate.mojo` | The `App` struct: all application state and small helpers |
| `src/app_*.mojo` | `App` behaviour as extensions: files, dialogs, menus, exec (command dispatch), pickers, jobs (build/format/run), input, mouse, draw |
| `src/app.mojo` | Event loop; `from app import *` gives `App` with all extensions |
| `src/util.mojo` | UTF-8, display widths, paths, popen/system, base64 |

## Testing

```bash
scripts/check.sh
```

builds the IDE, compiles and runs every `tests/test_*.mojo` (std.testing TestSuite files), and
runs a scripted smoke test of the real UI in a private tmux server. It prints `CHECK OK` only
if everything passed.

`scripts/tui-test.sh` lets you script key presses by hand and capture the screen:

```bash
scripts/tui-test.sh start examples/hello.mojo
scripts/tui-test.sh keys F9          # build
scripts/tui-test.sh shot             # print the screen
scripts/tui-test.sh stop
```

## Known limitations

- Tab stops are fixed at 4 columns.
- Each screen cell keeps only one combining mark, so stacked diacritics show just the last one.
- Ctrl-F9 Run hands the terminal to your program on purpose, the way Turbo's user screen did. Build and Format run in the background.
