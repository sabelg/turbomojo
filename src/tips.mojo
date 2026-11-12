"""Tips that answer what you just did, instead of a random tip at start-up: a few
rules watch the keys for a slow way of doing something there is a quick way for, and
name the quick way once - at the next pause, never again after that, and not at all
with ui.tips = false.

The rules:
- many PgUp / PgDn in a short time        -> Go to symbol (the function by name)
- a long run of Left / Right              -> Ctrl-Left / Ctrl-Right move by words
- a long run of Backspace                 -> Ctrl-Backspace deletes a word
- Find opened again and again             -> Search again finds the next one
"""
from std.collections import List

comptime TK_OTHER = 0      # any other key: runs are broken
comptime TK_PAGE = 1       # PgUp / PgDn in an editor
comptime TK_LR = 2         # plain Left / Right
comptime TK_BS = 3         # plain Backspace
comptime TK_FIND = 4       # the Find dialog was opened

comptime TIP_PAGE = 0
comptime TIP_WORDS = 1
comptime TIP_BACKSPACE = 2
comptime TIP_AGAIN = 3
comptime TIP_COUNT = 4

comptime PAGES_FOR_TIP = 6          # page presses ...
comptime PAGES_WITHIN_MS = 10000    # ... within this long
comptime LR_FOR_TIP = 20            # Left / Right in a row
comptime BS_FOR_TIP = 12            # Backspace in a row
comptime FINDS_FOR_TIP = 3          # Find opened ...
comptime FINDS_WITHIN_MS = 120000   # ... within this long


def tip_name(t: Int) -> String:
    """The tip's stable name (what tips-shown keeps)."""
    if t == TIP_PAGE:
        return "goto-symbol"
    if t == TIP_WORDS:
        return "word-moves"
    if t == TIP_BACKSPACE:
        return "delete-word"
    if t == TIP_AGAIN:
        return "search-again"
    return ""


struct TipRules(Copyable, Movable):
    var pages: List[Int]        # when the recent page presses were
    var finds: List[Int]        # when Find was recently opened
    var lr: Int                 # Left / Right in a row
    var bs: Int                 # Backspace in a row

    def __init__(out self):
        self.pages = List[Int]()
        self.finds = List[Int]()
        self.lr = 0
        self.bs = 0

    def feed(mut self, kind: Int, now: Int) -> Int:
        """One key (or Find) at time `now` (ns). The tip it calls for, or -1."""
        if kind != TK_LR:
            self.lr = 0
        if kind != TK_BS:
            self.bs = 0
        if kind == TK_PAGE:
            self.pages.append(now)
            var kept = List[Int]()
            for t in self.pages:
                if now - t <= PAGES_WITHIN_MS * 1000000:
                    kept.append(t)
            self.pages = kept^
            if len(self.pages) >= PAGES_FOR_TIP:
                self.pages.clear()
                return TIP_PAGE
        elif kind == TK_LR:
            self.lr += 1
            if self.lr >= LR_FOR_TIP:
                self.lr = 0
                return TIP_WORDS
        elif kind == TK_BS:
            self.bs += 1
            if self.bs >= BS_FOR_TIP:
                self.bs = 0
                return TIP_BACKSPACE
        elif kind == TK_FIND:
            self.finds.append(now)
            var kept = List[Int]()
            for t in self.finds:
                if now - t <= FINDS_WITHIN_MS * 1000000:
                    kept.append(t)
            self.finds = kept^
            if len(self.finds) >= FINDS_FOR_TIP:
                self.finds.clear()
                return TIP_AGAIN
        return -1


def parse_shown(text: String) -> List[String]:
    var out = List[String]()
    for l in text.split("\n"):
        var s = String(String(l).strip())
        if s.byte_length() > 0 and s not in out:
            out.append(s)
    return out^
