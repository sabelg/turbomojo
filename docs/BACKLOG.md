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
- [ ] P3-04 Unified quick-open palette: files (frecency), `>` commands, `@` symbols, `:` line
- [ ] P3-05 Project model: detect `pixi.toml`, list and run pixi tasks, include paths
- [ ] P3-06 Run configurations (file, args, env, cwd, pre-launch build) stored per project
- [ ] P3-07 Sessions: restore files, cursors, layout per project
- [ ] P3-08 Workspace trust prompt

## Phase 4: Debugger via DAP (v1.5)

- [ ] P4-01 DAP client on the JSON-RPC layer: initialize, launch (build with debug info first), configurationDone, events
- [ ] P4-02 Breakpoints: gutter toggle, conditional, hit-count, log points, function; persisted
- [ ] P4-03 Execution control with Turbo keys: step into/over/out, run to cursor, pause, terminate; current-line marker
- [ ] P4-04 Call Stack and Variables views (expandable, set value)
- [ ] P4-05 Watches and debug console with evaluate
- [ ] P4-06 Disassembly, Registers and Memory views
- [ ] P4-07 End-to-end debug test on `examples/hello.mojo` (scripted)

## Phase 5: Integrated terminal, tests, Git (v1.6)

- [ ] P5-01 pty support via FFI (`forkpty`/`openpty`), non-blocking, resize
- [ ] P5-02 Terminal emulation: libghostty-vt via FFI if obtainable through pixi/conda; otherwise built-in VT parser (CSI, SGR incl. truecolor, alt screen, scroll regions, cursor modes) with tests
- [ ] P5-03 Terminal panel: input pass-through, scrollback, copy; Run uses it instead of leaving the TUI (old behaviour kept as option)
- [ ] P5-04 REPL panel with send-selection
- [ ] P5-05 Test explorer: discover TestSuite files, list via `--skip-all`, run via `--only`, tree with states, jump to failure
- [ ] P5-06 Git gutter markers and status in explorer
- [ ] P5-07 Git: diff view, stage/unstage/revert hunk
- [ ] P5-08 Git: commit dialog, branch switch, blame
- [ ] P5-09 Unified Problems/Output panels with filters

## Phase 6: Coding agents via ACP (v1.7)

- [ ] P6-01 ACP client on the JSON-RPC layer: initialize, session new/prompt/update/cancel, tested against a fake agent script
- [ ] P6-02 Agent panel: Markdown conversation view, streaming, file/selection mentions
- [ ] P6-03 Editor services: fs read/write through buffers, diff accept/reject, terminal commands
- [ ] P6-04 Permission prompts and per-session allow list; off until configured

## Phase 7: UX polish and accessibility (v1.8)

- [ ] P7-01 Themes as TOML files; light and high-contrast themes; follow terminal light/dark (mode 2031)
- [ ] P7-02 Notification toasts and progress centre
- [ ] P7-03 Help: tutorial file, cheat sheet, searchable help, What's new
- [ ] P7-04 Accessibility: screen-reader (linear) mode, reduced motion
- [ ] P7-05 Breadcrumbs and sticky scope header; optional minimap
- [ ] P7-06 Externalised UI strings

## Phase 8: Extensibility (v1.9)

- [ ] P8-01 Plugin host: out-of-process plugins over JSON-RPC registering commands, keys, status items, event hooks; example plugin
- [ ] P8-02 Plugin panels (list/cell models)
- [ ] P8-03 Additional language servers by configuration (verify with one non-Mojo server if available)
- [ ] P8-04 Plugin API documentation

## Phase 9: Release engineering (2.0)

- [ ] P9-01 Fuzz harnesses: key parser, JSON, rope, VT parser
- [ ] P9-02 Performance benchmarks script and budgets checked in `scripts/check.sh` (startup, keystroke-to-frame, 1M-line open)
- [ ] P9-03 macOS portability layer for termios/ioctl constants (compile-time selected; untestable here, mark what is unverified)
- [ ] P9-04 Packaging recipe (conda `recipe.yaml`), install instructions, version flag
- [ ] P9-05 User guide, keymap reference, changelog; README refreshed to match reality
- [ ] P9-06 Soak script (scripted editing for a long run) and leak check; final full `scripts/check.sh` pass
