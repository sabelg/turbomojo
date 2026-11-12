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
- At the left the **file explorer** (Ctrl-E), at the right the **outline**, the **test
  explorer** or the **agent panel**.

## Editing

The keys follow your keymap (Options): Modern (Ctrl-C/X/V/Z), Turbo (WordStar Ctrl-K
blocks) or Emacs. After a prefix key such as Ctrl-K, wait a moment and a box lists
the keys that may follow. Multiple cursors, column selection, folding by indentation, soft
wrap, macros (Ctrl-F5 records), find and replace with regular expressions, and Find in
Files are in the Edit, Text and Search menus.

## Mojo

- **F7** starts the language server: problems underlined as you type, completion,
  hover (Alt-I), go to definition (F12), references, rename, code actions.
- **F9** builds, **Ctrl-F9** runs (in the terminal window if `run_in_terminal`).
- **F1** on a problem (a row of the Problems page, or its line in the editor) explains
  the message beside the code: what it means, how to fix it, a program before and
  after. Help > Error messages has them all.
- **Shift-F5** debugs: breakpoints (Ctrl-F8), stepping (F7, F8, Shift-F8), the Debug
  window (Ctrl-F3) with variables and watches, the CPU window (Alt-F2).
- Run > Test explorer runs `std.testing` suites and shows what failed where.
- **Ctrl-F1** shows the documentation of the name at the cursor; Help > Mojo
  documentation reads the manual, the reference and the standard library.
- Help > Docs pane keeps that documentation beside the code, following the cursor;
  Ctrl-F1 and Alt-I answer there while it is open, Enter opens the full page.

## Git

In a repository (in a trusted folder) the gutter marks lines changed since the index,
the explorer colours files by their status, and the File menu has Diff (stage, revert
or unstage one change), Commit, Branch and Blame.

## Coding agents

File > Agent panel (Ctrl-F11) talks to an agent that speaks the Agent Client Protocol,
named by `agent` under `[tools]`. It asks before every change and command unless you
allow it for the session; `@file:12-20` in a prompt sends those lines along.

## Settings

`~/.config/turbomojo/config.toml` (and a project's `.turbomojo.toml`): Options writes
there for you. Themes: Options > Colour theme; your own themes are TOML files in
`~/.config/turbomojo/themes/`.

## More help

- Help > Keyboard reference (F1): every key, as your keymap has it.
- Help > Cheat sheet: the keys used most.
- Help > Tutorial: a file to practise in.
- Help > What's new.
- In this viewer **/** searches every page, the Mojo documentation too. Find in
  documentation (Alt-F1) also takes a name, a dotted path (`List.append`) or a pasted
  error line; `?` in the palette (Ctrl-P) hands the text to it.
