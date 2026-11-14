"""The vim interface (Phase 12): `ui.keymap = "vim"`. The everyday part of vim, as editors
with a "vim mode" have it - modes, motions, operators, search, `:` commands - not
Vimscript, vim plugins or a .vimrc.

This module holds the state and what can be worked out without the IDE: the modes and
their names, and the keys as the keymap reference lists them. The keys themselves are
handled in app_vim.mojo, in front of TurboMojo's own bindings: in Normal and Visual mode
vim takes the plain keys (letters, digits, punctuation, Enter, Backspace, the arrows),
and everything with Ctrl or Alt, the F-keys and the menus stay TurboMojo's; in Insert
mode vim takes only Esc."""
from std.collections import List

comptime VM_NORMAL = 0
comptime VM_INSERT = 1
comptime VM_VISUAL = 2      # characters, the one under the cursor included
comptime VM_VLINE = 3       # whole lines

comptime KEYMAP_VIM = 3     # ui.keymap's number for "vim" (commands.keymap_name)


def vim_mode_name(mode: Int) -> String:
    """As vim's status line has it."""
    if mode == VM_INSERT:
        return "INSERT"
    if mode == VM_VISUAL:
        return "VISUAL"
    if mode == VM_VLINE:
        return "V-LINE"
    return "NORMAL"


struct VimState(Copyable, Movable):
    var mode: Int
    var count: Int          # the count typed so far (0: none)
    var ar: Int             # Visual: where the selection started
    var ac: Int
    var reg: List[Int]      # the unnamed register: what was deleted or yanked last
    var reg_lines: Bool     # ...whole lines (they are put on lines of their own)

    def __init__(out self):
        self.mode = VM_NORMAL
        self.count = 0
        self.ar = 0
        self.ac = 0
        self.reg = List[Int]()
        self.reg_lines = False

    def take_count(mut self) -> Int:
        """The count for the command being run (1 when none was typed); it is used up."""
        var n = self.count if self.count > 0 else 1
        self.count = 0
        return n


def vim_keys_markdown() -> String:
    """The vim keymap's section of docs/KEYMAP.md."""
    var out = String("\n## Vim (Options > Keys: Vim)\n\nIn Normal and Visual mode vim has the plain keys; Ctrl and Alt keys, the F-keys and\nthe menus are TurboMojo's (the Modern keys) in every mode. In Insert mode only Esc is\nvim's. A number before a command repeats it (3j).\n\n| Key | Mode | What it does |\n|---|---|---|\n")
    var rows = [
        ["Esc", "Insert, Visual", "Back to Normal mode"],
        ["i a", "Normal", "Insert before / after the cursor"],
        ["I A", "Normal", "Insert at the line's first character / its end"],
        ["o O", "Normal", "Open a line below / above and insert"],
        ["h j k l", "Normal, Visual", "Left, down, up, right (also the arrows, Backspace, Space, Enter)"],
        ["x", "Normal", "Delete the character under the cursor"],
        ["v V", "Normal, Visual", "Visual mode: characters / whole lines (again: back to Normal)"],
        ["d x y", "Visual", "Delete / delete / copy the selection"],
    ]
    for r in rows:
        out += "| " + String(r[0]) + " | " + String(r[1]) + " | " + String(r[2]) + " |\n"
    return out^
