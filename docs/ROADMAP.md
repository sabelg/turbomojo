# TurboMojo Roadmap: from tribute to professional IDE

*Revision 2, 10 November 2026. Revised after probing the installed Mojo tools and
researching current editor practice. Changes from revision 1 are summarised at the end.*

**Goal:** a terminal IDE that a Mojo team can use all day, with the retro look as a theme
rather than a limit. It should be complete (edit, navigate, build, debug, test, version
control, coding agents), current (LSP, DAP, ACP, modern terminal protocols), dependable (no
lost work, no broken terminal) and fast (well under a frame per keystroke).

**Starting point (v1.0, ~5.4k lines of Mojo):** a single-threaded TUI with a cell renderer,
an editor that understands tabs and wide characters and has grouped undo, Turbo-style menus
and dialogs, a regex-free find, background `mojo build`/`format` with error jumping, themes,
and OSC 52 copy. There are no automated tests and no config file, and no language
intelligence beyond a lexer.

---

## Research findings that shape the plan

### Measured on this machine (Mojo 1.2 nightly, `.pixi/envs/default/bin`)

| Finding | Evidence | Consequence |
|---|---|---|
| `mojo test` no longer exists | `mojo test --help` → "no such command"; `mojo --help` lists run, build, repl, debug, precompile, format, doc, demangle | Tests are ordinary programs that run a `std.testing.TestSuite`. The test explorer is redesigned around that (Phase 5). The IDE's Run ▸ Test was fixed to match |
| TestSuite output is machine-friendly | `mojo run test_fib.mojo` prints `PASS [ 0.001 ] test_name` lines and a summary; `--skip-all` lists tests without running; `--only <names>` runs a subset | A test tree needs no compiler support: list with `--skip-all`, run one with `--only` |
| `mojo-lsp-server` **supports**: completion (trigger `.`), hover, go-to-definition, references, rename, code actions, signature help, inlay hints, semantic tokens (full + delta), incremental sync, push diagnostics, Jupyter notebook sync | `initialize` response | Phase 2 can deliver all of these |
| `mojo-lsp-server` **does not advertise**: formatting, folding ranges, workspace symbols, declaration/type-definition, document highlights, pull diagnostics, UTF-8 positions (it ignored the `positionEncodings` offer, so positions are UTF-16) | Same response | Keep `mojo format` for formatting. Folding, the workspace symbol index and "highlight other uses" must be built in the IDE. The buffer must convert to and from UTF-16 offsets cheaply |
| Document symbols work although not advertised | `textDocument/documentSymbol` returned 3 symbols for `hello.mojo` | Use it for the outline when it answers, with the built-in scanner as fallback |
| Semantic tokens cover only 10 identifier kinds (variable, parameter, function, method, property, class, interface, type, namespace, specialVariable) | Token legend | Keywords, strings, comments and numbers still need a local highlighter |
| Server latency on a 26-line file: diagnostics 0.5 s after an edit; completion 0.36 s; hover, definition and semantic tokens under 10 ms | Timed JSON-RPC exchange | Diagnostics and completion targets are bounded by the server. The IDE must debounce edits and never wait on a response |
| `mojo-lldb-dap` (LLDB 24) supports conditional, hit-count, function, data and instruction breakpoints, log points, disassembly, memory read/write, set-variable, stepping granularity, hover evaluation, completions in the console | `initialize` response | The full Turbo Debugger feature set in Phase 4 is realistic |
| `mojo debug` can also drive `cuda-gdb` | `mojo debug --help` | GPU debugging has a supported path |
| Stable channel carries Mojo **1.1.0**; this project is on a 1.2 nightly | `pixi search mojo -c https://conda.modular.com/max` | Develop against stable 1.x; keep nightly as a canary only |

### From published sources

| Finding | Consequence |
|---|---|
| **Mojo 1.0 shipped on 11 August 2026**; 1.x changes are meant to be mostly additive, with stability guarantees only for APIs marked stable. `match`, enums and async are still to come. ([Modular blog](https://modular.com/blog/modular-26-5-mojo-1-0-is-here), [Linuxiac](https://linuxiac.com/mojo-1-0-programming-language-officially-released/)) | Language churn is a much smaller risk than revision 1 assumed. The highlighter and indenter need to be easy to extend when `match`/enums land |
| The Mojo compiler and toolchain were reported open-sourced (Apache 2.0 with LLVM exceptions) shortly after 1.0; outside contributions are not yet accepted. Secondary coverage only. ([Linuxiac](https://linuxiac.com/?p=217796)) | The LSP server's source can be read to learn undocumented behaviour, but gaps cannot be fixed upstream by us yet |
| **Agent Client Protocol (ACP)** is the emerging standard for running coding agents inside editors: JSON-RPC over stdio, agents as subprocesses, diffs and permission prompts in the protocol. Zed 1.0 (April 2026) made it the headline feature; JetBrains supports it; Claude Code (through an adapter), Codex CLI, Gemini CLI and OpenCode speak it. ([ACP introduction](https://agentclientprotocol.com/overview/introduction), [Zed blog](https://zed.dev/blog/claude-code-via-acp), [overview](https://www.morphllm.com/agent-client-protocol)) | Replace the custom "AI assistance" phase with an ACP client. It reuses the LSP transport, works with any agent, and is less work |
| Community **tree-sitter grammars for Mojo** exist (derived from tree-sitter-python; used by the Zed and Helix integrations). There is no official grammar, and maintenance status against 1.x syntax is unverified. ([zed-mojo](https://github.com/bajrangcoder/zed-mojo), [forum request](https://forum.modular.com/t/tree-sitter-for-mojo-programming-language/3335)) | Worth a spike: tree-sitter would supply folding, outline, indentation and selection-expansion that the LSP lacks. Do not depend on it until the grammar is checked against 1.x |
| **libghostty-vt** is an MIT-licensed C library for terminal emulation with no required dependencies and a C ABI "stable from 1.0". Adoption by JetBrains and Neovim is reported in secondary sources. ([libghostty docs](https://libghostty.tip.ghostty.org/), [announcement](https://mitchellh.com/writing/libghostty-is-coming)) | Use it through FFI for the integrated terminal instead of writing a VT emulator. Confirm the released version before committing |
| The **kitty keyboard protocol** is now implemented by kitty, foot, WezTerm, Ghostty, Alacritty, iTerm2, the VS Code terminal and Warp. ([protocol spec](https://sw.kovidgoyal.net/kitty/keyboard-protocol/), [2026 survey](https://blog.fsck.com/releases/2026/02/26/terminal-keyboard-protocol)) | Turn it on by default when the terminal answers the query; keep the legacy parser as fallback |
| Newer terminal modes exist for grapheme clustering (2027), light/dark change notification (2031) and in-band resize (2048), each detectable with a DECRQM query. Per-terminal support is uneven. ([grapheme clusters in terminals](https://mitchellh.com/writing/grapheme-clusters-in-terminals)) | Probe capabilities at startup and use each mode only when confirmed |
| Zed's buffer is a rope built on a B+ tree whose nodes carry summaries (a "SumTree"), so one structure answers line, offset and other lookups. VS Code uses a piece tree. ([Zed Decoded](https://zed.dev/blog/zed-decoded-rope-sumtree)) | Choose the summarised B-tree rope: the same tree can track bytes, lines, UTF-16 units (needed for LSP) and display width |
| LSP 3.17 added position-encoding negotiation and pull diagnostics; 3.18 adds inline completion. ([LSP 3.18](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification)) | Implement the client against 3.17 with capability detection, so features light up if the Mojo server gains them |

---

## Guiding principles

1. **Never lose work and never break the terminal.** Autosave to a swap file, recover after
   a crash, and restore the terminal on every exit path, including signals and errors.
2. **Never block the UI.** All tools (LSP, DAP, agents, builds, git, search) run as child
   processes on non-blocking pipes, multiplexed with `poll()`.
3. **Use the protocols, and detect capabilities.** LSP, DAP and ACP clients ask what the
   other side supports. The probe above shows the Mojo server implements a subset, so every
   feature needs a local fallback or a clean "not available".
4. **One JSON-RPC layer.** LSP, DAP and ACP all frame JSON over stdio. Build that once.
5. **Measure performance.** Keep budgets in CI: keystroke to frame under 8 ms, startup under
   100 ms, opening a 1M-line file under 1 s.
6. **Make everything a command.** Each action is a named command that can be bound to a key,
   shown in the palette, and called by plugins and agents.
7. **Build on stable Mojo.** Target the stable 1.x channel and run a weekly canary build
   against nightly.

---

## Phase 0: Foundations (v1.1) · about 3 weeks

No visible features. This makes everything after it safe to build.

| Work item | Details | Done when |
|---|---|---|
| Toolchain | Move `pixi.toml` from the nightly pin to stable 1.x; add a nightly canary job | Builds on stable; canary reports breakage weekly |
| Repository and CI | `git init`, CI on linux-64 and linux-aarch64 (macOS later). Build, tests, `mojo format --check` | Every PR is green or blocked |
| Unit tests | `std.testing` TestSuite files run with `mojo run` (the `examples/test_fib.mojo` pattern): buffer insert/delete/undo/redo, UTF-8 and width tables, key/mouse/paste parser fed from byte fixtures, highlighter states, path utilities | ≥80% of non-UI logic covered |
| Screen tests | Headless `Screen` snapshots compared against golden text files. Port the `scripts/tui-test.sh` scenarios into CI with tmux, and add mouse-event fixtures (mouse handling is still untested) | Menus, dialogs, editor rendering and mouse actions have goldens |
| Split `app.mojo` | Break the 2k-line file into `commands/`, `ui/`, `services/` and `core/`. Add a `Command` registry: id, title, default keys, enabled-when | No file over ~600 lines; menus and palette are generated from the registry |
| Event loop | Replace the 100 ms `VTIME` polling with `poll()` over stdin, child pipes, a signal self-pipe and timers | Idle CPU near 0%; child output appears within 1 ms |
| Signals | SIGWINCH, SIGTSTP/SIGCONT (suspend and restore), SIGTERM/SIGHUP (save swap file, restore terminal) | `kill` or closing the window never leaves a broken terminal |
| Terminal capability probe | At startup, query: kitty keyboard (`CSI ? u`), synchronized output (2026), grapheme clustering (2027), colour-scheme notification (2031), in-band resize (2048), truecolor, and the terminal's background colour. Store the answers in one `Caps` struct | Features switch on only when confirmed; 256- and 16-colour fallbacks render correctly |
| Crash safety | A top-level guard always calls `term.leave()`; crash log in `~/.local/state/turbomojo/` | Fault-injection test passes |
| Config | `~/.config/turbomojo/config.toml` plus per-project `.turbomojo.toml`; honour `.editorconfig` | All Options menu settings persist |
| Swap files and recovery | Write unsaved changes every 2 s or 300 keystrokes; offer recovery on next start | `kill -9` loses at most 2 s of typing |
| External change detection | inotify on open files. Reload a clean buffer silently; ask before reloading a modified one | Concurrent edits elsewhere are handled safely |
| **JSON-RPC spike** | A minimal JSON parser and a `Content-Length` framed exchange with `mojo-lsp-server` that prints diagnostics inside the IDE | Phase 2's main risk is retired early |

## Phase 1: A professional-grade editor core (v1.2) · about 6 weeks

| Work item | Details |
|---|---|
| **Text storage** | Replace `List[Line]` of `List[Int]` (8 bytes per character) with a UTF-8 **rope on a B-tree whose nodes carry summaries**: bytes, lines, UTF-16 units and display columns. One tree then answers "line N", "LSP position → byte" and "visual column" in O(log n) |
| Grapheme clusters | Segment text by extended grapheme cluster (UAX #29) so emoji sequences, flags and stacked accents are one cursor stop and one cell group. Use terminal mode 2027 when available. This removes the "one combining mark per cell" limit |
| Syntax tree (spike, then decide) | Bind `libtree-sitter` through FFI and try a community Mojo grammar against 1.x code. If it parses the standard library cleanly, use it for highlighting, folding, outline, auto-indent and expand-selection. If not, keep the built-in lexer and add indentation-based folding |
| Incremental highlighting | Whichever engine wins, re-highlight only what an edit touched. (Today every frame re-scans from the top of the file.) |
| Large files | Lazy loading and a "large file mode" above 50 MB that turns off expensive features |
| Multi-cursor and column selection | Alt-click, Ctrl-D for the next occurrence, box selection; all cursors undo as one step |
| Soft wrap, folding, rulers | Wrap at window or column; fold by syntax or indentation; guides at 80/100; configurable tab width |
| Search | Regex engine (Thompson NFA in Mojo, or PCRE2 via FFI); case, whole-word and in-selection options; highlight all matches; replace with capture groups and preview |
| Find in files | `rg --json` as a background job with a results window; built-in walker when `rg` is missing |
| Editing comforts | Auto-closing pairs, move/join/sort lines, case conversion, trim trailing whitespace on save, persistent undo across sessions |
| Encodings | UTF-8 BOM, Latin-1 fallback, visible marker for mixed line endings |
| Keymaps | **Turbo/WordStar**, **Modern** (VS Code-like) and **Emacs-lite**; user rebinding and chords |
| Full keyboard input | Kitty keyboard protocol when the probe confirms it (now most major terminals), so Ctrl-Shift-X, Ctrl-I versus Tab and key release can be told apart |
| Macros | Record and replay keystrokes |

**Exit criteria:** a 1M-line file opens in under 1 s; typing latency p99 under 8 ms with 16
cursors; a fuzzed edit/undo/redo script round-trips exactly; UTF-16 offset conversion is
verified against a reference implementation.

## Phase 2: Language intelligence via LSP (v1.3) · about 5 weeks

Scope is set by what the server answered in the probe.

| Feature | Source | Notes |
|---|---|---|
| JSON-RPC client | Built in Phase 0 spike, hardened here | Request table, cancellation, timeouts, restart on crash |
| Document sync | Server: incremental | Send UTF-16 positions from the rope's summaries; debounce changes by ~150 ms |
| Diagnostics | Server: push | Curly underlines where the terminal supports them, gutter marks, a Problems window, F8 for next |
| Completion | Server (`.` trigger) | Popup with kinds and docs; there is no resolve step, so show what arrives. Merge with the buffer-word completer for non-member positions |
| Hover, signature help | Server | Floating windows with Markdown rendered to cells |
| Go to definition, find references | Server | Results window and a back/forward jump list |
| Rename, code actions | Server | Preview across files, then apply as one undo step per file |
| Inlay hints, semantic tokens | Server | Layer semantic colours over the local highlighter; inferred types inline, toggleable |
| Outline | Server `documentSymbol` (works, though unadvertised) → syntax tree → built-in scanner | First source that answers wins |
| Formatting | **`mojo format`** (already implemented) | The server offers no formatting |
| Folding, highlight other uses, workspace symbols | **IDE-side**: syntax tree or scanner, plus a background project index | The server offers none of these |
| Offline docs | Index `mojo doc` JSON for the standard library | F1 on a symbol, as in Turbo |
| Notebook support | Server advertises Jupyter cell sync | Parked: record as a later option |

**Exit criteria:** no keystroke ever waits on the server; diagnostics appear within 150 ms
of the server publishing them; a crashed server restarts with a notification; rename across
files undoes correctly.

## Phase 3: Workspace and project (v1.4) · about 4 weeks

| Work item | Details |
|---|---|
| Layout engine | A split-pane tree with tab groups and docked panels. Floating Turbo windows remain as "Classic layout" |
| File explorer | Lazy tree with git status colours; create, rename, delete (to trash), move; respects `.gitignore` |
| Quick open | One palette: files (ranked by frequency and recency), `>` commands, `@` symbols, `:` line |
| Project model | Detect `pixi.toml`; expose pixi tasks as run targets; include paths (`-I`, also passed to the language server); package builds with `mojo precompile` |
| Run configurations | Named configurations (file, arguments, environment, working directory, pre-launch build) |
| Sessions | Restore files, cursors, layout, breakpoints and history per project |
| Workspace trust | Ask before running tasks, language servers or agents in a new folder |

## Phase 4: Debugger via DAP (v1.5) · about 5 weeks

Uses `mojo-lldb-dap`; every item below maps to a capability the adapter reported.

| Work item | Details |
|---|---|
| DAP client | Reuses the JSON-RPC layer (DAP's framing is the same, its message shape differs) |
| Breakpoints | Line, conditional, hit-count, log points, function and data (watchpoint) breakpoints; persisted per project |
| Execution control | F7 into, F8 over, Shift-F8 out, F4 run to cursor, Ctrl-F2 reset, pause; instruction-level stepping in the disassembly view |
| Views | Call Stack, Variables tree with set-value, Watches (Ctrl-F7), Registers, Disassembly, Memory (read and write), Modules |
| Debug console | Expression evaluation with completions; hover evaluation in the editor |
| GPU | A run configuration that launches `mojo debug` in its `cuda-gdb` mode for GPU kernels |

**Exit criteria:** debug the bundled examples end to end; stopping the debugger always
cleans up the debuggee.

## Phase 5: Integrated terminal, tests and Git (v1.6) · about 5 weeks

| Work item | Details |
|---|---|
| **Integrated terminal** | A pty (`forkpty` via FFI) driven by **libghostty-vt** through FFI for parsing and screen state; the IDE only copies its cells into a pane. Fallback: a minimal built-in parser if the library is absent. This becomes the "user screen", so Run no longer takes over the whole terminal |
| REPL panel | `mojo repl` in a terminal pane with "send selection" |
| **Test explorer** | Find files that use `TestSuite`. List tests with `mojo run <file> --skip-all`; run one or several with `--only <names>`; parse `PASS`/`FAIL`/`SKIP` lines and the `file:line:col` in failures to jump to the assertion. Optional re-run on save |
| Git | Changed-line markers in the gutter; stage, unstage and revert hunks; diff view; commit dialog; branches; blame; conflict resolution. All through `git` subprocesses with porcelain v2 output |
| Problems/Output panels | Filterable diagnostics from LSP, builds and tests in one place |

## Phase 6: Coding agents via ACP (v1.7) · about 3 weeks

Replaces revision 1's custom AI phase. It comes after Phase 5 because agents need the diff
view and the terminal.

| Work item | Details |
|---|---|
| ACP client | Third user of the JSON-RPC layer. Launch any ACP agent as a subprocess (Claude Code through its adapter, Codex CLI, Gemini CLI, OpenCode), chosen in config |
| Agent panel | Conversation view rendered from Markdown; file and selection mentions; streaming updates; several sessions side by side |
| Editor services for the agent | File reads and writes go through open buffers (so unsaved text is seen and edits are undoable); proposed changes appear in the diff view to accept or reject; commands run in the integrated terminal |
| Permissions | Every write or command prompts unless the user has allowed it for the session; honours workspace trust |
| Privacy | Off until an agent is configured; the IDE itself sends nothing anywhere |
| Later option | Inline "ghost text" completions through LSP 3.18 `inlineCompletion` if a server offers it |

## Phase 7: UX polish and accessibility (v1.8) · about 4 weeks

- Themes as TOML files; light and high-contrast themes; follow the terminal's light/dark
  setting through mode 2031 where supported.
- Notifications and a progress centre for the language server, builds, git and agents.
- Help: interactive tutorial, cheat sheet, searchable docs, "What's new".
- Accessibility: screen-reader mode (linear output, no box drawing), reduced motion, larger
  mouse targets.
- Breadcrumbs, sticky scope header, optional Braille-character minimap.
- Externalised UI strings.

## Phase 8: Extensibility (v1.9) · about 5 weeks

- Out-of-process plugins over the same JSON-RPC layer: commands, key bindings, panels,
  status items and event hooks. A crashing plugin cannot take the IDE down.
- Python scripting for quick automation (Mojo can call Python).
- Other language servers by configuration only (Python, C/C++, TOML, Markdown), which the
  capability-detecting client already allows.
- A curated plugin index.

## Phase 9: Release engineering, 2.0 · about 3 weeks

- Packaging: conda package so `pixi global install turbomojo` works; static binaries;
  macOS support (termios constants and FFI differ per OS).
- Reliability: 24-hour soak test; fuzzing of the input parser, JSON parser and rope.
- Performance dashboard in CI.
- Documentation site; semantic versioning; changelog; security policy.

---

## Timeline summary

| Version | Theme | Effort | Cumulative |
|---|---|---|---|
| 1.1 | Foundations | 3 wk | 3 wk |
| 1.2 | Editor core | 6 wk | 9 wk |
| 1.3 | LSP | 5 wk | 14 wk |
| 1.4 | Workspace | 4 wk | 18 wk |
| 1.5 | Debugger | 5 wk | 23 wk |
| 1.6 | Terminal, tests, Git | 5 wk | 28 wk |
| 1.7 | Coding agents (ACP) | 3 wk | 31 wk |
| 1.8 | Polish and accessibility | 4 wk | 35 wk |
| 1.9 | Plugins | 5 wk | 40 wk |
| 2.0 | Release | 3 wk | **~43 wk** for one experienced developer |

These are planning estimates, not measurements. **Phases 0–5 (28 weeks) are the minimum
professional cut.**

## Risks and mitigations

| Risk | Level | Mitigation |
|---|---|---|
| `mojo-lsp-server` gaps (no folding, formatting, workspace symbols; UTF-16 only) | Known, confirmed | IDE-side implementations listed in Phase 2; capability detection so server improvements are picked up automatically |
| Server latency (0.5 s diagnostics on a tiny file; unknown on large projects) | Medium | Never block on the server; debounce; measure on a large project during the Phase 0 spike |
| Tree-sitter Mojo grammar is community-maintained and may lag 1.x syntax | Medium | Spike before depending on it; the built-in lexer stays as fallback |
| libghostty-vt release status not confirmed from primary sources | Medium | Check the released version and licence before Phase 5; fallback is a small built-in parser |
| ACP is young and still changing | Medium | Isolate it behind one module; pin the protocol version; the IDE is fully usable without it |
| Mojo language changes (`match`, enums, async still to come) | Low since 1.0 | Stable channel plus nightly canary; table-driven keyword lists |
| Terminals differ | Medium | Startup capability probe; test matrix (kitty, WezTerm, Ghostty, iTerm2, GNOME, Windows Terminal, tmux) |
| Single-threaded design under load | Low | `poll()` loop plus child processes; move heavy local work to worker processes only if profiling demands it |
| Scope creep | Medium | Exit criteria per phase; nothing from a later phase merges early |

## Immediate next steps (first two weeks)

1. Initialise git; switch to the stable Mojo channel; add CI.
2. Write TestSuite files for `buffer.mojo` (undo/redo fuzz), `term.mojo` (byte fixtures,
   including mouse) and `util.char_width`.
3. Introduce the `Command` registry and split `app.mojo`.
4. Implement the `poll()` loop, signal self-pipe, crash-safe terminal restore and the
   capability probe.
5. JSON-RPC spike against `mojo-lsp-server`, including a latency run on a large Mojo
   project.
6. Tree-sitter spike: parse the Mojo standard library with a community grammar and count
   error nodes.

---

## What changed from revision 1

| Area | Revision 1 | Revision 2 | Why |
|---|---|---|---|
| Tests | Test explorer on `mojo test` | TestSuite files via `mojo run`, with `--skip-all` and `--only` | `mojo test` was removed from Mojo |
| LSP scope | Assumed a full-featured server | Exact supported set; folding, formatting, symbols index and highlights done IDE-side | Capability probe |
| Position handling | UTF-16 mapping mentioned as a detail | UTF-16 counts built into the rope's summaries | Server only speaks UTF-16 |
| Text storage | "Piece table or rope" | Summarised B-tree rope | One structure for lines, offsets, UTF-16 and width |
| Unicode | Width tables only | Grapheme clusters and terminal mode 2027 | Removes the stacked-accent limit |
| Syntax engine | Own lexer only | Tree-sitter spike, lexer as fallback | Community grammars exist; LSP lacks folding and outline |
| Integrated terminal | Write a VT parser | libghostty-vt through FFI | Maintained library with a stable C ABI |
| AI | Custom provider and chat (4 wk) | ACP client for any agent (3 wk), moved before polish | ACP is now the editor standard and reuses the JSON-RPC layer |
| Mojo version policy | Pin a nightly | Stable 1.x plus nightly canary | Mojo 1.0 shipped; 1.1.0 is on the stable channel |
| Debugger | Generic DAP list | Feature list matched to reported capabilities; cuda-gdb path | DAP probe and `mojo debug --help` |
| Phase 0 | No protocol work | JSON-RPC spike and terminal capability probe added | Retire the biggest risks first |
| Total | ~46 weeks | ~43 weeks | Library reuse and one shared protocol layer |

Items marked "secondary coverage" or "unverified" above (the compiler's open-source status,
the libghostty-vt release version, tree-sitter grammar upkeep, per-terminal mode support)
come from single searches and should be confirmed from primary sources before work depends
on them.

---

## Revision 4 (`v3.1` → `v4.0.0` Completed Milestones, Phases 21–25)

All five post-`v3.0` tracks in `docs/BACKLOG.md` (`P21-01` through `P25-02`) are implemented and verified in `v4.0.0`:
1. **Phase 21 (`v3.1`)**: Interactive `# @param` / `@interact` notebook widgets, virtualized `WK_DATAGRID` table & 2D Tensor heatmap window, pure-Mojo LZW GIF89a animation export + `WK_IMGVIEW` scrubber, inline LaTeX `$math$` & fenced ```` ```mermaid ```` diagrams, and external `ipykernel` bridge.
2. **Phase 22 (`v3.2`)**: CST structural Vim text objects (`af`/`if`, `ac`/`ic`, `aa`/`ia`, `aj`/`ij`), 2-char Flash / Leap cross-pane jump beacons, `ys`/`ds`/`cs` surround, Harpoon `1..9` quick-marks, `g;`/`g,` change-list, and live register/macro preview popup.
3. **Phase 23 (`v3.3`)**: Per-line `ncu`/`rocprof` & static PTX/AMDGCN stall gutter badges, interactive `WK_PROFILE` Flamegraph & Multi-Stream GPU Timeline viewer, and `LayoutTensor` 32-lane coalescing / 32-bank XOR swizzle + MAX `Graph` fusion visualizer.
4. **Phase 24 (`v3.4`)**: Multimodal notebook AI context (live schemas + tracebacks + PNG plot vision + IPC `get_notebook_context`), isolated `/tmp` `git worktree` shadow-verified task runner, and hybrid `mojocst` AST + Okapi BM25 semantic codebase search.
5. **Phase 25 (`v4.0.0`)**: Standalone zero-JS/zero-CDN `.ipynb` → `.html` exporter (with embedded PNG & GIF89a animations), zero-server `AF_UNIX` collaborative Live Share (`--share` / `--connect`), and multi-arch GitHub Actions release pipeline (`.github/workflows/release.yml`).
