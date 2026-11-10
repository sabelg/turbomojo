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
