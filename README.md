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
keymap = "modern"           # modern | turbo (WordStar keys) | emacs
layout = "classic"          # classic (overlapping windows) | tiled (panes with tabs, splits)
restore_session = true      # started without a file: open what was open in this project last time
line_numbers = true
highlight_line = true
clock = true
show_whitespace = false

[editor]
auto_indent = true
soft_wrap = false           # continue long lines on the next screen row (Alt-Z)
semantic_colors = true      # colours from the language server over the built-in ones
inlay_hints = true          # the language server's notes (inferred types) after the line
persistent_undo = true      # keep undo history and cursor position between sessions
auto_pairs = true           # typing ( [ { " ' also inserts the closing one
highlight_word = true       # show the other uses of the word the cursor is on
trim_trailing_whitespace = false   # on save (.editorconfig overrides)
rulers = []                 # e.g. [80, 100]: vertical guides after these columns

tab_width = 4               # display width of a tab character
indent_size = 4             # spaces per indent level
large_file_mb = 50          # files above this size open in large-file mode

[tools]
compiler = "mojo"           # the TURBOMOJO_COMPILER environment variable overrides this
lsp_server = "mojo-lsp-server"   # TURBOMOJO_LSP overrides this
include_paths = []          # extra -I folders for build, run and the language server;
                            # relative ones start at the folder of the config file
docs_paths = []             # folders of library sources whose documentation Ctrl-F1 should find

[keys]                      # command name = one key or a list of keys
"file.save" = ["F2", "Ctrl-S"]
"edit.duplicateLine" = "Alt-D"
"search.gotoLine" = "Ctrl-Q L"       # two keys in a row: press Ctrl-Q, then L
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
| Keymaps | Options ▸ Keys: **Modern** (default), **Turbo / WordStar** (the Ctrl-E/S/D/X cursor diamond, Ctrl-Y, Ctrl-T, and Ctrl-K / Ctrl-Q sequences such as Ctrl-K S save, Ctrl-Q F find, Ctrl-Q R top of file) or **Emacs** (Ctrl-A/E/F/B/N/P, Ctrl-K, Ctrl-Y, Ctrl-X Ctrl-S, Ctrl-X Ctrl-C...). Function keys work the same in all three. Any command can be bound to one key or to a two-key sequence in `[keys]`; menus show the active keys |
| Keyboard | On terminals that support the kitty keyboard protocol (kitty, Ghostty, WezTerm, foot, recent Alacritty...) the IDE switches it on, so Esc is instant and unambiguous and combinations such as Ctrl-Shift-P, Ctrl-I (distinct from Tab) or Ctrl-Backspace (delete word left) can be told apart and bound in `[keys]`. Other terminals work as before |
| Macros | Ctrl-F5 starts and stops recording ("● REC" shows in the status line), Ctrl-F6 replays. Keys, pastes and commands picked from menus are recorded, including dialogs such as Replace, so a macro can be played on line after line or at several cursors |
| Encodings | UTF-8, with a byte order mark kept if the file has one. A file that is not valid UTF-8 is read as Latin-1 (one character per byte) and saved back byte for byte; the status line shows "Latin-1" or "UTF-8 BOM". A file with both LF and CRLF line ends shows "Mixed>LF" (or "Mixed>CRLF") until it is saved with the kind shown |
| Between sessions | Reopening a file puts the cursor where it was and brings back its undo and redo history, as long as the file still has exactly the content it had when the history was saved. Kept under `~/.local/state/turbomojo/history` (the 500 most recent files); `editor.persistent_undo = false` turns it off |
| Problems (language server) | F7 starts the Mojo language server. Problems are underlined where they are (curly and coloured on terminals that can; plain otherwise, `TURBOMOJO_UNDERLINE=curly` or `plain` decides), the line number takes the colour of the worst problem on its line, and the status line shows the message for the cursor line. The **Problems** window lists them for all open files; Enter jumps, Alt-F8 / Alt-F7 go to the next and previous one |
| Completion | Ctrl-Space shows words from the file at once; with the language server running (F7) its suggestions are merged in on top, with a tag for the kind (`fn`, `var`, `typ`...), the signature or type beside the name, and a panel with the documentation of the selected item. Typing `.` asks the server for members by itself. Typing narrows the list, Enter or Tab accepts |
| Describe symbol | Alt-I (Search ▸ Describe symbol) asks the language server about the symbol at the cursor and shows the answer in a window under it: signature in the editor's syntax colours, documentation with headings, lists, **bold**, `code` and links rendered from Markdown. Arrow keys and PgUp/PgDn scroll; Esc closes; any other key closes it and does what it normally does |
| Parameter tip | Typing `(` or `,` in a call (the characters the language server names) shows the signature of the function on the row above the cursor, with the parameter being typed highlighted and underlined; it follows the cursor through the arguments and disappears when the call is closed or left. Several signatures show as "2/3"; parameter documentation appears below; a signature wider than the screen is shown around the current parameter. Alt-P (Search ▸ Parameter info) asks for it anywhere; Esc hides it |
| Go to definition | F12 (Search ▸ Go to definition) asks the language server where the symbol at the cursor is defined and goes there, opening the file if needed. Several definitions are listed in the Message window (Alt-F8 / Alt-F7 step through them) |
| Find references | Shift-F12 (Search ▸ Find references) lists every use of the symbol at the cursor, its definition included, in the Message window as file:line:column with the line's text - the file being edited first, other files after it. Enter on a line, or Alt-F8 / Alt-F7, goes to a use; Alt-, comes back |
| Rename symbol | Shift-F2 (Search ▸ Rename symbol) asks for a new name and has the language server rename the symbol everywhere. Every change is listed in the Message window. Changes in this file only are applied at once and one Undo takes them back; when other files are affected the IDE asks first, then opens them and changes each in one undo step - nothing is saved until you save. Note: the Mojo 1.2 server renames local variables only and says so for anything else |
| Quick fix | Alt-Enter (Search ▸ Quick fix) asks the language server what it can do about the problems on the cursor's line or the selection, and lists the offers - the server's preferred fix first; ones that cannot be used say why. Enter applies the chosen one as one undo step; changes reaching other files are listed and confirmed first, as with Rename. Note: the Mojo 1.2 server answers but offered no fixes for the errors tried |
| Semantic colours | With the language server running, names are coloured by what they are - functions and methods at their calls, types, fields, parameters, namespaces - on top of the built-in highlighter, which keeps colouring keywords, strings, comments and numbers. The colours move with the text while you type and are refreshed after each edit. Options ▸ Semantic colours (`editor.semantic_colors`) turns them off |
| Inlay hints | Notes from the language server (inferred types, parameter names) are shown dimmed after the end of the line as `◂ total: Int`; they are not part of the text. Options ▸ Inlay hints (`editor.inlay_hints`). Note: the Mojo 1.2 server sent no hints for the code tried |
| Outline | Ctrl-F12 (Window ▸ Outline) shows the file's structure in a window at the right edge: structs, traits, functions and methods as an indented tree, plus fields and variables when the language server is running. It follows the editor in front, updates as you type, and marks the symbol the cursor is in. Switch to it (F6) and press Enter, or click a line twice, to go to that symbol; Ctrl-F12 again closes it. Without a server a built-in scan of the text is used |
| Other uses of a word | With the cursor on a name, every other whole-word use of it on screen gets a quiet background - no language server needed. Off while a search's matches are shown or text is selected; `editor.highlight_word = false` turns it off |
| Go to symbol in project | Alt-F12 (Search ▸ Go to symbol in project) lists every def, struct, trait and constant of the project's Mojo files; type a few letters of a name (or of the struct it belongs to) to narrow the list, Enter goes there. The index is built in the background (hidden folders and `.gitignore`d ones are skipped), includes unsaved changes of open files, and is refreshed on save and when it is older than 20 seconds |
| Documentation (Topic search) | Ctrl-F1 (Help ▸ Topic search) shows the documentation of the name at the cursor in a window: signature, summary, arguments, result, and for a struct its fields and methods - taken from the docstrings with `mojo doc`, no language server needed. F1 does the same when the cursor is on a name it has documentation for, and shows the keyboard reference otherwise. Covers the project's Mojo files and the folders in `tools.docs_paths`; the installed standard library ships without sources, so for its names Ctrl-F1 falls back to the language server's description when the server is running |
| Tiled layout | Window ▸ Tiled layout (or `layout = "tiled"` under `[ui]`) replaces the overlapping windows by panes that share the screen. Every open file is a tab of a pane; the tabs stand in the pane's top border and can be clicked. Alt-\\ moves the file in front into a new pane to the right, Alt-\| into one below; Alt-F6 goes to the next pane, Alt-PgDn / Alt-PgUp to the next / previous tab; Window ▸ Move to next pane, Grow pane (Alt-}), Shrink pane (Alt-{). Closing the last file of a pane gives its room back; Zoom (F5) lets one pane take everything. The Message and Outline windows keep the bottom and the right edge. The classic layout stays the default |
| Bottom panel | The window at the bottom has three pages, shown as tabs in its top border: **Message** (compiler and program output), **Search** (Find in Files results, references and other lists of places) and **Problems** (what the language server reports, for all files). Each page keeps its own content and its own list for Enter and Alt-F8 / Alt-F7. Window ▸ Message / Search results / Problems list opens a page; with the panel focused, Left / Right (or Alt-PgUp / Alt-PgDn, or a click on a tab) switch pages and Alt-} / Alt-{ make it higher or lower (the Outline window: wider or narrower). New problems come to the front only if you have not turned to another page |
| File explorer | Ctrl-E (Window ▸ File explorer) opens the project's files as a tree at the left edge; editors move over, and the file being edited is marked. Only folders you open are read. In it: Enter opens a file or opens / closes a folder, Right / Left step into and out of folders, **N** new file, **F** new folder, **R** rename, **M** move to another folder of the project, **Del** move to the trash (after a question; nothing is deleted outright - it goes to the desktop's trash folder and can be restored from there), **.** shows files that `.gitignore` hides, **U** reads the folders again (it also happens by itself every two seconds). Open windows follow a renamed or moved file. Esc returns to the editor; Ctrl-E from inside closes the explorer |
| Palette ("Go to") | One field for going anywhere. Alt-G (File ▸ Go to file) lists the project's files - the ones you open often and lately first - and narrows as you type a name or folder; `name:12` or `name:12:5` opens at that line (and column). Start with `>` for commands (Ctrl-P opens it that way), `@` for the symbols of the file in front, `#` for symbols of the whole project, `:` for a line of the file in front. Enter goes there, Esc leaves; Alt-, comes back |
| Project and pixi tasks | The project is the folder with `pixi.toml` at or above where the IDE is started (a `.turbomojo.toml` takes precedence): the explorer, the palette and the symbol index cover that folder even when you start in a subfolder. Shift-F9 (Run ▸ Pixi tasks) lists the tasks of `pixi.toml` with what they run; Enter runs the chosen one with `pixi run` in the project folder while you keep editing. Its output goes to the Message page; compiler-style errors in it can be jumped to. Run ▸ Run last task repeats it; Ctrl-F2 cancels |
| Run configurations | Run ▸ Run configurations lists named ways to run the project: which file, with what arguments, environment variables and working folder, and whether to build first and run the result. Select marks the one that Run (Ctrl-F9) uses - whatever file is in front; "(the file being edited)" gives the old behaviour back. Edit, New and Delete change them. They are kept in the project's `.turbomojo.toml` as `[run.<name>]` tables (with `[run] active = "<name>"`), so they can be shared with the project. Test still runs the file in front |
| Sessions | Start TurboMojo without a file name in a project and it opens what was open there last time: the files, each cursor where it was, the window that had the keyboard, the window places (or, in the tiled layout, the panes and their tabs), the explorer with its open folders, the Outline window and the bottom panel's page. The session is written on Quit and every half minute. Starting with file names opens just those and leaves the session alone; `restore_session = false` under `[ui]` turns it off |
| Back / Forward | Alt-, returns to where the cursor was before the last jump (go to definition, go to line, go to symbol, a compiler message or search hit); Alt-. goes forward again. Up to 100 places are remembered, across files |
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
| `src/markdown.mojo` | Markdown to styled, wrapped lines (hover windows, documentation panels) |
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
- Only UTF-8 and Latin-1 are handled: other encodings (UTF-16, Windows-1252's extra characters, Shift-JIS...) open as Latin-1 characters. There is no command to convert a file between encodings or to add or remove the byte order mark. If you type a character Latin-1 cannot hold into a Latin-1 file, it is saved as UTF-8 and the status line says so.
- The saved undo history contains text you deleted, in plain form, in your state directory (the folder is created for your user only). It is written when you save, close an unchanged file or quit; if another program changes the file, its history is not used again.
- While the language server runs (F7), every open `.mojo` file is kept in step with it: opened, updated 0.3 s after you stop typing (only the changed ranges when the server supports that), told about saves, and closed. Problems are known only for files that are open.
- If the language server stops unexpectedly it is started again for the file it was checking, after 1, 2 and 4 seconds; after three crashes within a minute it stays off until you press F7 again. What it offers is written to the log file when it starts.
- Find in files reads files from disk (unsaved changes are not seen), lists one hit per matching line, and skips hidden files, `node_modules`, `__pycache__`, binary files, files over 5 MB and the simple entries of the folder's `.gitignore` (`name`, `name/`, `*.ext`); other `.gitignore` rules are not applied. It stops after 5,000 hits.
- With several cursors, commands other than typing, deleting, moving and the clipboard (Tab indent, comment, duplicate line, PgUp/PgDn, Find...) first go back to one cursor. Undo also returns to one cursor. Alt-click needs a terminal that passes Alt with mouse clicks to the program.
- With soft wrap, Home and End still go to the start and end of the whole line, continuation rows are not indented, and the Message window does not wrap.
- Folds are not saved with the file or in recovery files, the fold markers need the line-number gutter, and deleting a folded header line deletes only that line (the block under it becomes visible).
- Auto-closing pairs do not look at syntax: they also act inside strings and comments. Rulers are not drawn while soft wrap is on.
- Key sequences are at most two keys long. The Turbo keymap has no block markers (Ctrl-K B / Ctrl-K K): Ctrl-K C/V/Y act on the ordinary selection. In the Emacs keymap Alt-F and Alt-W keep opening the File and Window menus rather than moving by word or copying. Some key combinations never reach a terminal program (Ctrl-M, Ctrl-I, Ctrl-H are Enter, Tab and Backspace).
- A macro is kept only until the IDE exits, there is one of it, mouse actions are not recorded, and each recorded step is its own undo step.
- Ctrl-F9 Run hands the terminal to your program on purpose, the way Turbo's user screen did. Build and Format run in the background.
