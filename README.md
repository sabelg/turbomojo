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
soft_wrap = false           # continue long lines on the next screen row (Alt-Z)
auto_pairs = true           # typing ( [ { " ' also inserts the closing one
trim_trailing_whitespace = false   # on save (.editorconfig overrides)
rulers = []                 # e.g. [80, 100]: vertical guides after these columns

tab_width = 4               # display width of a tab character
indent_size = 4             # spaces per indent level
large_file_mb = 50          # files above this size open in large-file mode

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
| Soft wrap | Options ▸ Soft wrap (Alt-Z): long lines continue on the next screen row, broken after a blank where possible. Up/Down move by screen rows, the view scrolls inside a line taller than the window, and line numbers mark only the first row of each line |
| Folding | Blocks are found by indentation. Alt-- (Edit ▸ Fold or unfold) hides or shows the block at the cursor, from its header or from any line inside it; clicking the ▾/▸ marker in the line-number gutter does the same. Fold all, and Expand all (Alt-=). A folded header shows how many lines it hides; moving the cursor skips them, and jumping into one (search, go to line, an error) opens it |
| Text menu | Move line up/down (Alt-Up/Down, also for selected lines), Join lines (Alt-J), Sort lines, Upper/Lower case (Alt-U / Alt-L) for the selection or the word at the cursor |
| Typing aids | Auto-closing pairs: `(`, `[`, `{` and quotes insert their partner, typing the closer steps over it, Backspace removes an empty pair, and with a selection the pair wraps it. Column rulers (`editor.rulers`). Trailing whitespace can be trimmed on save |
| Multiple cursors | Alt-D selects the word under the cursor, then adds a cursor at each next occurrence; Ctrl-Alt-Up/Down (or Shift-Alt-Up/Down) add a cursor on the line above or below; Alt-click adds or removes one. Typing, Backspace, Delete, Enter, arrows, Home/End, selection, cut/copy/paste act at every cursor, and each step is one undo. Copy joins the selections line by line and a paste with one line per cursor deals them out. Esc returns to one cursor. **Column selection:** Ctrl-Shift-Alt-arrows or Alt-drag select a rectangle (by screen columns, so tabs and wide characters line up); typing replaces it on every line and copy/paste keeps the block shape |
| Search | Find and Replace with **search as you type**: the first match is selected, every match is highlighted and the dialog shows "Match 3 of 17" while you type (Esc puts the cursor back). Options: case sensitive, whole words, **regular expressions** (no backtracking, so no pattern can hang the editor; `$1`, `${1}`, `$0`, `\n` in the replacement) and **in selection**. Replace steps through matches one at a time, Change all is one undo step. **Find in files** (Shift-F3) searches the project folder in the background with the same options and lists the hits in the Message window (Enter opens the file at the match, Alt-F8/Alt-F7 step through them, Ctrl-F2 cancels). Search again (Ctrl-L), Go to line, **Go to symbol** (fuzzy list of `def`/`struct`/`trait`/`comptime`) |
| Command palette | Ctrl-P fuzzy-searches every menu command |
| Completion | Ctrl-Space completes identifiers from the buffer plus Mojo keywords, types and builtins |
| Compile | F9 runs `mojo build` **in the background**: you keep editing while a spinner and timer show progress, output streams into the Message window, and Ctrl-F2 cancels. When it finishes you get the Turbo-style result box. In the Message window, Enter or Alt-F8/F7 jumps to the error's line and column |
| Language server | **F7** starts live checking of the current file with `mojo-lsp-server`: errors and warnings appear in the Message window about half a second after you stop typing, and Enter or Alt-F8/F7 jumps to them. F7 again stops it. (First slice; completion, hover and go-to-definition come with roadmap phase 2) |
| Run | Ctrl-F9 / F8 runs `mojo run` on the user screen and then returns. Alt-F5 shows the user screen again. Run ▸ Test runs the file's `std.testing` TestSuite, and program arguments can be set |
| Format | Alt-F9 runs `mojo format` in the background and reloads the file as one undo step. If you edit the buffer while it runs, the buffer is left alone |
| Files | Tabs are kept as real tab characters (shown 4 columns wide; Options ▸ Show whitespace marks them). Tab-indented files are detected and the Tab key and auto-indent follow suit. CRLF line endings and a missing final newline are preserved; the status bar shows `LF`/`CRLF` and `Tabs`/`Spaces`, and both can be toggled in Options |
| Unicode | Full UTF-8 with display widths: CJK and emoji take two columns and combining accents attach to their base letter, so cursor, selection, mouse clicks and the right border stay aligned. The cursor, Delete and selection work on grapheme clusters: an emoji sequence, a flag, a Hangul syllable or a letter with its accents is one step (Backspace removes a single accent first) |
| Large files | A 1,000,000-line file opens in about 0.1 s. Files above 50 MB (`editor.large_file_mb`) open in large-file mode, shown in the window title: syntax colours, the periodic recovery snapshots and the language server are off for that file. Work is still saved to the recovery folder if the IDE crashes or is terminated |
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
| `src/window_multi.mojo` | Multi-cursor editing (extends `Window`) |
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
| `src/grapheme.mojo` | Grapheme cluster boundaries (UAX #29) and cluster widths |
| `src/regex.mojo` | Regular expressions: parser, compiler and a Pike VM (no backtracking, captures, lazy quantifiers) |
| `src/grep.mojo` | Find in files: incremental folder walk and search |
| `src/search.mojo` | A search request: text or regular expression plus the Find options, matched line by line |
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

`scripts/bench-open.sh` generates a 1,000,000-line file and a 60 MB file under `build/big/` and
times how long the editor's loader takes to open them (it fails above 1 s for the first).

`scripts/tui-test.sh` lets you script key presses by hand and capture the screen:

```bash
scripts/tui-test.sh start examples/hello.mojo
scripts/tui-test.sh keys F9          # build
scripts/tui-test.sh shot             # print the screen
scripts/tui-test.sh stop
```

## Known limitations

- Grapheme clusters use built-in tables for common scripts and emoji, not the full Unicode database; Indic conjuncts are split after the virama. Emoji sequences line up only on terminals that report grapheme clustering (mode 2027); elsewhere their parts are laid out side by side. Dialog input fields still step by codepoint.
- Searching works line by line: a pattern cannot match across a line break, and matches of length zero are skipped. In texts over 50,000 lines the search runs when you press Enter instead of while you type, and matches are not counted.
- Find in files reads files from disk (unsaved changes are not seen), lists one hit per matching line, and skips hidden files, `node_modules`, `__pycache__`, binary files, files over 5 MB and the simple entries of the folder's `.gitignore` (`name`, `name/`, `*.ext`); other `.gitignore` rules are not applied. It stops after 5,000 hits.
- With several cursors, commands other than typing, deleting, moving and the clipboard (Tab indent, comment, duplicate line, PgUp/PgDn, Find...) first go back to one cursor. Undo also returns to one cursor. Alt-click needs a terminal that passes Alt with mouse clicks to the program.
- With soft wrap, Home and End still go to the start and end of the whole line, continuation rows are not indented, and the Message window does not wrap.
- Folds are not saved with the file or in recovery files, the fold markers need the line-number gutter, and deleting a folded header line deletes only that line (the block under it becomes visible).
- Auto-closing pairs do not look at syntax: they also act inside strings and comments. Rulers are not drawn while soft wrap is on.
- Ctrl-F9 Run hands the terminal to your program on purpose, the way Turbo's user screen did. Build and Format run in the background.
