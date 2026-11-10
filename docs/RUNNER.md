# Roadmap runner

Instructions for the autonomous loop that implements `docs/ROADMAP.md`.
The user chose: loop in one session, one git commit per finished task, no pauses between
phases. Stop only when the backlog is finished or everything left is blocked.

## Each round

1. **Orient.** Read `docs/BACKLOG.md` and the last ~40 lines of `docs/JOURNAL.md`. Run
   `git status --short` and `git log --oneline -5`. If the tree is dirty from an interrupted
   round, finish or revert that work first (`scripts/check.sh` decides).
2. **Pick** the first `[ ]` task in file order. A `[~]` task comes before any `[ ]` task.
   If a task is too big for one round, split it into `a`/`b`/`c` sub-tasks in the backlog
   and do the first.
3. **Read before writing.** Open the roadmap section for the task and the source files it
   touches. Reuse what exists.
4. **Implement** in Mojo under `src/`. Add or extend tests under `tests/` in the same round.
5. **Verify** with `scripts/check.sh` (build, all tests, TUI smoke test). It must end with
   `CHECK OK`. For UI work also look at the screen with `scripts/tui-test.sh`.
6. **Record.** Mark the task `[x]` in the backlog. Append a journal entry: task id, what
   changed, how it was verified, anything left out. Update `README.md` when user-visible
   behaviour changes.
7. **Commit** everything from the round as one commit on branch `roadmap`:
   `P0-03: <summary>`, ending with the attribution trailer. Never push.
8. **Continue** with the next task while the round has room; otherwise schedule the next
   wake-up with the same loop prompt.

## Rules

- **The build never stays broken.** If a task cannot be made to pass `scripts/check.sh`,
  revert it (`git checkout -- . && git clean -fd src tests`), mark the task `[!]` with the
  reason, journal it, commit that note, and move on.
- **Blocked is fine; pretending is not.** Mark `[x]` only for work that was run and
  verified here. If part of a task cannot be verified on this machine (macOS, a missing
  library, a terminal feature tmux hides), mark it `[~]` or note "unverified" in the
  journal. Do not write tests that only assert what the code happens to do in order to get
  green.
- **Dependencies** come only from the pixi/conda channels already configured (Modular,
  conda-forge). If a library is not there, use the fallback named in the backlog or mark
  the task blocked. Do not download and run binaries or scripts from anywhere else.
- **Stay inside the project folder.** Use `$TMPDIR` for scratch files. Do not touch other
  projects, global config or the user's own tmux server (`scripts/tui-test.sh` uses a
  private socket).
- **No outward actions:** no pushes, no publishing, no network calls beyond pixi package
  installs.
- **Keep it working like Turbo.** The classic look and the existing key bindings stay
  available as each feature lands.
- **Three failed attempts** at the same task in different ways → mark `[!]`, journal what
  was tried, move on. Revisit blocked tasks once, after the last phase.
- When every task is `[x]` or `[!]`, write a final summary at the end of the journal and
  stop the loop.

## Loop prompt

```
Work on the TurboMojo roadmap as described in docs/RUNNER.md: read docs/BACKLOG.md and docs/JOURNAL.md, do the next unfinished task, verify with scripts/check.sh, record and commit, then continue with further tasks.
```
