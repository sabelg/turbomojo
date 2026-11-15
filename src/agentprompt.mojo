"""Agent prompt composer and slash-command parser for ACP coding agent panel."""
from std.collections import List
from term import (
    KEY_ENTER, KEY_BACKSPACE, KEY_DELETE, KEY_LEFT, KEY_RIGHT,
    KEY_HOME, KEY_END, MOD_ALT, MOD_SHIFT, KEY_UP, KEY_DOWN, K_BASE,
)
from util import decode, to_str


def parse_slash_command(text: String) -> Tuple[String, String]:
    """Parses '/' command verb and arguments if text starts with '/'.

    Example: '/model gemini-3.1-pro' -> ('/model', 'gemini-3.1-pro').
    """
    var s = text.strip()
    if not s.startswith("/"):
        return ("", "")
    var sp = s.find(" ")
    if sp < 0:
        return (String(s), "")
    return (String(s[byte=0:sp]), String(s[byte=sp + 1:].strip()))


def available_slash_commands() -> List[String]:
    """Returns the list of supported ACP agent slash commands."""
    var cmds = List[String]()
    cmds.append("/model")
    cmds.append("/mode")
    cmds.append("/thinking")
    cmds.append("/clear")
    cmds.append("/revert")
    cmds.append("/help")
    return cmds^


def filter_slash_commands(prefix: String) -> List[String]:
    """Filters available slash commands by matching prefix for popup picker."""
    var out = List[String]()
    for cmd in available_slash_commands():
        if cmd.startswith(prefix):
            out.append(cmd)
    return out^


struct AgentPrompt(Movable):
    """The multi-line agent prompt composer state and navigation logic."""
    var input: List[Int]
    var cur: Int
    var history: List[String]
    var hist_idx: Int
    var draft: List[Int]
    var scroll: Int

    def __init__(out self):
        self.input = List[Int]()
        self.cur = 0
        self.history = List[String]()
        self.hist_idx = -1
        self.draft = List[Int]()
        self.scroll = 0

    def key(mut self, k: Int) -> Bool:
        var n = len(self.input)
        self.cur = max(0, min(self.cur, n))
        if k == KEY_BACKSPACE:
            if self.cur > 0:
                _ = self.input.pop(self.cur - 1)
                self.cur -= 1
            return True
        if k == KEY_DELETE:
            if self.cur < n:
                _ = self.input.pop(self.cur)
            return True
        if k == KEY_LEFT:
            self.cur = max(0, self.cur - 1)
            return True
        if k == KEY_RIGHT:
            self.cur = min(n, self.cur + 1)
            return True
        if k == KEY_HOME:
            self.cur = 0
            return True
        if k == KEY_END:
            self.cur = n
            return True
        if k == (KEY_UP | MOD_ALT):
            if len(self.history) > 0:
                if self.hist_idx < 0:
                    self.draft = self.input.copy()
                    self.hist_idx = len(self.history) - 1
                elif self.hist_idx > 0:
                    self.hist_idx -= 1
                self.input = decode(self.history[self.hist_idx])
                self.cur = len(self.input)
            return True
        if k == (KEY_DOWN | MOD_ALT):
            if self.hist_idx >= 0:
                self.hist_idx += 1
                if self.hist_idx >= len(self.history):
                    self.hist_idx = -1
                    self.input = self.draft.copy()
                else:
                    self.input = decode(self.history[self.hist_idx])
                self.cur = len(self.input)
            return True
        if k == (KEY_ENTER | MOD_SHIFT):
            self.insert_newline()
            return True
        if k >= 32 and k < K_BASE:
            self.input.insert(self.cur, k)
            self.cur += 1
            return True
        return False

    def insert_newline(mut self):
        """Insert newline into prompt (Shift-Enter)."""
        self.cur = max(0, min(self.cur, len(self.input)))
        self.input.insert(self.cur, 10)
        self.cur += 1

    def paste(mut self, text: List[Int]) -> Bool:
        """Preserves newlines (10) and spaces during paste, stripping CR (13)."""
        self.cur = max(0, min(self.cur, len(self.input)))
        for c in text:
            var ch = c
            if ch == 13:
                continue
            self.input.insert(self.cur, ch)
            self.cur += 1
        return True

    def input_rows(self, width: Int) -> List[List[Int]]:
        """Wraps prompt into multiple rows with '› ' prompt indicator."""
        var rows = List[List[Int]]()
        var cur_row = decode("› ")
        var shown = self.input.copy()
        var wrap_w = max(3, width)
        for c in shown:
            if c == 10:  # Newline
                rows.append(cur_row^)
                cur_row = decode("  ")
                continue
            if len(cur_row) >= wrap_w:
                rows.append(cur_row^)
                cur_row = decode("  ")
            cur_row.append(c)
        rows.append(cur_row^)
        return rows^

    def calculate_cursor(self, width: Int, win_x: Int, win_y: Int, win_w: Int, win_h: Int) -> Tuple[Int, Int]:
        """Calculates (cx, cy) screen cursor coordinates for the prompt."""
        var rows = self.input_rows(width)
        var keep = min(len(rows), max(1, win_h // 3))
        var area = win_h - keep - 1
        var per = max(1, width - 2)
        var row = 0
        var seg_col = 0
        var lim = max(0, min(self.cur, len(self.input)))
        for idx in range(lim):
            var c = self.input[idx]
            if c == 10:
                row += 1
                seg_col = 0
            else:
                if seg_col >= per:
                    row += 1
                    seg_col = 0
                seg_col += 1
        if lim < len(self.input) and self.input[lim] != 10 and seg_col >= per:
            row += 1
            seg_col = 0
        var col = 2 + seg_col
        if row >= len(rows):
            row = len(rows) - 1
            col = len(rows[row])
        col = min(col, max(0, win_w - 1))
        var r0 = len(rows) - keep
        var cy = win_y + area + 1 + max(0, row - r0)
        var cx = win_x + col
        return (cx, cy)

    def parse_slash_command(self) -> Tuple[String, String]:
        """Parses '/' command and arguments if prompt starts with '/'."""
        return parse_slash_command(to_str(self.input))
