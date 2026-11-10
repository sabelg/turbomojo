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
