# TurboMojo user guide

TurboMojo is an editor and IDE for Mojo in the terminal, in the style of Turbo C++ 3.0.
Everything is reached from the menu bar (**F10**, or **Alt** and a menu's letter) and
from the command palette (**Ctrl-P**), which finds every command by name.

## Windows

- Edit windows overlap like on a desk; **Alt-1** to **Alt-9** go to a window by its
  number, **F6** to the next one, **F5** zooms one. Window > Tiled layout puts them side
  by side in panes with tabs instead.
- The **bottom panel** has three pages: Message (compiler and program output), Search
  (results and lists of places) and Problems (from the language server, the last build
  and failed tests). Left / Right switch pages; Enter goes to the place a line names.
- At the left the **file explorer** (Ctrl-E), at the right the **outline**, the **docs
  pane**, the **test explorer** or the **agent panel**.

## Editing

The keys follow your keymap (Options): Modern (Ctrl-C/X/V/Z), Turbo (WordStar Ctrl-K
blocks), Emacs or Vim. After a prefix key such as Ctrl-K, wait a moment and a box lists
the keys that may follow. Multiple cursors, column selection, folding by indentation, soft
wrap, macros (Ctrl-F5 records), find and replace with regular expressions, and Find in
Files are in the Edit, Text and Search menus.

## Mojo

- **F7** starts the language server: problems underlined as you type, completion,
  hover (Alt-I), go to definition (F12), references, rename, code actions.
- **F9** builds, **Ctrl-F9** runs (in the terminal window if `run_in_terminal`).
- **F1** on a problem (a row of the Problems page, or its line in the editor) explains
  the message beside the code with syntax-coloured Before / After programs: **C** copies
  the fixed code, **T** opens it in a scratch buffer, **A** asks the coding agent, and
  **?** searches the docs. Help > Error messages has all 27 pages.
- **Shift-F5** debugs: breakpoints (Ctrl-F8), stepping (F7, F8, Shift-F8), the Debug
  window (Ctrl-F3) with variables and watches, the CPU window (Alt-F2).
- Run > Test explorer runs `std.testing` suites and shows what failed where.
- **Ctrl-F1** shows the documentation of the name at the cursor (understanding receiver
  chains like `items.append` and `Python.import_module`); **Shift-F1** (Help > Mojo
  documentation) reads the manual, the language reference, the standard library and
  Modular's courses.
- Help > Docs pane keeps rich syntax-coloured documentation beside the code, following
  the cursor; **Enter** opens the full page, **C** copies a code example, **T** tries it
  in a scratch buffer.

## Notebooks & Jupyter (`.ipynb`)

- Open any Jupyter **`.ipynb`** file directly (`tmide notebook.ipynb`, **F3**, or **Ctrl-E**),
  create a fresh notebook from **≡ > New Jupyter notebook (.ipynb)...**, or write `# %%`
  and `# %% [markdown]` cell headers in any `.mojo` or `.py` file.
- **Ctrl-Enter** runs the cell at the cursor in a persistent `mojo repl` or `python3`
  kernel (**Ctrl-Shift-Enter** runs and advances); virtual output blocks, Tensor / DataFrame
  summary cards, and `matplotlib` plots (`Text > Open cell plot preview`) render inline.
- Saving (**F2**) writes valid nbformat v4 `.ipynb` JSON with outputs and plots preserved;
  Help > Jupyter & notebooks has the full guide.

## Vim mode (`tmide vim`)

- Run `tmide vim [file...]` (or `tmide --vim`, or `:zen` inside Vim keys) for a full-screen,
  chromeless Vim experience: buffers start on row 0 with `~` EOF markers, a classic two-row
  Vim statusline + `:`/`/` command bar at the bottom, `<Space>` leader keys (`<Space>f` files,
  `<Space>g` grep, `<Space>e` explorer, `<Space>b` build, `<Space>x` run, `<Space>c` cell),
  `:Ex`, `ZZ`/`ZQ`, and full Mojo 1.2 LSP (`gd`, `gr`, `K`, `[d`/`]d`). Press **F10** anytime
  to open IDE menus.

## Git

In a repository (in a trusted folder) the gutter marks lines changed since the index,
the explorer colours files by their status, and the File menu has Diff (stage, revert
or unstage one change), Commit, Branch and Blame.

## Coding agents

File > Agent panel (Ctrl-F11) talks to an agent that speaks the Agent Client Protocol,
named by `agent` under `[tools]` (`agent_mode` chooses `ask`, `accept-edits`, or `auto`).
Inside the agent panel: **Alt-M** cycles permission mode, **Alt-O** switches model,
**Alt-T** cycles thinking level, **Tab** completes `@file` mentions, and **Alt-Up** /
**Alt-Down** step prompt history. Help > Ask agent about this error (or this code) and
File > Send diagnostics to agent ground the prompt with your code, diagnostics, and
Mojo 1.2 documentation excerpts, and verify imports in the agent's answer.

## Settings

`~/.config/turbomojo/config.toml` (and a project's `.turbomojo.toml`): Options writes
there for you. Themes: Options > Colour theme; your own themes are TOML files in
`~/.config/turbomojo/themes/`.

## More help

- Help > Keyboard reference (F1): every key, as your keymap has it.
- Help > Cheat sheet: the keys used most.
- Help > Tutorial: a file to practise in.
- Help > Exercises: 13 small Mojo 1.2 programs that are wrong until you fix them; Help >
  Exercise done? checks yours - and your copy of a Mojo GPU Puzzle (**O** on its program
  in the documentation reader makes one, offering to run `pixi install` the first time).
- Help > Coming from Python: what is different, and the keys next to VS Code's.
- Help > What's new.
- In this viewer **/** searches every page (**Alt-F1** from anywhere, including dotted
  module paths like `std.collections.list`), **Ctrl-F** searches on the current page
  (**F3** / **Shift-F3** next / previous), **G** jumps to a heading on the page, **C**
  copies the visible code block, and **T** opens it in a scratch buffer.
