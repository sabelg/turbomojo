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

`pixi run` puts the Mojo toolchain on `PATH`. The IDE also works when started directly, as long
as `mojo` is on `PATH`: it then works out the toolchain's environment (`MODULAR_HOME`) itself.
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

tab_width = 4               # display width of a tab character
indent_size = 4             # spaces per indent level

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

**EditorConfig.** A `.editorconfig` in the file's folder or above it is honoured per file:
`indent_style`, `indent_size`, `tab_width`, `end_of_line` (lf/crlf), `insert_final_newline` and
`trim_trailing_whitespace`. These override the `[editor]` sizes above and the tab/space
auto-detection. The status bar shows the result, for example `LF  Spaces:2`.

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
| Language server | **F7** starts live checking of the current file with `mojo-lsp-server`: errors and warnings appear in the Message window about half a second after you stop typing, and Enter or Alt-F8/F7 jumps to them. F7 again stops it. (First slice; completion, hover and go-to-definition come with roadmap phase 2) |
| Run | Ctrl-F9 / F8 runs `mojo run` on the user screen and then returns. Alt-F5 shows the user screen again. Run ▸ Test runs the file's `std.testing` TestSuite, and program arguments can be set |
| Format | Alt-F9 runs `mojo format` in the background and reloads the file as one undo step. If you edit the buffer while it runs, the buffer is left alone |
| Files | Tabs are kept as real tab characters (shown 4 columns wide; Options ▸ Show whitespace marks them). Tab-indented files are detected and the Tab key and auto-indent follow suit. CRLF line endings and a missing final newline are preserved; the status bar shows `LF`/`CRLF` and `Tabs`/`Spaces`, and both can be toggled in Options |
| Unicode | Full UTF-8 with display widths: CJK and emoji take two columns and combining accents attach to their base letter, so cursor, selection, mouse clicks and the right border stay aligned. The cursor, Delete and selection work on grapheme clusters: an emoji sequence, a flag, a Hangul syllable or a letter with its accents is one step (Backspace removes a single accent first) |
| Clipboard | Internal clipboard mirrored to the system clipboard via OSC 52. Bracketed paste is supported |
| Themes | Turbo Classic (CGA), Midnight Neon, Amber CRT |
| Robustness | **Unsaved work survives crashes:** every modified buffer is copied to a swap file 2 seconds after a change, and after a crash, `kill -9` or power loss the next start offers to recover it (Recover / Discard / Later). Being killed politely (`kill`, closing the terminal, logging out) keeps the buffers the same way and restores the terminal. Your own files are never written without a save. **Files changed by other programs** are noticed at once: an unmodified buffer reloads quietly (undoable), and if you have unsaved changes you are asked whether to reload or keep your version. Resizing is picked up instantly; `kill -TSTP` / `fg` suspends and resumes cleanly. If the IDE itself crashes, the terminal is restored and a stack trace goes to `~/.local/state/turbomojo/crash.log`. An idle IDE uses no CPU |
| Rendering | Double-buffered diff renderer with 24-bit colour and synchronized output (no tearing) |

Press **F1** inside the IDE for the full keyboard reference.

## Source layout (all Mojo, no dependencies)

| File | Purpose |
|---|---|
| `src/term.mojo` | termios raw mode via FFI, window size, key / SGR mouse / bracketed-paste parser |
| `src/screen.mojo` | Cell buffer, box drawing, shadows, truecolor diff renderer, text dump for tests |
| `src/rope.mojo` | Text storage: UTF-8 rope on a B-tree with byte/character/line/UTF-16 summaries |
| `src/buffer.mojo` | Text buffer on the rope: (row, column) editing, grouped undo/redo, per-file settings |
| `src/highlight.mojo` | Mojo tokenizer with multi-line string state |
| `src/window.mojo` | Editor/message window state, movement and editing commands |
| `src/window_search.mojo`, `src/window_draw.mojo` | Find/replace/bracket matching and window drawing (extend `Window`) |
| `src/commands.mojo` | Command registry: ids, titles, hints, default keys, menu layout |
| `src/menu.mojo` | Menu structures and drawing (contents generated from the registry) |
| `src/dialog.mojo` | Turbo Vision-style dialogs: input lines, check boxes, list boxes, buttons |
| `src/palette.mojo` | Colour themes |
| `src/appstate.mojo` | The `App` struct: all application state and small helpers |
| `src/app_*.mojo` | `App` behaviour as extensions: files, dialogs, menus, exec (command dispatch), pickers, jobs (build/format/run), input, mouse, draw, swap, watch, lsp |
| `src/app.mojo` | Event loop; `from app import *` gives `App` with all extensions |
| `src/signals.mojo`, `src/crash.mojo` | Signal handling via an event descriptor; crash guard that restores the terminal |
| `src/caps.mojo` | Terminal capability detection and colour-depth mapping |
| `src/toml.mojo`, `src/config.mojo`, `src/editorconfig.mojo` | Config file reader/writer, layered settings, EditorConfig rules |
| `src/swap.mojo`, `src/watch.mojo` | Swap files for crash recovery; detection of files changed by other programs |
| `src/json.mojo` | JSON reader and writer (for the language-server, debugger and agent protocols) |
| `src/proc.mojo`, `src/rpc.mojo` | Two-way non-blocking child processes; JSON-RPC with Content-Length framing |
| `src/lsp.mojo` | Language Server Protocol client: lifecycle, document sync, diagnostics |
| `src/util.mojo` | UTF-8, display widths, paths, popen/system, base64 |

## Testing

```bash
pixi run check
```

builds the IDE, compiles and runs every `tests/test_*.mojo` (std.testing TestSuite files), and
runs a scripted smoke test of the real UI in a private tmux server. It prints `CHECK OK` only
if everything passed.

The project builds against the stable Mojo release (1.2 or newer). A second environment tracks
the nightly toolchain as an early warning for upcoming changes:

```bash
pixi run canary
```

`scripts/tui-test.sh` lets you script key presses by hand and capture the screen:

```bash
scripts/tui-test.sh start examples/hello.mojo
scripts/tui-test.sh keys F9          # build
scripts/tui-test.sh shot             # print the screen
scripts/tui-test.sh stop
```

## Known limitations

- Grapheme clusters use built-in tables for common scripts and emoji, not the full Unicode database; Indic conjuncts are split after the virama. Emoji sequences line up only on terminals that report grapheme clustering (mode 2027); elsewhere their parts are laid out side by side. Dialog input fields still step by codepoint.
- Ctrl-F9 Run hands the terminal to your program on purpose, the way Turbo's user screen did. Build and Format run in the background.
