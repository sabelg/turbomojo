"""A session: which files were open in a project, where the cursors were, and how the
windows were arranged - written as a small text file and read back at the next start."""
from std.collections import List
from util import decode, to_str


struct SessionFile(Copyable, Movable):
    var path: String
    var cr: Int
    var cc: Int
    var top: Int
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var zoomed: Bool
    var folds: List[Int]        # rows of the folded block headers

    def __init__(out self, path: String):
        self.path = path
        self.cr = 0
        self.cc = 0
        self.top = 0
        self.x = 0
        self.y = 1
        self.w = 0
        self.h = 0
        self.zoomed = False
        self.folds = List[Int]()


struct SessionData(Copyable, Movable):
    var root: String                # the project it belongs to
    var files: List[SessionFile]    # back to front: the last one had the keyboard
    var tiled: Bool
    var layout: String              # Layout.encode() with positions in `files` as ids
    var explorer: Bool
    var explorer_w: Int
    var opened: List[String]        # folders open in the explorer
    var outline: Bool
    var panel: Bool                 # the bottom panel
    var panel_page: Int
    var panel_h: Int

    def __init__(out self):
        self.root = ""
        self.files = List[SessionFile]()
        self.tiled = False
        self.layout = ""
        self.explorer = False
        self.explorer_w = 0
        self.opened = List[String]()
        self.outline = False
        self.panel = False
        self.panel_page = 0
        self.panel_h = 0

    def encode(self) -> String:
        """One "key<TAB>values" line per fact; paths come last on their line, so they
        may contain anything but a line break."""
        var s = String("turbomojo-session 1\n")
        s += "root\t" + self.root + "\n"
        s += "tiled\t" + ("1" if self.tiled else "0") + "\n"
        if self.layout.byte_length() > 0:
            s += "layout\t" + self.layout + "\n"
        if self.explorer:
            s += "explorer\t" + String(self.explorer_w) + "\n"
            for o in self.opened:
                s += "opened\t" + o + "\n"
        if self.outline:
            s += "outline\t1\n"
        if self.panel:
            s += "panel\t" + String(self.panel_page) + " " + String(self.panel_h) + "\n"
        for f in self.files:
            s += "file\t" + String(f.cr) + " " + String(f.cc) + " " + String(f.top) + " " + String(f.x) + " " + String(f.y) + " " + String(f.w) + " " + String(f.h) + " " + ("1" if f.zoomed else "0") + fold_words(f.folds) + "\t" + f.path + "\n"
        s += "end\n"
        return s


def fold_words(folds: List[Int]) -> String:
    """ " N r1 r2 ..." for a file's folds ("" when there are none, as older sessions)."""
    if len(folds) == 0:
        return ""
    var s = " " + String(len(folds))
    for r in folds:
        s += " " + String(r)
    return s


def session_numbers(text: String) -> List[Int]:
    """The non-negative numbers of a blank-separated text; empty if any word is not one."""
    var out = List[Int]()
    for w in text.split(" "):
        if w.byte_length() == 0:
            continue
        var n = 0
        for c in String(w).as_bytes():
            var d = Int(c) - 48
            if d < 0 or d > 9:
                return List[Int]()
            n = min(n * 10 + d, 1000000000)
        out.append(n)
    return out^


def session_decode(text: String) -> Tuple[SessionData, Bool]:
    """Read what encode() wrote. The flag is False (and the data empty) unless the text
    is a complete session of a version this program knows; single lines that do not
    fit are skipped."""
    var d = SessionData()
    var lines = text.split("\n")
    if len(lines) < 2 or String(lines[0]) != "turbomojo-session 1":
        return (SessionData(), False)
    var complete = False
    for k in range(1, len(lines)):
        var line = String(lines[k])
        if line == "end":
            complete = True
            break
        var tab = line.find("\t")
        if tab <= 0:
            continue
        var key = String(line[byte=0:tab])
        var rest = String(line[byte=tab + 1:])
        if key == "root":
            d.root = rest
        elif key == "tiled":
            d.tiled = rest == "1"
        elif key == "layout":
            d.layout = rest
        elif key == "explorer":
            var n = session_numbers(rest)
            if len(n) == 1:
                d.explorer = True
                d.explorer_w = n[0]
        elif key == "opened":
            if rest.startswith("/"):
                d.opened.append(rest)
        elif key == "outline":
            d.outline = rest == "1"
        elif key == "panel":
            var n = session_numbers(rest)
            if len(n) == 2:
                d.panel = True
                d.panel_page = n[0]
                d.panel_h = n[1]
        elif key == "file":
            var tab2 = rest.find("\t")
            if tab2 <= 0:
                continue
            var n = session_numbers(String(rest[byte=0:tab2]))
            var path = String(rest[byte=tab2 + 1:])
            # 8 numbers, then (since the folds were kept) their count and rows
            if len(n) < 8 or not path.startswith("/"):
                continue
            if len(n) > 8 and len(n) != 9 + n[8]:
                continue
            var f = SessionFile(path)
            f.cr = n[0]
            f.cc = n[1]
            f.top = n[2]
            f.x = n[3]
            f.y = n[4]
            f.w = n[5]
            f.h = n[6]
            f.zoomed = n[7] == 1
            for k in range(9, len(n)):
                f.folds.append(n[k])
            d.files.append(f^)
    if not complete:
        return (SessionData(), False)
    return (d^, True)
