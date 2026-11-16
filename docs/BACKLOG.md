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
- [x] P10-18 Semantic colour roles under all themes (surface, panel, text, text-muted, text-disabled, border, border-blurred, cursor, cursor-blurred, diag-error, diag-warn) with designed truecolor, 256 and 16 values; an Okabe-Ito colour-blind theme with its own contrast test (split into a-c below) [E]
- [x] P10-18a An Okabe-Ito colour-blind theme, with a colour-vision check (simulated protanopia, deuteranopia, tritanopia) that keeps its severities, git markers and main syntax classes apart, and the contrast floors [E]
- [x] P10-18b Semantic colour roles ([roles]: surface, panel, text, text-muted, text-disabled, border, border-blurred, cursor, diag-error, diag-warn) and colours designed for 256 and 16 colours ([colors256], [colors16]) under every built-in theme, each reaching the contrast floors as such a terminal shows it [E]
- [x] P10-18c The other themes through the colour-vision check (Paper Light's error and warning fall together with deuteranopia, High Contrast's git add / change with tritanopia; Classic, Midnight, Amber not yet measured), fixed where they fail [E]
- [x] P10-19 A restrained syntax palette (4-6 token classes, errors, search hits and the current line most salient) as the default's alternative, richer colouring stays a theme option [F]
- [x] P10-20 Theme follows the terminal live (2031 / 996 / OSC 11) and a muted low-saturation Turbo variant; the first run asks, with a preview (split into a-b below) [G]
- [x] P10-20a The theme follows the terminal live where it only reports its background (OSC 11 asked again on focus and every half minute; 2031 / 996 were followed already), and Turbo Muted, a low-saturation Turbo Classic [G]
- [x] P10-20b The first run asks which theme, with a preview of each (dark / light / auto, Turbo or modern) [G]
- [x] P10-21 Grapheme-width discipline: mode 2027 where reported, else the width table plus a cursor-position measurement for doubtful glyphs; Unicode-safe hot letters [H]
  - [x] P10-21a Width measurement at start-up (cursor-position reports for doubtful glyphs), the layout chosen by it, narrow emoji padded, the next cell placed explicitly after a doubtful glyph
  - [x] P10-21b Unicode-safe hot letters (non-ASCII and accented hot letters, case-folded matching, a clear rule for labels without one)
- [x] P10-22 Inline images in the docs pane (kitty graphics with Unicode placeholders under tmux, sixel), with a text fallback [I]
  - [x] P10-22a The text fallback (Markdown and HTML images as "[image: alt]" links that keep the picture's source) and the probe for kitty graphics and sixel
  - [x] P10-22b Kitty graphics: a local PNG shown in the reader, transmitted as it is and placed with Unicode placeholders (so it works through tmux), rows reserved in the page, deleted when the page changes
  - [x] P10-22c Sixel: PNG decoded (inflate and filters), scaled to the cells, quantised to a palette, sent as sixel

## Phase 11: Ready for other people (v2.2)

From reports/Making TurboMojo something people use.md (the recommendation each task comes
from in brackets). Not tasks for the runner, because they publish or are the user's to
decide: the licence, merging the branches, pushing, the public conda channel, and posting
in the Modular forum [1, 2, 4, 16, 17].

- [x] P11-01 README first screen: a two-line pitch (ready to use, runs over SSH, starts in 50 ms, explains Mojo's errors), a "Why TurboMojo?" section comparing it honestly with VS Code + the Mojo extension, and the terminal-capability details moved to docs/USER_GUIDE.md [8, 9]
- [x] P11-02 Pictures of the IDE made from itself: `tmide --screenshot FILE.svg` (the screen buffer as SVG, with the theme's colours) and a script that records a short demo through tmux as an asciinema cast; three screenshots (Turbo Classic, a modern theme, the docs reader) and the cast linked from the README [7]
- [x] P11-03 Mojo version check: the Mojo version TurboMojo was built with is recorded; when the `mojo` found differs, the status line and `tmide --caps` say so plainly, instead of the language server or builds failing in strange ways [5]
- [x] P11-04 File > New project: makes a pixi project with Mojo (`pixi init`, the Modular channel, `mojo` as a dependency), a hello.mojo and a test, and opens them; offered by the welcome screen when the folder has no project [13]
- [x] P11-05 First-run checklist (also Help > Check setup): Mojo found and its version, the language server, the debugger, the docs downloaded, the terminal's colours and keys; each missing piece with the command or button that fixes it [14]
- [x] P11-06 A "Modern" start besides the Turbo look, in the first-run question: tiled layout, explorer open, VS Code keys and a calm theme in one choice (and Options > Presets to switch later) [15]
- [x] P11-07 Working on a remote machine over SSH: a user-guide page (clipboard through OSC 52, mouse, colours, pictures through tmux, keys that SSH clients take), and tests for what it needs (OSC 52 copy when there is no local clipboard tool, no DISPLAY / WAYLAND_DISPLAY) [10]
- [x] P11-08 Help > Report a problem: writes a ready-to-file issue text (versions, `--caps` output, the last crash-log entry, the config with anything secret-looking removed) to a file and the clipboard; it sends nothing [19]
- [x] P11-09 Contributing: CONTRIBUTING.md (building, the gate, docs/SOURCE.md, docs/JOURNAL.md), issue templates asking for `tmide --caps` output, and a GitHub Actions workflow that runs the tests (written, not run here) [3, 18]
- [x] P11-10 GPU awareness (split into a-c below) [11]
  - [x] P11-10a The GPU the program will run on (nvidia-smi, rocm-smi, or none) in `--caps` and as an optional status-line item, read once in the background
  - [x] P11-10b A run's time and the GPU it used in the Message window after Ctrl-F9
  - [x] P11-10c "Check my answer" for the GPU puzzles in the docs reader, as the exercises have
- [x] P11-11 A copy-to-the-server bundle: `pixi run bundle` makes a tar file with tmide and the Mojo runtime libraries it needs, which runs after unpacking on another Linux machine with the same glibc (checked in a clean folder without the project's .pixi) [12]
- [!] P11-12 macOS, first part: osx-arm64 in pixi's platforms and the build linked for it where the toolchain allows that here; running it needs a Mac, so that part becomes [!] with what was checked [6]
  Blocked on running it: there is no Mac here. Done and checked: osx-arm64 in pixi.toml and pixi.lock; `scripts/macos-link.sh` compiles for arm64-apple-macosx14.0 and links with ld64.lld against the osx-arm64 packages and a libSystem stub - an arm64 Mach-O executable, signed ad hoc, no undefined symbol (the link found close_range, Linux-only, now replaced on macOS). See the journal.
- [x] P11-13 Install what a program uses (asked by the user, 2026-11-13): when a build or run fails because a Mojo module (`unable to locate module 'max'`) or a Python one (`No module named 'numpy'`) is not installed, TurboMojo names it, finds the package on the project's channels, and offers to install it (`pixi add`, in the background), then runs again; without a pixi.toml it offers to make one first; nothing is installed without a yes
- [x] P11-14 The documentation of what a program uses (asked by the user with P11-13, 2026-11-13): F1 / Ctrl-F1 on a name of a Python library the file imports (`np.zeros` with `var np = Python.import_module("numpy")`) shows pydoc's text from the project's Python; the language server runs in the project's environment, so the Mojo packages installed there (which come compiled) have their documentation on hover and Ctrl-F1, completion and errors; an install restarts it
- [x] P11-15 Install and documentation in the running IDE (asked by the user, 2026-11-13): with scripts/tui-test.sh, the real TurboMojo and the real pixi in a scratch project - a file that imports numpy fails, the offer, Install, it runs; F1 on `np.zeros`; hover on a MAX name with the project's language server. Fix what breaks
- [x] P11-16 The language server follows the project: when the file in front belongs to another pixi environment than the running server's, the server is started again for it (its packages, its include paths)
- [x] P11-17 Release 2.2: TurboMojo 2.2.0 (version, What's new, CHANGELOG, the conda package built and its tests run); the tag is made here and pushed only with the user's word

## Phase 12: A vim interface (v2.3)

Asked by the user (2026-11-13), for people who do not like the retro look: the everyday
part of vim, as editors with a "vim mode" have it - not Vimscript, vim plugins or .vimrc.
The Turbo, Modern and Emacs keymaps stay as they are.

- [x] P12-01 Modal editing core: `ui.keymap = "vim"` (and Options > Keys); Normal, Insert and Visual (characters and lines) modes; the mode in the status line; the cursor a block in Normal and a bar in Insert (DECSCUSR, where the terminal has it); Esc and i a I A o O v V
- [x] P12-02 Motions and operators: h j k l w b e W B E 0 ^ $ gg G f t F T ; , % { } with counts; d c y p P x r J > < with motions and counts (dd, 3dw, cw, yy); text objects iw aw i" a" i( a( i{ ip; `.` repeats the last change; u and Ctrl-R undo and redo
- [x] P12-03 Search and commands: / ? n N * #; `:w :q :wq :x :q! :e FILE :N :s/a/b/g :%s/a/b/g`, and `:` with TurboMojo's own commands (`:build`, `:run`, the command palette's names)
- [x] P12-04 Registers and the clipboard: the unnamed register, "a-"z, "0, and "+ / "* through the clipboard TurboMojo already uses (OSC 52 over SSH)
- [x] P12-05 A "Vim" preset (Options > Presets, and the first-run question): the Modern look, the vim keys, relative line numbers (`editor.relative_numbers`, new); the menu bar still reachable with F10 and Alt

## Phase 13: Mojo 1.2 & GPU developer milestone (v2.4)

40-feature end-to-end IDE milestone (`F01`–`F40`), verified by `tests/e2e/test_f01_*.mojo` through `tests/e2e/test_f40_*.mojo` in the sharded `scripts/check.sh` gate.

- [x] P13-01 Async `mojo doc` (`aux_job` pipe), warm 2-server `lsp_pool`, Mojo 1.2 quick fixes (`Alt-Enter`), multi-tabstop snippets, and full polyglot extra-server LSP parity (`F01`–`F06`, `F17`, `F20`)
- [x] P13-02 `std.benchmark` runner with JSON baseline regression deltas and inline ns/op badges, PTX/AMDGCN/ASM/LLVM codegen inspector with live cursor sync, GPU monitor & roofline profiler, and MAX serve / benchmark launcher (`F07`–`F10`)
- [x] P13-03 Test Explorer watch-on-save, line coverage gutter, one-key failed-test debugging, and `# %%` Mojo/Python interactive code cells with execution badges and kernel reset (`F11`–`F12`)
- [x] P13-04 DAP live attach to PID, `coredumpctl` post-mortem core dumps, conditional/hit-count/logpoint breakpoints, inline variable ghosts, GPU lane/block focus, and CPU SIMD/FP16/BF16 lane inspector (`F13`–`F16`)
- [x] P13-05 Workspace call & type hierarchy (`CM_CALL_HIERARCHY` / `CM_TYPE_HIERARCHY`) and inline cursor-anchored PeekBox (`Alt-Shift-F12`) with Git hunk preview (`S` stage / `R` revert) (`F18`–`F19`)
- [x] P13-06 Branching undo tree (`D_UNDO_TREE`, `g-`/`g+`), auto-detected read-only hex viewer (`WK_HEX`), structural selection & multi-cursor editing, regex streaming Replace in Files with atomic multi-file undo, and rainbow brackets (`F21`–`F25`)
- [x] P13-07 Interactive minimap & scrollbar scrubbing, overview ruler ticks, draggable tiled splitters, disambiguated & pinned tabs (`CM_PIN_TAB`), middle-click tab close, and scroll-synced GFM Markdown preview (`WK_MDPREVIEW`) (`F26`–`F27`)
- [x] P13-08 Complete Vim polish: `:set` option bridging, `:marks`/`:registers`, `gn`/`gN`, `g;`/`g,`, `gv`, `q:`/`q/` history window, and uppercase file marks (`F28`)
- [x] P13-09 Interactive Git commit graph (`WK_GITLOG`), side-by-side split diff & 3-way conflict resolution, async push/pull/fetch & stash picker, MRU project switcher, and Git worktree manager (`F29`–`F32`)
- [x] P13-10 Multi-hunk agent diff review, `@doc`/`@symbol` prompt grounding, IPC/MCP co-debugging, Plugin API v2 (`editor/edit`, `diagnostics/set`, manager dialog), multi-tab terminal, SSH/tmux clipboard & port-forward toasts, `.gitignore` explorer/watcher, and extended `--lines` & screen-reader context cues (`F33`–`F40`)

## Phase 14: Terminal notebooks, refactorings & zero-config projects (v2.5)

End-to-end terminal notebook execution, Jupyter `.ipynb` interop & inline plots, zero-config multi-project discovery, structural refactorings & Mojo 1.2 migration assistant, live codegen cursor sync & GPU register pressure badges, and memory-safe CI/release polish.

- [x] P14-01 Persistent non-blocking `mojo repl` & `python3` `# %%` cell kernels (`Ctrl-Enter` / `Ctrl-Shift-Enter`), FD-level prior-cell stdout suppression, `NotebookVirtualDoc` live `mojo-lsp-server` virtualization, exact error-line remapping, and outline cell hierarchy & folding (`src/cells.mojo`, `tests/e2e/test_f12_cell_kernel.mojo`)
- [x] P14-02 Zero-config upward project & `src/` package root auto-discovery from any `.mojo` / `.🔥` file across LSP, Build, Run, Debug, Test, Codegen, and cell kernels, with per-subproject warm `lsp_pool` keying (`src/project.mojo`, `src/appstate.mojo`, `tests/e2e/test_v25_project_autodiscover.mojo`)
- [x] P14-03 Bidirectional Jupyter `.ipynb` (nbformat v4) open/save & `CM_EXPORT_IPYNB` plus automatic `matplotlib` / PNG inline terminal plot capture and Kitty / Sixel / half-block preview (`src/ipynb.mojo`, `src/cells.mojo`, `src/app_docs.mojo`, `tests/e2e/test_v25_ipynb_plots.mojo`)
- [x] P14-04 One-click Mojo 1.2 Migration Assistant (`CM_MIGRATE_MOJO12`, `CM_MIGRATE_MOJO12_PROJECT`, and `Ctrl-.` quick fix) plus `CM_EXTRACT_VAR` and `CM_EXTRACT_FUNC` structural refactorings with string/comment safety and 1-step Undo (`src/refactor.mojo`, `tests/e2e/test_v25_refactor_migrate.mojo`)
- [x] P14-05 Bidirectional live cursor sync between `WK_EDITOR` and `WK_CODEGEN` (`ASM` / `PTX` / `AMDGCN` / `LLVM IR`), DWARF data-section stripping, and inline GPU/SIMD resource badges (`[⚡ 32 regs | 4.0 KB smem | 0 spills]`) (`src/codegen.mojo`, `src/app_codegen.mojo`, `tests/e2e/test_v25_codegen_sync_gpu.mojo`)
- [x] P14-06 Release 2.5.0: memory-aware `scripts/check.sh` parallel shard scaling from `/proc/meminfo` (`MemAvailable`), Arch Linux `packaging/PKGBUILD`, regenerated `docs/KEYMAP.md`, `CHANGELOG.md`, `docs/SOURCE.md`, and `help/whats-new.md`

## Phase 15: Inline virtual notebooks, Tensor inspector & Whole-Vim mode (v2.6)

- [x] P15-01 Virtual multi-line cell output blocks in `TextBuffer` / `Window` / `window_draw.mojo` without mutating buffer line numbers, sequential `CM_RUN_ALL_CELLS` / `CM_RUN_CELLS_ABOVE` / `CM_CELL_CLEAR_OUT` cell queue, and bidirectional `.ipynb` `outputs` + `execution_count` persistence (`tests/e2e/test_v30_p15_inline_nb_tensor.mojo`)
- [x] P15-02 Live Tensor, SIMD & DataFrame summary cards (`src/tensor_inspect.mojo`) across Python (`numpy`, `torch`, `pandas`, `polars`) and Mojo (`SIMD`, `List`, `LayoutTensor`, `Tensor`) in cell outputs and `WK_DEBUG`
- [x] P15-03 Real Jupyter `.ipynb` hardening, `File > New/Open notebook (.ipynb)...`, `Shift-Enter` / `Alt-Enter` / `Esc` Jupyter Command Mode, rendered Markdown cells, IPython `!shell` & `%magic` helpers, `Help > Jupyter & notebooks`, and `tmide vim` / `tmvim` Chromeless Whole-Vim Mode (`tests/e2e/test_v30_p15b_ipynb_vim.mojo`)

## Phase 16: GPU occupancy modeling, bank-conflict analyzer & SIMT warp view (v2.7)

- [x] P16-01 Exact SM/CU hardware occupancy calculator (`sm_80` A100, `sm_86`/`sm_89` Ada, `sm_90` H100, `sm_100`/`sm_120` Blackwell/GB10, `gfx90a`/`gfx942` MI250X/MI300X), static 32-bank shared-memory stride & conflict analyzer (`CM_GPU_OCCUPANCY`), occupancy `%` in GPU badges & `WK_CODEGEN`, and 32/64-lane SIMT warp mask strips + cross-lane watch comparison in `WK_DEBUG` (`src/gpu_occupancy.mojo`, `tests/e2e/test_v30_p16_gpu_occupancy_warp.mojo`)

## Phase 17: Pure-Mojo CST & deep structural refactorings (v2.8)

- [x] P17-01 Pure-Mojo Concrete Syntax Tree (`src/mojocst.mojo`) over `Highlighter` tokens powering syntax-exact `Expand / Shrink Selection`, `CM_SWAP_CALL_ARGS`, multi-file `CM_CHANGE_SIGNATURE` (`offer_edit()`), precedence-safe `CM_INLINE_SYMBOL` (variable & helper function), and `CM_IMPL_TRAIT_STUBS` (`Writable`, `Equatable`, `Hashable`, `Copyable`, and custom traits) (`tests/e2e/test_v30_p17_cst_refactor.mojo`)

## Phase 18: Compiler-verified inline AI & local MAX FIM ghost text (v2.9)

- [x] P18-01 Cursor-anchored `CM_INLINE_AI` (`Ctrl-Alt-I`) transform with Closed-Loop Mojo 1.2 Compiler Verification (`[ai] verify_edits`, `CM_AI_VERIFY_TOGGLE`, shadow `mojo build` + up to 2 self-healing retries) and local OpenAI-compatible (`max serve` / `vLLM` / `ollama`) FIM ghost text (`Tab`, `Ctrl-Right`, `Esc`) (`src/inline_ai.mojo`, `tests/e2e/test_v30_p18_inline_ai_fim.mojo`)

## Phase 19: Remote compute targets & multi-GPU cluster topology (v2.10)

- [x] P19-01 Declarative `[target.<name>]` (`ssh`, `docker`, `apptainer`, `slurm`) compute targets (`CM_SELECT_TARGET`), `[target:...]` status pill, transparent `with_env` sync/dispatch & diagnostic path remapping, and multi-GPU `nvidia-smi topo -m` NVLink/PCIe matrices + `squeue` Slurm queues + container cgroup slices in `WK_GPU` (`src/remote_target.mojo`, `src/gpuinfo.mojo`, `tests/e2e/test_v30_p19_remote_targets.mojo`)

## Phase 20: Cross-platform macOS, Omarchy desktop sync & Plugin Hub (v3.0)

- [x] P20-01 Mojo 1.2 `IS_MACOS` `kqueue` watcher FFI fix (`src/watch.mojo`), `arm64-apple-macosx14.0` Mach-O compilation & linking (`scripts/macos-link.sh`), and Apple Silicon Metal unified-memory GPU detection (`src/gpuinfo.mojo`)
- [x] P20-02 Non-invasive live Omarchy Linux theme sync (`src/omarchy_sync.mojo`, `theme = "omarchy"` watching `~/.config/omarchy/current/theme/colors.toml`), `packaging/turbomojo.desktop`, `packaging/turbomojo.svg`, updated `packaging/PKGBUILD` (`3.0.0`, `tmvim`), and Git/folder Plugin & Snippet Hub (`CM_PLUGIN_INSTALL`, `@ref` pinning, update, remove, `snippets.toml`) (`tests/e2e/test_v30_p20_crossplat_plugins.mojo`)

## Phase 21: Interactive Notebook Widgets, DataGrid, GIF89a & LaTeX/Mermaid (v3.1)
- [x] P21-01 Interactive `# @param` & `@interact` terminal sliders, toggles & dropdowns inside `.ipynb` / `# %%` cards (`Alt-Left`/`Alt-Right` + mouse click live cell re-run), virtualized `WK_DATAGRID` sortable table & perceptual Viridis 2D Tensor heatmap window (`CM_CELL_DATAGRID`, 8-bin Unicode sparklines, crimson `NaN`/`Inf` cells, RFC-4180 CSV export) (`src/nb_widgets.mojo`, `tests/test_nb_widgets.mojo`, `tests/e2e/test_v40_p21_widgets_datagrid_gif.mojo`)
- [x] P21-02 Pure-Mojo multi-frame variable-width LZW **GIF89a** animated encoder (`encode_gif89a`) + clickable timeline scrubber & `[g GIF]` export in `WK_IMGVIEW` (`CM_IMG_SAVE_GIF`), inline `$...$` LaTeX Unicode math & fenced ```` ```mermaid ```` box-diagram rendering in Markdown cells and `WK_MDPREVIEW`, and external ZeroMQ `ipykernel` client bridge (`--kernel`, `CM_CONNECT_KERNEL`) (`src/nb_widgets.mojo`, `tests/e2e/test_v40_p21_widgets_datagrid_gif.mojo`)

## Phase 22: CST-Powered Vim Text Objects, 2-Char Flash Jump, Surround & Harpoon (v3.2)
- [x] P22-01 CST structural text objects (`af`/`if` `def`, `ac`/`ic` `struct`/`trait`/`class`, `aa`/`ia` call/signature argument with comma-clean `daa`, `aj`/`ij` `# %%` notebook cell), 2-char smartcase **Flash / Leap** cross-pane jump beacons (`gs`, `<Space>j`, `CM_FLASH_JUMP`), pure-Mojo `ys`/`yss`/`ds`/`cs` surround edits, Harpoon `1..9` quick-marks (`gm`/`gh`/`g1..g4`, `<Space>m`/`<Space>1..4`, `CM_HARPOON_MENU`), `g;`/`g,` change-list jumps, and live register/macro preview popup (`src/vim_cst.mojo`, `tests/test_vim_cst.mojo`, `tests/e2e/test_v40_p22_vim_cst_flash.mojo`)

## Phase 23: GPU Per-Line Stall Profiler, Flamegraph Window & LayoutTensor / MAX Viz (v3.3)
- [x] P23-01 Per-line Nsight Compute (`ncu --csv --page source`), `rocprof`, and zero-hardware static PTX/AMDGCN scoreboard/MIO/barrier stall gutter badges, interactive **Flamegraph & Multi-Stream GPU Timeline Window (`WK_PROFILE`)** (`CM_PROFILE_VIEW`) over Chrome Trace JSON & folded stacks, and **`LayoutTensor` 32-lane global coalescing + 32-bank XOR swizzle + MAX `Graph` epilogue fusion visualizer** (`CM_LAYOUT_VIZ`) (`src/gpu_profiler.mojo`, `tests/test_gpu_profiler.mojo`, `tests/e2e/test_v40_p23_gpu_profiler_layout.mojo`)

## Phase 24: Multimodal Notebook AI, Isolated Worktree Agents & Hybrid AST+BM25 Search (v3.4)
- [x] P24-01 Multimodal notebook AI context (`build_notebook_ai_context` + OpenAI vision data-URI payloads + IPC `get_notebook_context` combining preceding cell signatures, live Tensor/DataFrame schemas, tracebacks, and PNG/animation frames), detached `/tmp` `git worktree` task runner (`CM_AGENT_WORKTREE_TASK`) with shadow `mojo build` verification before `offer_edit()`, and offline hybrid `mojocst` AST + Okapi BM25 semantic codebase search (`CM_SEMANTIC_SEARCH`) (`src/nb_ai_rag.mojo`, `tests/test_nb_ai_rag.mojo`, `tests/e2e/test_v40_p24_multimodal_ai_rag.mojo`)

## Phase 25: Standalone HTML5 Notebook Export, Zero-Server Live Share & Release 4.0 (v4.0)
- [x] P25-01 Self-contained zero-JS/zero-CDN `.ipynb` / `# %%` → `.html` exporter (`CM_EXPORT_HTML`, `--export-html`) with Mojo/Python syntax highlighting, collapsible `<details>` code blocks, Markdown/math, Tensor badges, and embedded base64 PNG + animated GIF89a outputs, plus cross-platform non-blocking `AF_UNIX` collaborative **Live Share** (`CM_LIVE_SHARE`, `--share`, `--connect`) syncing edits, peer cursors, and notebook cell outputs (`src/nb_export_share.mojo`, `tests/test_nb_export_share.mojo`, `tests/e2e/test_v40_p25_export_share_release.mojo`)
- [x] P25-02 Bump `TURBOMOJO_VERSION` to `4.0.0` across `src/version.mojo`, `pixi.toml`, `recipe/recipe.yaml`, and `packaging/PKGBUILD`, add multi-arch GitHub Actions `.github/workflows/release.yml`, sync help book & generated docs (`KEYMAP.md`, `CHANGELOG.md`, `SOURCE.md`), verify `scripts/macos-link.sh` (`arm64` Mach-O), and pass full `./scripts/check.sh` gate (`tests/test_release.mojo`, `tests/e2e/test_v40_p25_export_share_release.mojo`)
