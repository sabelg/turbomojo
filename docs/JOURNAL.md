# Runner journal

Newest entries at the bottom. One entry per finished, blocked or reverted task.

## 2026-11-10 · setup

- Runner set up: `docs/BACKLOG.md` (tasks), `docs/RUNNER.md` (rules), `scripts/check.sh`
  (build + tests + smoke test). Git initialised; runner work happens on branch `roadmap`.
- Baseline: v1.0 builds; `examples/test_fib.mojo` passes; no tests under `tests/` yet.
- Known from research (see `docs/ROADMAP.md`): `mojo test` is gone, use TestSuite files;
  the language server speaks UTF-16 and lacks formatting/folding/workspace symbols.
- Environment note: this machine is linux-aarch64 with a Mojo 1.2 nightly; commands must be
  run through `pixi run` so `mojo` is on PATH.

## 2026-11-10 · P0-01 test harness + util tests · done

- Added `tests/test_util.mojo` (19 tests): UTF-8 decode/encode incl. invalid bytes and exact
  4-byte encoding, display widths (narrow, wide, zero-width), `pad_right` at wide-char
  boundaries, char classes, `fuzzy_score` ordering, `shell_quote`, `strip_ansi`, path
  helpers, base64 against the RFC 4648 vectors.
- `scripts/check.sh` runs every `tests/test_*.mojo` with `mojo run -I src`.
- Verified: all 19 pass; a deliberately failing test file makes `check.sh` exit 1 (then
  removed); full `check.sh` ends with CHECK OK.
- Not covered here (need a process or filesystem): `run_capture`, `list_dir`, `clock_hm`,
  `env_or`. Left for an integration test later.

## 2026-11-10 · P0-02 buffer tests · done

- Added `tests/test_buffer.mojo` (26 tests): load/save round-trips (final newline kept or
  absent, new files get one, CRLF detected and preserved, tabs kept, tab/space detection,
  Unicode), insert/delete incl. multi-line and returned end positions, `get_text`, `at`
  bounds, undo/redo text and cursor, group merging rules, redo cleared by a new edit.
- Randomised check (fixed seed, 400 steps): random inserts/deletes are applied to the
  buffer and to a flat-list reference model and compared after every step; then every step
  is undone and redone, comparing against the recorded snapshots each time.
- Verified: 26/26 pass; `check.sh` CHECK OK. No buffer bugs found.
- Note for later tasks: `ref` is a reserved word in Mojo (as are `case` and `out`).

## 2026-11-10 · P0-03 testable key parser · done

- `Terminal.feed(bytes, stale)` now does the parsing; `poll()` only reads and calls it, so
  the parser runs without a terminal.
- Added `tests/test_term.mojo` (20 tests): printable/control/UTF-8 keys, arrows and
  navigation keys with modifiers, F1–F12 in SS3 and tilde forms with modifiers (the IDE's
  Ctrl-F9, Alt-F9, Alt-F3, Ctrl-F2, Shift-F6), Alt-letters, lone ESC resolved on an idle
  tick, sequences and UTF-8 split across reads, kitty CSI-u, SGR mouse
  press/release/drag/wheel/right button/large coordinates, bracketed paste.
- Bug fixed: when the end-of-paste marker arrived split across two reads with an idle tick
  in between, the first half was swallowed as pasted text and the parser stayed in paste
  mode. The parser now holds back any tail that is a prefix of the marker. Covered by
  `test_paste_terminator_split_across_reads` (written with the fix; not run against the old
  code).
- Verified: 20/20 pass; `check.sh` CHECK OK (smoke test exercises real key input).

## 2026-11-10 · P0-04 highlighter tests · done

- Added `tests/test_highlight.mojo` (19 tests): def/struct/trait/comptime names, keywords,
  builtins, `self`, keywords inside identifiers, comments, `#` inside strings, escapes,
  unterminated strings, triple-quoted strings on one line and across lines (both quote
  kinds, blank lines, reopening on the same line), numbers, digits in identifiers,
  decorators, string prefixes, symbols.
- No highlighter bugs found. One test initially failed because of a wrong expected length
  in the test itself (14 codepoints, not 15); corrected.
- Verified: 19/19 pass; `check.sh` CHECK OK (4 test files, 84 tests in total).

## 2026-11-10 · P0-05 headless screen snapshots · done

- `Screen.row_text()`, `to_text()`, `fg_at()`, `bg_at()` dump the cell grid as text and
  expose colours, so UI code can be tested with no terminal.
- Added `tests/test_screen.mojo` (16 tests). Primitives: text/fill, clipping, out-of-bounds,
  wide characters (two cells, overwriting either half, clip edge), combining marks,
  hot-text, frames, shadows, and that a second `render()` emits almost nothing.
  UI pieces with golden files in `tests/golden/`: menu bar, Options dropdown with a check
  mark, Find dialog (wide text in the field, cursor position, button hit-testing), an
  editor window with a tab + CJK + emoji + combining accent, and an inactive editor over an
  active Message window.
- The goldens were generated with `UPDATE_GOLDEN=1` and then read by eye before committing;
  each golden test also asserts specific facts (row widths equal the window width, frame
  styles, cursor column, colours) so it is not only "whatever the code drew".
- One test expectation was wrong (space after the check mark); fixed in the test.
- Verified: 16/16 pass; `check.sh` CHECK OK (5 files, 100 tests).

## 2026-11-10 · P0-06 window editing tests · done

- Added `tests/test_window.mojo` (53 tests): typing and undo grouping, overwrite mode,
  typing over a selection, newline/auto-indent (after `:`, in tab-indented files, inside
  indentation, splitting a line), backspace (tab stops, tabs, joining lines, selection),
  delete, Tab/Shift-Tab (single line, block, blank lines, selection ending at column 0),
  toggle comment (single, block with mixed indent, mixed commented state), duplicate and
  delete line, cursor movement (wrapping, words, smart Home, document Home/End, remembered
  column), visual columns with tabs/wide/combining characters, selection normalisation,
  find (advance, wrap, case, overlapping, not found), replace-all (count, no rescan, one
  undo), bracket matching within and across lines, whole-buffer replace, goto clamping.
- All 53 passed on the first run; no editor bugs found. Expected values were written from
  the intended behaviour before running, not copied from output.
- Verified: `check.sh` CHECK OK (6 files, 153 tests).

## 2026-11-10 · P0-07 mouse tests · done

- Added `tests/test_mouse.mojo` (30 tests) sending synthetic mouse events through
  `App.handle()` on an 80x25 screen: click-to-place (past end of line, below the text, with
  tabs, wide characters and a scrolled view), drag selection forwards/backwards, stray
  motion after release, wheel scrolling and its limits, right click ignored, scrollbar
  arrows and page area, corner resize, title-bar move, desktop bounds and minimum size,
  zoom box, close box with and without unsaved changes (Cancel / No buttons), raising a
  background window, menu bar open/switch/close, menu item and separator clicks, status-bar
  click, dialog check box / input line / OK / Cancel / close box, clicks outside a dialog,
  list click-then-click to accept, wheel in a list, Message window row selection.
- Result: no mouse bugs found; 29 passed at once. The one failure was a wrong assumption in
  the test: with a check box focused, typing `c` fires the Cancel hot letter (Turbo Vision
  behaviour), so the test now clicks the input line before typing.
- Together with the SGR decoding tests in `test_term.mojo`, the path from terminal bytes to
  editor action is now covered. Still unverified: a real terminal emitting those bytes
  (tmux cannot inject mouse input), so a manual check in a real terminal is still worth
  doing once.
- Performance finding: `mojo run` took 47 s for this file while the compiled binary takes
  0.05 s. `scripts/check.sh` now compiles each test file to `build/tests/` and runs the
  binary; the full gate takes about 15 s. Re-verified that a failing test still fails the
  gate. Measured while investigating: one full `draw()` is ~0.28 ms, a full-screen
  `render()` ~0.06 ms.
- Verified: `check.sh` CHECK OK (7 files, 183 tests).

## 2026-11-10 · correction to the P0-07 entry

- The "performance finding" above was wrong. TestSuite prints times in **milliseconds**:
  the "47 s" for `test_mouse.mojo` was 47 ms. Measured wall-clock: `mojo run` 6.3 s for
  that file (almost all compilation); compile-then-run 2.1 s with a warm compile cache and
  about the same as `mojo run` when cold. The gate's compile-then-run step stays because it
  is correct and a little faster on repeat runs, not because of a large speed-up.
- The other measurements in that entry (one `draw()` ~0.28 ms, full `render()` ~0.06 ms)
  were taken with `perf_counter_ns` directly and stand.

## 2026-11-10 · P0-08 command registry · done

- New `src/commands.mojo`: command ids, a `Registry` of commands (id, stable name such as
  `file.save`, title with hot letter, hint, default keys) plus the menu layout,
  `key_name()` to print key codes ("Ctrl-F9", "Shift-Del"), and `rebind()` for later user
  configuration.
- Generated from it: the menus (`build_menus(reg)`), keyboard shortcuts
  (`App.shortcut` is now `reg.find_key`, replacing a 90-line if-chain), the command palette
  (now shows every binding and lists a command once even when it sits in two menus) and
  the F1 keyboard reference (was hand-written text).
- Behaviour changes: Search menu items are now titled "Next/Previous message" like the
  Compile menu (same commands); Window ▸ "Close all" hot letter changed from `l` to `e`
  because it clashed with "List..." (pressing `l` in the Window menu always picked Close
  all). The clash was caught by the new uniqueness test.
- Added `tests/test_commands.mojo` (11 tests): key names, unique ids/names, no key bound
  twice, every command placed and every placement valid, unique hot letters per menu and
  across menu titles, all 45 v1.0 key bindings checked one by one, unbound keys, primary
  key labels, generated menu structure, rebinding.
- Verified: `check.sh` CHECK OK (8 files, 194 tests); looked at the generated F1 screen and
  the Window menu in the running IDE through tmux.

## 2026-11-10 · P0-09 split app.mojo · done

- Probed first: Mojo allows `__extension App:` blocks in other modules, and modules that
  star-import each other circularly (`from x import *`) see each other's extension
  methods. A plain `import x` does not bring extensions into scope.
- `app.mojo` (2014 lines) is now `appstate.mojo` (struct, fields, init, helpers, 261 lines)
  plus extension modules: `app_files`, `app_dialogs`, `app_menus`, `app_exec`,
  `app_pickers`, `app_jobs`, `app_input`, `app_mouse`, `app_draw`, and `app.mojo` (event
  loop). The method bodies were moved verbatim by line range; no logic changed.
- `window.mojo` (871 lines) was split the same way into `window.mojo` (576),
  `window_search.mojo` and `window_draw.mojo`.
- Largest source file is now `window.mojo` at 576 lines (target: none over ~700).
- Callers that need the methods use `from app import *` / `from window_draw import *`.
- README source layout and testing sections updated.
- Verified: `check.sh` CHECK OK (8 files, 194 tests, smoke test) after each of the two
  splits.

## 2026-11-10 · P0-10 poll()-based event loop · done

- `term.wait_readable(fds, timeout_ms)` sleeps in `poll(2)` on stdin and, while a build or
  format runs, on the compiler's pipe. Terminal reads are now non-blocking (VTIME 0).
- Timers are time-based instead of counted loop ticks: status messages carry a deadline
  (`status_until`), the spinner frame comes from the clock, and
  `App.next_timeout_ms()` picks the shortest of: spinner (100 ms, only while a job runs),
  pending-escape timeout (25 ms, only while an incomplete sequence is buffered), status
  expiry, the next minute boundary (clock), and a 250 ms resize check that P0-11 will
  replace with SIGWINCH.
- A lone Esc is now resolved after 25 ms without further bytes (was up to 100 ms), judged
  by elapsed time since the last input so a compiler-output wake-up cannot cut an escape
  sequence short.
- `wait_byte()` (user screen) blocks in `poll()` instead of spinning.
- Added `tests/test_loop.mojo` (14 tests): `wait_readable` against real pipes (timeout
  duration, immediate return, which fd is ready, wake on writer close, zero timeout), the
  timer selection rules, `say()` deadlines, minute-boundary wake, pending-escape state.
- Measured with the new `scripts/idle-cpu.sh` (10 s idle in tmux): before 50 ms CPU and
  ~10 wakeups/s; after 20 ms CPU and 4 wakeups/s.
- Verified: `check.sh` CHECK OK (9 files, 208 tests, smoke test). Checked live through
  tmux: Esc closes a menu within 150 ms, F9 builds in the background and shows the result
  box, Alt-F5 user screen returns on a key, cursor keys work.
- Not measured: keystroke-to-screen latency (needs instrumentation; planned in P9-02).

## 2026-11-10 · P0-11 signals · done

- First attempt (signalfd with the signals blocked) was wrong and is not in the tree: the
  Mojo runtime starts 20 worker threads before `main()`, each with an empty signal mask, so
  a process-directed signal was usually delivered to a worker and killed the process. A
  standalone script died 26 times in 30. Verified by listing `/proc/<pid>/task/*`.
- Probed and confirmed that a Mojo `def` can be passed as a C callback to `signal(2)`
  (handler ran, process survived, 40/40).
- Final design (`src/signals.mojo`): a minimal handler `on_signal_c` whose only action is
  `eventfd_write` to a fixed descriptor (250); each signal has its own byte of the counter.
  The event loop polls that descriptor. Nothing is blocked, so child processes start with
  default signal handling (tested via /proc: not blocked, not ignored, no handler).
  `close()` restores SIG_DFL through `sigaction`.
- Behaviour: SIGWINCH wakes the loop (the 250 ms size polling is gone when the descriptor
  is active); SIGTERM/SIGHUP/SIGINT write every modified buffer to
  `$XDG_STATE_HOME/turbomojo/recovered/<time>-<n>-<name>` (never over the user's file),
  restore the terminal and exit with a message; SIGTSTP gives the terminal back and stops,
  SIGCONT re-enters and repaints.
- Mistake caught on the way: a search-and-replace also rewrote the SIGTSTP branch of
  `on_signal`, so a terminate signal stopped the process; found because the test processes
  showed up as "Stopped". Fixed, and suspend is now its own method.
- Also fixed: at widths under ~74 columns the menu-bar clock overdrew the Help menu; the
  clock is now hidden when it does not fit (test added).
- `tests/test_signals.mojo` (12 tests) incl. 300 alternating signals per run that must all
  be seen; the suite passed 30/30 consecutive runs. Note for later: the offer-to-recover
  flow on next start belongs to P0-15.
- Measured (`scripts/idle-cpu.sh`, 10 s): 0 ms CPU, 1 wakeup (was 20 ms / 40 after P0-10,
  50 ms / 96 before).
- Verified live in tmux: resize to 70x20 redraws at once; `kill -TERM` with unsaved text
  exits cleanly, recovery file holds the text, original file untouched; `kill -TSTP` puts
  the process in state T and returns the terminal, `kill -CONT` resumes and typing works;
  closing the pane (SIGHUP) ends the process and saves; Ctrl-F2 still kills a running
  compiler. `check.sh` CHECK OK (10 files, 221 tests).
- Unverified: macOS (no signalfd was needed in the end, but `eventfd` is Linux-only; the
  macOS port in P9-03 must use a pipe instead).

## 2026-11-10 · P0-12 crash safety and crash log · done

- Probed: a failed bounds check prints "Assert Error ... out of bounds" and dies with
  SIGTRAP after the Mojo runtime's own handler prints a stack dump; the terminal is left on
  the alternate screen with mouse reporting on (confirmed: `alternate_on=1 mouse=1`).
- New `src/crash.mojo` (`CrashGuard`): a handler for SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGABRT/
  SIGTRAP that restores the terminal (escape sequences + saved termios), prints a notice
  with the log path on the real terminal, writes a session header to the crash log, then
  re-installs the runtime's handler and re-raises so the stack trace is still produced.
  The handler uses only system calls; its data sits behind fixed descriptors: a memfd page
  (251: termios, saved sigactions, header), the log (252) and the original stderr (253).
- While the full-screen UI is up, stderr is redirected to the crash log, so the runtime's
  stack trace lands there instead of on the screen. `Terminal.enter()/leave()` switch it.
- Errors that are caught in the event loop are now appended to the same log with a
  timestamp (`App.log_error`). An error that escapes the loop makes `main` save unsaved
  buffers to the recovery directory, restore the terminal, log, print where things are and
  exit with status 1.
- Fault injection for tests: `TURBOMOJO_FAULT=index` (out-of-bounds trap) or `raise`.
- `scripts/smoke.sh` now runs both faults in tmux and checks: alternate screen and mouse
  mode off, tty back in cooked mode, notice shown, non-zero exit status, crash log has the
  header and a stack trace naming `App::run`. Counter-check done once by hand: with the
  guard unable to install (unwritable state dir) the same crash leaves
  `alternate_on=1 mouse=1`.
- `tests/test_crash.mojo` (9 tests): slots, install/uninstall and descriptor hygiene,
  stderr redirection only while the UI is up, re-install, timestamp format, `append_line`,
  `log_error` silent before `run()`, no guard without a log path.
- `scripts/tui-test.sh` now sets `XDG_STATE_HOME=build/state` so test runs never write to
  the user's home directory (checked: `~/.local/state/turbomojo` does not exist).
- Known limit: the one-line "Assert Error: index N is out of bounds" text is printed by
  the runtime to stdout before the trap and is lost with the alternate screen; the log has
  the stack trace (function names) but not that line.
- Unverified: macOS (`memfd_create` and `dup3` are Linux-specific).
- Verified: `check.sh` CHECK OK (11 files, 230 tests, smoke incl. crash scenarios).

## 2026-11-10 · P0-13 terminal capability probe · done

- New `src/caps.mojo`: `Caps` (colour depth, synchronized output 2026, grapheme clustering
  2027, colour-scheme notification 2031, in-band resize 2048, kitty keyboard, whether the
  terminal answered) and colour mapping (`rgb_to_256`, `rgb_to_16`, `sgr_16`).
- `Terminal.probe()` sends DECRQM queries, the kitty keyboard query and a final DA1
  request, and waits up to 150 ms for the DA1 answer. Replies (`CSI ? ...`) are recognised
  by the input parser and produce no key events; keys typed during the probe are kept and
  delivered first. Previously `CSI ? 1 u` would have been misread as a key.
- Colour depth comes from `$COLORTERM`/`$TERM` with a `TURBOMOJO_COLORS` override.
  `Screen.render` now emits 24-bit, 256-colour (`38;5;N`) or 16-colour SGR codes
  accordingly, and wraps frames in mode-2026 markers only when the terminal supports them.
- Behaviour change: inside tmux without `COLORTERM`, the IDE now uses 256 colours (it used
  to send 24-bit codes regardless). The CGA palette maps to near-identical cube colours.
- `tmide --caps` prints the detected capabilities. The IDE now refuses to start its UI
  when stdin/stdout is not a terminal (exit status 2) instead of writing escape codes into
  a pipe; found when a piped `--caps` run leaked the terminal's reply onto the shell.
- The detected values are stored for later tasks: kitty keyboard (P1-16), grapheme
  clustering (P1-04), colour-scheme notification (P7-01). Nothing enables them yet.
- `tests/test_caps.mojo` (20 tests): reply parsing incl. mixed with typing and split across
  reads, kitty key events still parsed as keys, colour-level detection and override, cube
  levels, known 256-colour indices, index validity over ~80k sampled colours, exact CGA
  mapping to 16 colours, SGR codes, rendering in all three depths, sync markers on/off.
  One expectation of mine was wrong (0xC0CAF5 is nearer bright white than grey); fixed.
- Verified live in tmux: `--caps` reports "256 colours, answered: yes"; the UI renders with
  `38;5;227`/`48;5;19` (auto), `93`/`44` (16-colour) and `38;2;...` (truecolor override).
  `check.sh` CHECK OK (12 files, 250 tests).
- Unverified: replies from terminals other than tmux (kitty, WezTerm, Ghostty, iTerm2 are
  not available here); the parsing is tested against the documented reply formats only.

## 2026-11-10 · P0-14 split; P0-14a config files · done

- P0-14 was split into P0-14a (config) and P0-14b (.editorconfig) in the backlog.
- New `src/toml.mojo`: a TOML subset reader (tables, strings with escapes, literal strings,
  integers, booleans, one-line arrays, quoted keys, comments) that reports problems with
  line numbers and never fails, plus `toml_set`, which changes one value in existing text
  and leaves comments, order and other keys alone.
- New `src/config.mojo`: `Settings` with defaults, layering (user file, then the nearest
  `.turbomojo.toml` at or above the working directory), validation with warnings for wrong
  types, unknown themes and unknown setting names.
- `commands.parse_key()` (inverse of `key_name`) and `[keys]` rebinding through the
  registry; menus show the rebound keys.
- Options menu changes and the compiler dialog write the one changed setting back to the
  user file. First version wrote all options, which copied project-file values into the
  user file; found in the live check, fixed, test added.
- Config is loaded by `main`, not by `App()`, so tests never read or write the user's real
  config. `scripts/tui-test.sh` and the smoke test point `XDG_CONFIG_HOME` at an empty
  location. Checked that `~/.config/turbomojo` and `~/.local/state/turbomojo` do not exist
  after all runs.
- Config warnings are shown in the status line after files are opened (the first version
  was overwritten by the "Loaded" message) and logged.
- `tests/test_config.mojo` (29 tests): parser, error reporting, layering, writer round
  trips and in-place edits, settings validation, key-name parsing incl. a round trip of
  every default binding, applying settings to the app, single-option persistence,
  comment preservation, project-file lookup.
- Verified live in tmux with a user file (theme, custom Save key, a typo) and a project
  file (line numbers off): all applied, toggle persisted alone, comment kept, typo shown
  and logged. `check.sh` CHECK OK (13 files, 279 tests).
- Not done here: `.editorconfig` (P0-14b); a trailing comment on a line that `toml_set`
  rewrites is dropped (documented in the function).
