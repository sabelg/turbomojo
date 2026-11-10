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
