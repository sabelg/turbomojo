# Changelog

What each version brought, made from the roadmap's finished tasks (docs/BACKLOG.md) and the
day each was done (docs/JOURNAL.md) by `scripts/gen_docs.py`. The current version is 2.0.0;
docs/JOURNAL.md has, for every task, what changed, how it was checked and what is not done.

## 2.1: UI clarity and calm (in progress: 10 tasks to go)

- Redundant focus cues in both layouts: the focused window/pane with a bright double frame, bold title and the only cursor; unfocused ones with a dim single frame and a muted "inactive selection" row; the active tab marked by glyph as well as colour [1] (P10-01)
- Never colour-only diagnostics: E/W/i glyphs in the gutter and the Problems page, and undercurl with an SGR 58 colour where the terminal supports it (probed), else a plain underline [2] (P10-02)
- A "Terminal ANSI" theme using only the 16 palette colours and the default foreground/background, and honour NO_COLOR [3] (P10-03)
- Contrast gate for every theme and token in the tests (WCAG ratio floor plus APCA Lc 75 code / 60 secondary / 30 disabled), extending the Paper Light / High Contrast test; fix what fails [4] (P10-04)
- Calm by default: screen-reader mode implies reduced motion; a test that toasts and background events never take focus or move the hardware cursor; modal dialogs only for decisions [5, 13] (P10-05)
- Response-time ladder for build, run, tests and the agent: nothing under 1 s, a status-line spinner 1-10 s, beyond 10 s what is done so far and the cancel key in the Compiling box [6] (P10-06)
- OSC 8 links on every file:line in the Message, Search and Problems pages and agent output [7] (P10-07)
- Show the exact toolchain command at the top of each Message page run [8] (P10-08)
- Key-hint boxes after ~200 ms (now 600), never over the cursor, with on/off state for toggles [9] (P10-09)
- Probe hardening: ask CSI ? 996 n for the colour scheme, OSC 11 luminance fallback, DECRQSS truecolor and XTGETTCAP Smulx/Setulc, no DCS under GNU screen, trust tmux's answers, drain late replies, always pop kitty keyboard flags and close synchronized output on error paths [10] (P10-10)
- Glyph tiers `glyphs = ascii | unicode | nerd` (default unicode) and a half-block fallback for the braille minimap; no emoji or ambiguous-width characters in the chrome [11] (P10-11)
- text-muted and text-disabled colours used consistently in menus, the palette and the status line; dim the UI while the terminal loses focus (mode 1004) [12] (P10-12)

## 2.0: Release engineering - 2026-11-12

- Fuzz harnesses: key parser, JSON, rope, VT parser (P9-01)
- Performance benchmarks script and budgets checked in `scripts/check.sh` (startup, keystroke-to-frame, 1M-line open) (P9-02)
- macOS portability layer for termios/ioctl constants (compile-time selected; untestable here, mark what is unverified) (P9-03)
- Packaging recipe (conda `recipe.yaml`), install instructions, version flag (P9-04)
- User guide, keymap reference, changelog; README refreshed to match reality (P9-05)
- Soak script (scripted editing for a long run) and leak check; final full `scripts/check.sh` pass (P9-06)

## 1.9: Extensibility - 2026-11-12

- Plugin host: out-of-process plugins over JSON-RPC registering commands, keys, status items, event hooks; example plugin (P8-01)
- Plugin panels (list/cell models) (P8-02)
- Additional language servers by configuration (verify with one non-Mojo server if available) (P8-03)
- Plugin API documentation (P8-04)

## 1.8: UX polish and accessibility - 2026-11-12

- Themes as TOML files; light and high-contrast themes; follow terminal light/dark (mode 2031) (P7-01)
- Notification toasts and progress centre (P7-02)
- Help: tutorial file, cheat sheet, searchable help, What's new (P7-03)
- Accessibility: screen-reader (linear) mode, reduced motion (P7-04)
- Breadcrumbs and sticky scope header; optional minimap (P7-05)
- Externalised UI strings (P7-06)
- Calm key echo: "Next time: <key>" on the status line (active keymap) after a command is run from a menu, the palette or the mouse; stops once its key is used; never takes focus (P7-07)
- Hand-written explanations for the most frequent Mojo diagnostics (what, why, fix, runnable before/after), keyed by message pattern; F1 on a Problems row or the cursor's problem opens one in a split (P7-08)
- Docs pane beside the code that follows the cursor (Ctrl-F1 and hover results docked, updated on idle; full-screen viewer kept for study) (P7-09)
- Key-hint boxes after a prefix key (WordStar Ctrl-K / Ctrl-Q, Emacs C-x, chords): the next keys with their command names (P7-10)
- One search box for code-shaped queries: Alt-F1 takes identifiers, dotted paths and pasted error text; one-line answers in the results; cross-linked with the palette (P7-11)
- Breakpoint-aware notifications: toasts held while typing, delivered after a save, build or pause; the user's own job first (P7-12)
- Grounded "Explain" actions into the agent panel (this error, this code): send the diagnostic, code, explanation and local doc excerpts; answers cite the pages; imports checked against the installed stdlib (P7-13)
- Behaviour-triggered tips instead of random tips: a few rules (e.g. many page presses to a function → Go to symbol), once, at a pause, dismissible for good (P7-14)
- Interactive tutorial, opt-in: exercise files that fail until fixed (Rustlings style), with error-and-recovery steps; skip by experience; no launch tour (P7-15)
- "Coming from" pages: Python → Mojo 1.x differences (def, ownership, var; no fn) and key equivalents per keymap; linked from explanations of Python-habit errors (P7-16)

## 1.7: Coding agents via ACP - 2026-11-11

- ACP client on the JSON-RPC layer: initialize, session new/prompt/update/cancel, tested against a fake agent script (P6-01)
- Agent panel: Markdown conversation view, streaming, file/selection mentions (P6-02)
- Editor services: fs read/write through buffers, diff accept/reject, terminal commands (P6-03)
- Permission prompts and per-session allow list; off until configured (P6-04)

## 1.6: Integrated terminal, tests, Git - 2026-11-11

- pty support via FFI (`forkpty`/`openpty`), non-blocking, resize (P5-01)
- Terminal emulation: libghostty-vt via FFI if obtainable through pixi/conda; otherwise built-in VT parser (CSI, SGR incl. truecolor, alt screen, scroll regions, cursor modes) with tests (P5-02)
- Terminal panel: input pass-through, scrollback, copy; Run uses it instead of leaving the TUI (old behaviour kept as option) (P5-03)
- REPL panel with send-selection (P5-04)
- Test explorer: discover TestSuite files, list via `--skip-all`, run via `--only`, tree with states, jump to failure (P5-05)
- Git gutter markers and status in explorer (P5-06)
- Git: diff view, stage/unstage/revert hunk (P5-07)
- Git: commit dialog, branch switch, blame (P5-08)
- Unified Problems/Output panels with filters (P5-09)

## 1.5: Debugger via DAP - 2026-11-10

- DAP client on the JSON-RPC layer: initialize, launch (build with debug info first), configurationDone, events (P4-01)
- Breakpoints: gutter toggle, conditional, hit-count, log points, function; persisted (P4-02)
- Execution control with Turbo keys: step into/over/out, run to cursor, pause, terminate; current-line marker (P4-03)
- Call Stack and Variables views (expandable, set value) (P4-04)
- Watches and debug console with evaluate (P4-05)
- Disassembly, Registers and Memory views (P4-06)
- End-to-end debug test on `examples/hello.mojo` (scripted) (P4-07)

## 1.4: Workspace and project - 2026-11-10

- Layout tree: horizontal/vertical splits with tab groups; classic floating layout kept as an option (P3-01)
- Docked panels (left/bottom) hosting explorer, problems, messages, search results (P3-02)
- File explorer: lazy tree, create/rename/delete (to trash)/move, respects `.gitignore` (P3-03)
- Unified quick-open palette: files (frecency), `>` commands, `@` symbols, `:` line (P3-04)
- Project model: detect `pixi.toml`, list and run pixi tasks, include paths (P3-05)
- Run configurations (file, args, env, cwd, pre-launch build) stored per project (P3-06)
- Sessions: restore files, cursors, layout per project (P3-07)
- Workspace trust prompt (P3-08)

## 1.3: Language intelligence via LSP - 2026-11-10

- LSP client core: initialize/initialized/shutdown, capability table, restart on crash, per-project `-I` paths (P2-01)
- Document sync: didOpen/didChange (incremental, UTF-16 positions from the rope)/didSave/didClose with debounce (P2-02)
- Diagnostics: underlines (curly when supported), gutter marks, Problems window, next/previous problem (P2-03)
- Completion popup from the server (kinds, detail, docs panel), merged with word completion (P2-04)
- Hover window with Markdown-to-cells rendering (P2-05)
- Signature help (P2-06)
- Go to definition; back/forward jump list (P2-07)
- Find references results window (P2-08)
- Rename with multi-file preview and apply (P2-09)
- Code actions (quick-fix menu) (P2-10)
- Semantic tokens layered over the lexer; inlay hints (toggle) (P2-11)
- Outline panel: documentSymbol → scanner fallback (P2-12)
- IDE-side: highlight other uses of the word; background workspace symbol index with fuzzy search (P2-13)
- Offline docs: index `mojo doc` JSON; F1 on symbol shows its docs (P2-14)

## 1.2: Editor core - 2026-11-10

- Rope on a B-tree with summaries (bytes, lines, UTF-16 units) as a standalone module with exhaustive tests against a naive reference (P1-01)
- Port `TextBuffer` onto the rope behind the same API; undo/redo intact; all Phase 0 tests still pass (P1-02)
- Line metadata cache (visual width, lexer end state); incremental highlighting that re-lexes only from the edited line until states converge (P1-03)
- Grapheme cluster segmentation (UAX #29 extended clusters) with tests; cursor, delete and selection move by cluster; screen cells hold full clusters (P1-04)
- Large-file behaviour: open a generated 1M-line file under 1 s; large-file mode above 50 MB; benchmark script recorded in the journal (P1-05)
- Configurable tab width per buffer (from config/.editorconfig) (done with P0-14b) (P1-06)
- Regex engine module (Thompson NFA: classes, groups, alternation, quantifiers, anchors, captures) with tests (P1-07)
- Search upgrade: regex/case/whole-word/in-selection options, highlight all matches, match count, replace with capture groups, incremental search as you type (P1-08)
- Find in files: background `rg --json` (or built-in walker), results window with jump-to (P1-09)
- Multi-cursor: add next occurrence, add cursor above/below, Alt-click; all cursors edit and undo as one step (P1-10)
- Column (box) selection (P1-11)
- Soft wrap (P1-12)
- Folding by indentation with fold markers in the gutter (P1-13)
- Rulers; trim trailing whitespace on save; auto-closing pairs; move line up/down; join lines; sort lines; case conversion (P1-14)
- Keymaps: Modern (default), Turbo/WordStar (Ctrl-K/Ctrl-Q chords), Emacs-lite; user key rebinding from config; chord support (P1-15)
- Kitty keyboard protocol when the probe confirms it (push/pop flags, CSI u parsing, release events ignored) (P1-16)
- Keyboard macros: record/replay (P1-17)
- Encodings: UTF-8 BOM preserved, Latin-1 fallback for invalid UTF-8, mixed-EOL indicator (P1-18)
- Persistent undo and cursor position across sessions (state dir) (P1-19)

## 1.1: Foundations - 2026-11-10

- Test harness: `tests/` directory with TestSuite files run by `scripts/check.sh`; first tests for `util.mojo` (UTF-8 decode/encode, `char_width`, `pad_right`, paths, `fuzzy_score`, `base64`) (P0-01)
- Tests for `buffer.mojo`: load/save round-trip (tabs, CRLF, final newline), insert/delete, undo/redo, grouped undo, plus a randomised edit/undo/redo consistency test with a fixed seed (P0-02)
- Make the key parser testable without a tty (feed bytes, get events) and test it: arrows, modifiers, F-keys, Alt, UTF-8, SGR mouse press/drag/release/wheel, bracketed paste, lone ESC (P0-03)
- Tests for `highlight.mojo`: keywords, strings, triple-quoted state across lines, numbers, decorators, comments (P0-04)
- Headless screen snapshots: render `Screen` to plain text; golden-file tests for menu bar, a dropdown, a dialog, an editor window with wide characters (P0-05)
- Tests for `window.mojo` editing: typing, auto-indent, backspace unindent, tab/shift-tab, toggle comment, duplicate/delete line, selection, find/replace, bracket match, visual columns with tabs and wide chars (P0-06)
- Mouse handling tests through the app with synthetic events: click to place cursor, drag select, wheel scroll, title-bar move, corner resize, close box, menu clicks, dialog clicks. Fix whatever fails (P0-07)
- Command registry: one table of commands (id, title, default keys, hint); menus, palette, shortcuts and help generated from it (P0-08)
- Split `app.mojo` into modules (commands, files, jobs, dialogs-flow, mouse, draw); no source file over ~700 lines (P0-09)
- `poll()`-based event loop over stdin and child pipes with timers, replacing VTIME polling; idle wakeups only for the clock/spinner (P0-10)
- Signals through a self-pipe: SIGWINCH resize, SIGTERM/SIGHUP save-and-exit, SIGTSTP/SIGCONT suspend and restore (P0-11)
- Crash safety: terminal always restored on error paths; crash log under `~/.local/state/turbomojo/` (P0-12)
- Terminal capability probe (`Caps`): kitty keyboard, modes 2026/2027/2031/2048 via DECRQM, truecolor detection with 256/16-colour fallback rendering (P0-13)
- Config: TOML subset parser; `~/.config/turbomojo/config.toml` and project `.turbomojo.toml`; all Options persist; key rebinding from config (P0-14a)
- Honour `.editorconfig` (indent style/size, EOL, final newline, trim trailing whitespace) (P0-14b)
- Swap files and crash recovery (write every 2 s when dirty; offer recovery on open) (P0-15)
- External change detection (inotify via FFI, or mtime polling fallback): reload clean buffers, ask for modified ones (P0-16)
- JSON parser/writer module with tests (objects, arrays, strings with escapes and \u, numbers, bool, null) (P0-17)
- JSON-RPC transport (`Content-Length` framing over a child's pipes, non-blocking, request table) with tests against a fake server script (P0-18)
- Spike: start `mojo-lsp-server`, open the current file, show its diagnostics in the Message window; record measured latency in `docs/JOURNAL.md` (P0-19)
- Move `pixi.toml` to the stable Mojo 1.x channel if the code builds there; otherwise record what blocks it (P0-20)
- CI workflow file (`.github/workflows/ci.yml`) running `scripts/check.sh` on linux-64 and linux-aarch64 (not pushed; file only) (P0-21)

## 1.0: the Turbo C++ tribute

Overlapping windows, the menu bar and dialogs of Turbo C++ 3.0, the editor with undo,
syntax colours, mouse, build and run - before the roadmap.
