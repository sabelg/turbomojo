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
    var op: Int             # an operator waiting for its motion (d c y > <; 0: none)
    var op_n: Int           # ...and the count typed before it (0: none)
    var pend: Int           # a key waiting for one more: g, f t F T, r, or i / a after an operator
    var f_kind: Int         # the last f t F T, for ; and , (0: none yet)
    var f_ch: Int
    var cur: List[Int]      # the keys of the command being typed (for .)
    var dot: List[Int]      # the keys of the last change, which . types again
    var changed: Bool       # the command being typed changes the text
    var replaying: Bool     # . is typing
    var ins_group: Int      # the undo group an Insert started by a command joins (0: none)
    var cl_on: Bool         # the command line (/ ? :) is being typed on the status row
    var cl_kind: Int        # ...its first character: / ? or :
    var cl_text: List[Int]
    var cl_v1: Int          # the Visual selection's rows when : was typed there (-1: none)
    var cl_v2: Int
    var s_pat: List[Int]    # the last search, in vim's syntax (n N repeat it; :s uses it)
    var s_fwd: Bool         # ...forwards (/ *) or backwards (? #)

    def __init__(out self):
        self.mode = VM_NORMAL
        self.count = 0
        self.ar = 0
        self.ac = 0
        self.reg = List[Int]()
        self.reg_lines = False
        self.op = 0
        self.op_n = 0
        self.pend = 0
        self.f_kind = 0
        self.f_ch = 0
        self.cur = List[Int]()
        self.dot = List[Int]()
        self.changed = False
        self.replaying = False
        self.ins_group = 0
        self.cl_on = False
        self.cl_kind = 0
        self.cl_text = List[Int]()
        self.cl_v1 = -1
        self.cl_v2 = -1
        self.s_pat = List[Int]()
        self.s_fwd = True

    def counted(self) -> Bool:
        """Was a count typed (before the operator or after it)?"""
        return self.count > 0 or self.op_n > 0

    def total_count(mut self) -> Int:
        """The count for an operator's motion - the two counts multiplied (2d3w is six
        words) - used up."""
        var n = max(self.op_n, 1) * max(self.count, 1)
        self.count = 0
        self.op_n = 0
        return n

    def take_count(mut self) -> Int:
        """The count for the command being run (1 when none was typed); it is used up."""
        var n = self.count if self.count > 0 else 1
        self.count = 0
        return n


def vim_keys_markdown() -> String:
    """The vim keymap's section of docs/KEYMAP.md."""
    var out = String("\n## Vim (Options > Keys: Vim)\n\nIn Normal and Visual mode vim has the plain keys; Ctrl and Alt keys, the F-keys and\nthe menus are TurboMojo's (the Modern keys) in every mode. In Insert mode only Esc is\nvim's. A number before a command repeats it (3j, 2dd, 3.).\n\n| Key | Mode | What it does |\n|---|---|---|\n")
    var rows = [
        ["Esc", "Insert, Visual", "Back to Normal mode (also cancels a half-typed command)"],
        ["i a", "Normal", "Insert before / after the cursor"],
        ["I A", "Normal", "Insert at the line's first character / its end"],
        ["o O", "Normal", "Open a line below / above and insert"],
        ["h j k l", "Normal, Visual", "Left, down, up, right (also the arrows, Backspace, Space, Enter)"],
        ["w b e", "Normal, Visual", "Next word, back a word, end of the word"],
        ["W B E", "Normal, Visual", "The same for words between blanks"],
        ["0 ^ $", "Normal, Visual", "The line's start, its first character, its end"],
        ["+ - Enter", "Normal, Visual", "The first character of the next / the line before"],
        ["gg G", "Normal, Visual", "The first / the last line (with a count: that line)"],
        ["f t F T", "Normal, Visual", "To / just before the next character typed (F T: to the left)"],
        ["; ,", "Normal, Visual", "The last f t F T again / the other way"],
        ["%", "Normal, Visual", "The matching bracket"],
        ["{ }", "Normal, Visual", "The empty line before / after the paragraph"],
        ["/ ?", "Normal, Visual", "Search forwards / backwards: type the pattern on the status row, then Enter"],
        ["n N", "Normal, Visual", "The last search again / the other way"],
        ["* #", "Normal, Visual", "Search for the word under the cursor, forwards / backwards"],
        [":", "Normal, Visual", "A command line (in Visual mode for the selection's lines): see below"],
        ["d c y", "Normal", "Delete / change / copy (yank) what the motion or text object covers: dw, c$, y3j, dd, cc, yy"],
        ["> <", "Normal", "Indent / unindent the lines the motion covers: >>, <ip"],
        ["iw aw iW aW", "after d c y", "The word (aw: with the blanks after it)"],
        ["i\" a\" i' a'", "after d c y", "Inside the quotes (a: with them)"],
        ["i( a( i{ a{ i[ a[ i< a<", "after d c y", "Inside the brackets (a: with them); ib iB too"],
        ["ip ap", "after d c y", "The paragraph (ap: with the empty lines after it)"],
        ["x X", "Normal", "Delete the character under / before the cursor"],
        ["D C Y", "Normal", "d$, c$, yy"],
        ["s S", "Normal", "Change the character / the line"],
        ["r", "Normal", "Replace the character under the cursor with the next one typed"],
        ["J", "Normal, Visual", "Join the line and the next (the lines selected)"],
        ["p P", "Normal", "Put what was deleted or copied after / before the cursor (whole lines: below / above)"],
        [".", "Normal", "Repeat the last change"],
        ["u Ctrl-R", "Normal", "Undo / redo"],
        ["v V", "Normal, Visual", "Visual mode: characters / whole lines (again: back to Normal)"],
        ["o", "Visual", "To the other end of the selection"],
        ["d x y c > < J", "Visual", "Delete, delete, copy, change, indent, unindent, join the selection"],
    ]
    for r in rows:
        out += "| " + String(r[0]) + " | " + String(r[1]) + " | " + String(r[2]) + " |\n"
    out += "\nPatterns are vim's: `\\(` `\\)` `\\|` `\\+` `\\{n,m}` `\\<` `\\>` are operators and a bare `(` `|` `+` is the\ncharacter; `\\c` ignores case. Matches are marked until `:noh`.\n\n| Command line | What it does |\n|---|---|\n"
    var ex = [
        [":w", "Save (:w FILE writes a copy; :w! FILE over an existing file)"],
        [":q :q!", "Close the window (:q! without saving)"],
        [":wq :x", "Save and close (:x saves only when changed)"],
        [":wa :qa :wqa", "Save all / quit (asking about unsaved files) / both"],
        [":e FILE", "Open a file"],
        [":N", "Go to line N (also :$, :.+3)"],
        [":s/a/b/g", "Replace in this line; :%s for every line, :N,M for some, :'<,'> the selection; flags g i I; & and \\1 in the replacement"],
        [":d :y", "Delete / copy lines (with a range: :2,5d)"],
        [":noh", "Unmark the search's matches"],
        [":NAME", "One of TurboMojo's commands: :build, :run, :gotoLine, :compile.build, or its menu title"],
    ]
    for e in ex:
        out += "| " + String(e[0]) + " | " + String(e[1]) + " |\n"
    return out^
