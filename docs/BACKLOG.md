# TurboMojo backlog

The runner (see `docs/RUNNER.md`) works through this file top to bottom.
Source of truth for scope is `docs/ROADMAP.md`; this file breaks it into tasks.

Status marks: `[ ]` todo · `[x]` done and verified · `[!]` blocked (reason on the next line) · `[~]` partly done (what is missing on the next line)

## Phase 0: Foundations (v1.1)

- [x] P0-01 Test harness: `tests/` directory with TestSuite files run by `scripts/check.sh`; first tests for `util.mojo` (UTF-8 decode/encode, `char_width`, `pad_right`, paths, `fuzzy_score`, `base64`)
- [x] P0-02 Tests for `buffer.mojo`: load/save round-trip (tabs, CRLF, final newline), insert/delete, undo/redo, grouped undo, plus a randomised edit/undo/redo consistency test with a fixed seed
- [x] P0-03 Make the key parser testable without a tty (feed bytes, get events) and test it: arrows, modifiers, F-keys, Alt, UTF-8, SGR mouse press/drag/release/wheel, bracketed paste, lone ESC
- [x] P0-04 Tests for `highlight.mojo`: keywords, strings, triple-quoted state across lines, numbers, decorators, comments
- [x] P0-05 Headless screen snapshots: render `Screen` to plain text; golden-file tests for menu bar, a dropdown, a dialog, an editor window with wide characters
- [x] P0-06 Tests for `window.mojo` editing: typing, auto-indent, backspace unindent, tab/shift-tab, toggle comment, duplicate/delete line, selection, find/replace, bracket match, visual columns with tabs and wide chars
- [x] P0-07 Mouse handling tests through the app with synthetic events: click to place cursor, drag select, wheel scroll, title-bar move, corner resize, close box, menu clicks, dialog clicks. Fix whatever fails
- [x] P0-08 Command registry: one table of commands (id, title, default keys, hint); menus, palette, shortcuts and help generated from it
- [x] P0-09 Split `app.mojo` into modules (commands, files, jobs, dialogs-flow, mouse, draw); no source file over ~700 lines
- [x] P0-10 `poll()`-based event loop over stdin and child pipes with timers, replacing VTIME polling; idle wakeups only for the clock/spinner
- [x] P0-11 Signals through a self-pipe: SIGWINCH resize, SIGTERM/SIGHUP save-and-exit, SIGTSTP/SIGCONT suspend and restore
- [x] P0-12 Crash safety: terminal always restored on error paths; crash log under `~/.local/state/turbomojo/`
- [x] P0-13 Terminal capability probe (`Caps`): kitty keyboard, modes 2026/2027/2031/2048 via DECRQM, truecolor detection with 256/16-colour fallback rendering
- [x] P0-14a Config: TOML subset parser; `~/.config/turbomojo/config.toml` and project `.turbomojo.toml`; all Options persist; key rebinding from config
- [x] P0-14b Honour `.editorconfig` (indent style/size, EOL, final newline, trim trailing whitespace)
- [x] P0-15 Swap files and crash recovery (write every 2 s when dirty; offer recovery on open)
- [x] P0-16 External change detection (inotify via FFI, or mtime polling fallback): reload clean buffers, ask for modified ones
- [x] P0-17 JSON parser/writer module with tests (objects, arrays, strings with escapes and \u, numbers, bool, null)
- [x] P0-18 JSON-RPC transport (`Content-Length` framing over a child's pipes, non-blocking, request table) with tests against a fake server script
- [x] P0-19 Spike: start `mojo-lsp-server`, open the current file, show its diagnostics in the Message window; record measured latency in `docs/JOURNAL.md`
- [x] P0-20 Move `pixi.toml` to the stable Mojo 1.x channel if the code builds there; otherwise record what blocks it
- [x] P0-21 CI workflow file (`.github/workflows/ci.yml`) running `scripts/check.sh` on linux-64 and linux-aarch64 (not pushed; file only)

## Phase 1: Editor core (v1.2)

- [x] P1-01 Rope on a B-tree with summaries (bytes, lines, UTF-16 units) as a standalone module with exhaustive tests against a naive reference
- [x] P1-02 Port `TextBuffer` onto the rope behind the same API; undo/redo intact; all Phase 0 tests still pass
- [x] P1-03 Line metadata cache (visual width, lexer end state); incremental highlighting that re-lexes only from the edited line until states converge
- [x] P1-04 Grapheme cluster segmentation (UAX #29 extended clusters) with tests; cursor, delete and selection move by cluster; screen cells hold full clusters
- [x] P1-05 Large-file behaviour: open a generated 1M-line file under 1 s; large-file mode above 50 MB; benchmark script recorded in the journal
- [x] P1-06 Configurable tab width per buffer (from config/.editorconfig) (done with P0-14b)
- [x] P1-07 Regex engine module (Thompson NFA: classes, groups, alternation, quantifiers, anchors, captures) with tests
- [x] P1-08 Search upgrade: regex/case/whole-word/in-selection options, highlight all matches, match count, replace with capture groups, incremental search as you type
- [x] P1-09 Find in files: background `rg --json` (or built-in walker), results window with jump-to
- [x] P1-10 Multi-cursor: add next occurrence, add cursor above/below, Alt-click; all cursors edit and undo as one step
- [x] P1-11 Column (box) selection
- [x] P1-12 Soft wrap
- [x] P1-13 Folding by indentation with fold markers in the gutter
- [x] P1-14 Rulers; trim trailing whitespace on save; auto-closing pairs; move line up/down; join lines; sort lines; case conversion
- [x] P1-15 Keymaps: Modern (default), Turbo/WordStar (Ctrl-K/Ctrl-Q chords), Emacs-lite; user key rebinding from config; chord support
- [x] P1-16 Kitty keyboard protocol when the probe confirms it (push/pop flags, CSI u parsing, release events ignored)
- [x] P1-17 Keyboard macros: record/replay
- [x] P1-18 Encodings: UTF-8 BOM preserved, Latin-1 fallback for invalid UTF-8, mixed-EOL indicator
- [x] P1-19 Persistent undo and cursor position across sessions (state dir)
- [!] P1-20 Tree-sitter spike: check whether `libtree-sitter` and a Mojo grammar are obtainable through pixi/conda; if so bind via FFI and measure error nodes on the stdlib; record decision in the journal. If not obtainable, mark blocked and keep the lexer

## Phase 2: Language intelligence via LSP (v1.3)

- [x] P2-01 LSP client core: initialize/initialized/shutdown, capability table, restart on crash, per-project `-I` paths
- [x] P2-02 Document sync: didOpen/didChange (incremental, UTF-16 positions from the rope)/didSave/didClose with debounce
- [x] P2-03 Diagnostics: underlines (curly when supported), gutter marks, Problems window, next/previous problem
- [x] P2-04 Completion popup from the server (kinds, detail, docs panel), merged with word completion
- [x] P2-05 Hover window with Markdown-to-cells rendering
- [x] P2-06 Signature help
- [x] P2-07 Go to definition; back/forward jump list
- [x] P2-08 Find references results window
- [x] P2-09 Rename with multi-file preview and apply
- [x] P2-10 Code actions (quick-fix menu)
- [x] P2-11 Semantic tokens layered over the lexer; inlay hints (toggle)
- [x] P2-12 Outline panel: documentSymbol → scanner fallback
- [x] P2-13 IDE-side: highlight other uses of the word; background workspace symbol index with fuzzy search
- [x] P2-14 Offline docs: index `mojo doc` JSON; F1 on symbol shows its docs

## Phase 3: Workspace and project (v1.4)

- [x] P3-01 Layout tree: horizontal/vertical splits with tab groups; classic floating layout kept as an option
- [x] P3-02 Docked panels (left/bottom) hosting explorer, problems, messages, search results
- [x] P3-03 File explorer: lazy tree, create/rename/delete (to trash)/move, respects `.gitignore`
- [x] P3-04 Unified quick-open palette: files (frecency), `>` commands, `@` symbols, `:` line
- [x] P3-05 Project model: detect `pixi.toml`, list and run pixi tasks, include paths
- [x] P3-06 Run configurations (file, args, env, cwd, pre-launch build) stored per project
- [x] P3-07 Sessions: restore files, cursors, layout per project
- [x] P3-08 Workspace trust prompt

## Phase 4: Debugger via DAP (v1.5)

- [x] P4-01 DAP client on the JSON-RPC layer: initialize, launch (build with debug info first), configurationDone, events
- [x] P4-02 Breakpoints: gutter toggle, conditional, hit-count, log points, function; persisted
- [x] P4-03 Execution control with Turbo keys: step into/over/out, run to cursor, pause, terminate; current-line marker
- [x] P4-04 Call Stack and Variables views (expandable, set value)
- [x] P4-05 Watches and debug console with evaluate
- [x] P4-06 Disassembly, Registers and Memory views
- [x] P4-07 End-to-end debug test on `examples/hello.mojo` (scripted)

## Phase 5: Integrated terminal, tests, Git (v1.6)

- [x] P5-01 pty support via FFI (`forkpty`/`openpty`), non-blocking, resize
- [x] P5-02 Terminal emulation: libghostty-vt via FFI if obtainable through pixi/conda; otherwise built-in VT parser (CSI, SGR incl. truecolor, alt screen, scroll regions, cursor modes) with tests
- [x] P5-03 Terminal panel: input pass-through, scrollback, copy; Run uses it instead of leaving the TUI (old behaviour kept as option)
- [x] P5-04 REPL panel with send-selection
- [x] P5-05 Test explorer: discover TestSuite files, list via `--skip-all`, run via `--only`, tree with states, jump to failure
- [x] P5-06 Git gutter markers and status in explorer
- [x] P5-07 Git: diff view, stage/unstage/revert hunk
- [x] P5-08 Git: commit dialog, branch switch, blame
- [x] P5-09 Unified Problems/Output panels with filters

## Phase 6: Coding agents via ACP (v1.7)

- [x] P6-01 ACP client on the JSON-RPC layer: initialize, session new/prompt/update/cancel, tested against a fake agent script
- [x] P6-02 Agent panel: Markdown conversation view, streaming, file/selection mentions
- [x] P6-03 Editor services: fs read/write through buffers, diff accept/reject, terminal commands
- [x] P6-04 Permission prompts and per-session allow list; off until configured

## Phase 7: UX polish and accessibility (v1.8)

P7-07 to P7-16 come from the research report "Help that keeps users working" (reports/, kept out of git; the user asked for all ten on 2026-11-11).

- [x] P7-01 Themes as TOML files; light and high-contrast themes; follow terminal light/dark (mode 2031)
- [x] P7-02 Notification toasts and progress centre
- [x] P7-03 Help: tutorial file, cheat sheet, searchable help, What's new
- [x] P7-04 Accessibility: screen-reader (linear) mode, reduced motion
- [x] P7-05 Breadcrumbs and sticky scope header; optional minimap
- [x] P7-06 Externalised UI strings
- [x] P7-07 Calm key echo: "Next time: <key>" on the status line (active keymap) after a command is run from a menu, the palette or the mouse; stops once its key is used; never takes focus
- [x] P7-08 Hand-written explanations for the most frequent Mojo diagnostics (what, why, fix, runnable before/after), keyed by message pattern; F1 on a Problems row or the cursor's problem opens one in a split
- [x] P7-09 Docs pane beside the code that follows the cursor (Ctrl-F1 and hover results docked, updated on idle; full-screen viewer kept for study)
- [x] P7-10 Key-hint boxes after a prefix key (WordStar Ctrl-K / Ctrl-Q, Emacs C-x, chords): the next keys with their command names
- [x] P7-11 One search box for code-shaped queries: Alt-F1 takes identifiers, dotted paths and pasted error text; one-line answers in the results; cross-linked with the palette
- [x] P7-12 Breakpoint-aware notifications: toasts held while typing, delivered after a save, build or pause; the user's own job first
- [x] P7-13 Grounded "Explain" actions into the agent panel (this error, this code): send the diagnostic, code, explanation and local doc excerpts; answers cite the pages; imports checked against the installed stdlib
- [x] P7-14 Behaviour-triggered tips instead of random tips: a few rules (e.g. many page presses to a function → Go to symbol), once, at a pause, dismissible for good
- [x] P7-15 Interactive tutorial, opt-in: exercise files that fail until fixed (Rustlings style), with error-and-recovery steps; skip by experience; no launch tour
- [x] P7-16 "Coming from" pages: Python → Mojo 1.x differences (def, ownership, var; no fn) and key equivalents per keymap; linked from explanations of Python-habit errors

## Phase 8: Extensibility (v1.9)

- [x] P8-01 Plugin host: out-of-process plugins over JSON-RPC registering commands, keys, status items, event hooks; example plugin
- [x] P8-02 Plugin panels (list/cell models)
- [x] P8-03 Additional language servers by configuration (verify with one non-Mojo server if available)
- [x] P8-04 Plugin API documentation

## Phase 9: Release engineering (2.0)

- [x] P9-01 Fuzz harnesses: key parser, JSON, rope, VT parser
- [x] P9-02 Performance benchmarks script and budgets checked in `scripts/check.sh` (startup, keystroke-to-frame, 1M-line open)
- [x] P9-03 macOS portability layer for termios/ioctl constants (compile-time selected; untestable here, mark what is unverified)
- [x] P9-04 Packaging recipe (conda `recipe.yaml`), install instructions, version flag
- [x] P9-05 User guide, keymap reference, changelog; README refreshed to match reality
- [x] P9-06 Soak script (scripted editing for a long run) and leak check; final full `scripts/check.sh` pass

## Phase 10: UI clarity and calm (v2.1)

From reports/TurboMojo UI improvements.md (the recommendation each task comes from in
brackets; where TurboMojo already did part of it, only the rest is a task).

- [x] P10-01 Redundant focus cues in both layouts: the focused window/pane with a bright double frame, bold title and the only cursor; unfocused ones with a dim single frame and a muted "inactive selection" row; the active tab marked by glyph as well as colour [1]
- [x] P10-02 Never colour-only diagnostics: E/W/i glyphs in the gutter and the Problems page, and undercurl with an SGR 58 colour where the terminal supports it (probed), else a plain underline [2]
- [x] P10-03 A "Terminal ANSI" theme using only the 16 palette colours and the default foreground/background, and honour NO_COLOR [3]
- [x] P10-04 Contrast gate for every theme and token in the tests (WCAG ratio floor plus APCA Lc 75 code / 60 secondary / 30 disabled), extending the Paper Light / High Contrast test; fix what fails [4]
- [x] P10-05 Calm by default: screen-reader mode implies reduced motion; a test that toasts and background events never take focus or move the hardware cursor; modal dialogs only for decisions [5, 13]
- [x] P10-06 Response-time ladder for build, run, tests and the agent: nothing under 1 s, a status-line spinner 1-10 s, beyond 10 s what is done so far and the cancel key in the Compiling box [6]
- [x] P10-07 OSC 8 links on every file:line in the Message, Search and Problems pages and agent output [7]
- [x] P10-08 Show the exact toolchain command at the top of each Message page run [8]
- [x] P10-09 Key-hint boxes after ~200 ms (now 600), never over the cursor, with on/off state for toggles [9]
- [x] P10-10 Probe hardening: ask CSI ? 996 n for the colour scheme, OSC 11 luminance fallback, DECRQSS truecolor and XTGETTCAP Smulx/Setulc, no DCS under GNU screen, trust tmux's answers, drain late replies, always pop kitty keyboard flags and close synchronized output on error paths [10]
- [x] P10-11 Glyph tiers `glyphs = ascii | unicode | nerd` (default unicode) and a half-block fallback for the braille minimap; no emoji or ambiguous-width characters in the chrome [11]
- [x] P10-12 text-muted and text-disabled colours used consistently in menus, the palette and the status line; dim the UI while the terminal loses focus (mode 1004) [12]
- [x] P10-13 Counts and filters in titles: Problems "(3 E, 7 W)", the explorer's filter, the palette's "12/340" [14]
- [x] P10-14a Screen-reader mode, first part: labelled status lines (build:, agent:, test:, git:, error:, warning:), numbered menus (with "(on)" / "(not now)") and dialog buttons picked by their number, typed y/n, the bell when a build, the tests, a task or the agent finishes or asks; on with TERM=dumb as with TURBOMOJO_SCREEN_READER=1 [A]
- [x] P10-14b Screen-reader mode as a true linear mode: a line mode without cursor addressing for TERM=dumb (prompts and output as lines, as in an Emacs shell buffer) [A]
- [x] P10-14c OSC 133 marks (prompt, command, output, end) around a program run on the user screen and in the IDE's terminal windows, so terminals can jump between runs [A]
- [x] P10-15 Cursor discipline in the full UI: the hardware cursor always on the focused caret or row; status, minimap, spinner and toast updates never leave it elsewhere; unchanged cells never rewritten [B]
- [x] P10-16 Responsive layout (split into a-c below) [C]
- [x] P10-16a Responsive layout, first part: a "terminal too small" screen below a minimum size, and the minimap, breadcrumbs and gutter hidden below widths where they would crowd the text [C]
- [x] P10-16b One-key zoom of the focused pane in three steps (normal, half, full) [C]
- [x] P10-16c Stacking on narrow terminals: the tiled layout's side panes go above / below the editor instead of beside it [C]
- [x] P10-17 Navigation memory (split into a-b below): most-recent ordering in the palette and F6, per-tab cursor, scroll and fold state that survives pane moves and restarts (back/forward exists: Alt-, Alt-.) [D]
- [x] P10-17a Navigation memory, first part: the commands used last come first in the command palette (kept across restarts), and F6 goes to the window used last, further back on each press in a row [D]
- [x] P10-17b Navigation memory, second part: a file's cursor, scroll and folds remembered when it is closed and across restarts (the session keeps folds too), and kept when a tab moves to another pane [D]
- [ ] P10-18 Semantic colour roles under all themes (surface, panel, text, text-muted, text-disabled, border, border-blurred, cursor, cursor-blurred, diag-error, diag-warn) with designed truecolor, 256 and 16 values; an Okabe-Ito colour-blind theme with its own contrast test (split into a-b below) [E]
- [x] P10-18a An Okabe-Ito colour-blind theme, with a colour-vision check (simulated protanopia, deuteranopia, tritanopia) that keeps its severities, git markers and main syntax classes apart, and the contrast floors [E]
- [ ] P10-18b Semantic colour roles under all themes (surface, panel, text, text-muted, text-disabled, border, border-blurred, cursor, cursor-blurred, diag-error, diag-warn) with designed truecolor, 256 and 16 values; the other themes through the colour-vision check (Paper Light's error and warning fall together with deuteranopia) [E]
- [ ] P10-19 A restrained syntax palette (4-6 token classes, errors, search hits and the current line most salient) as the default's alternative, richer colouring stays a theme option [F]
- [ ] P10-20 Theme follows the terminal live (2031 / 996 / OSC 11) and a muted low-saturation Turbo variant; the first run asks, with a preview [G]
- [ ] P10-21 Grapheme-width discipline: mode 2027 where reported, else the width table plus a cursor-position measurement for doubtful glyphs; Unicode-safe hot letters [H]
- [ ] P10-22 Inline images in the docs pane (kitty graphics with Unicode placeholders under tmux, sixel), with a text fallback [I]
