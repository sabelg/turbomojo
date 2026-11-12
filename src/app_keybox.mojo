"""After a prefix key (WordStar's Ctrl-K and Ctrl-Q, Emacs's C-x, any two-key
binding): if the second key does not come within a moment, a box above the status
line lists the keys that may follow, with their commands. It never takes the
keyboard: the next key completes the sequence as before, Esc cancels it. Someone
who types the sequence quickly never sees it (KEY_BOX_MS, 200 ms). It is drawn away
from the cursor, and an option that is switched on or off says which it is now. With a screen reader the keys go to the
status line at once instead. ui.key_hints = false turns it off (with the key echo).
"""
from std.collections import List
from appstate import *
from util import *
from commands import plain, key_name, chord, CM_NONE
from app_menus import *
from window import WK_EDITOR

comptime KEY_BOX_COL_MAX = 30           # the widest a column of the box is


__extension App:
    def chord_entries(self, first: Int) -> List[String]:
        """"KEY  Command" for every key that may follow `first`."""
        var out = List[String]()
        for s in self.reg.chord_seconds(first):
            var cmd = self.reg.find_key(chord(first, s))
            var ci = self.reg.index_of(cmd)
            if cmd == CM_NONE or ci < 0:
                continue
            var state = String("")
            if cmd in self.toggle_cmds():
                state = ": on" if cmd in self.checked() else ": off"
            out.append(key_name(s) + "  " + plain(self.reg.cmds[ci].title).strip(". ") + state)
        return out^

    def chord_line(self, first: Int) -> String:
        var out = key_name(first) + " then: "
        var e = self.chord_entries(first)
        for k in range(len(e)):
            out += (", " if k > 0 else String("")) + e[k]
        return out^

    def chord_tick(mut self, now: Int):
        if self.chord != 0 and not self.chord_box and self.key_hints and not self.reader and now >= self.chord_since + KEY_BOX_MS * 1000000:
            self.chord_box = True

    def chord_box_place(self, w: Int, h: Int) -> Tuple[Int, Int]:
        """Where the box goes: above the status line at the left, unless the cursor is
        there - then at the top, or at the right (it never covers where you type)."""
        var spots = List[Tuple[Int, Int]]()
        spots.append((1, self.scr.h - 1 - h))
        spots.append((1, 1))
        spots.append((max(1, self.scr.w - w - 2), self.scr.h - 1 - h))
        spots.append((max(1, self.scr.w - w - 2), 1))
        # the cursor of this frame (the screen's is placed after the boxes are drawn)
        var cx = -1
        var cy = -1
        var t = self.top()
        if t >= 0 and self.wins[t].kind == WK_EDITOR:
            var c = self.wins[t].cursor_cell()
            cx = c.c
            cy = c.r
        elif self.scr.cvis:
            cx = self.scr.cx
            cy = self.scr.cy
        if cx < 0:
            return spots[0]
        for s in spots:
            var x = s[0]
            var y = s[1]
            # (the shadow too: one row below, two columns to the right)
            if not (cx >= x and cx < x + w + 2 and cy >= y and cy < y + h + 1):
                return s
        return spots[0]

    def draw_chord_box(mut self):
        if self.chord == 0 or not self.chord_box:
            return
        var e = self.chord_entries(self.chord)
        if len(e) == 0:
            return
        var p = self.pal.copy()
        var colw = 0
        for s in e:
            colw = max(colw, cp_len(s) + 3)
        colw = min(colw, KEY_BOX_COL_MAX)
        var cols = max(1, min(len(e), (self.scr.w - 4) // colw))
        var rows = (len(e) + cols - 1) // cols
        var most = max(1, self.scr.h - 6)
        var cut_short = rows > most
        if cut_short:
            rows = most
        var w = cols * colw + 3
        var h = rows + 2
        var place = self.chord_box_place(w, h)
        var x = place[0]
        var y = place[1]
        self.scr.fill(x, y, w, h, 32, p.dlg_fg, p.dlg_bg)
        self.scr.frame(x, y, w, h, False, p.dlg_frame, p.dlg_bg)
        var title = " " + key_name(self.chord) + " ... (Esc cancels) "
        self.scr.clip(x + 1, y, w - 2, 1)
        _ = self.scr.text(x + 2, y, title, p.dlg_title, p.dlg_bg)
        self.scr.no_clip()
        for k in range(len(e)):
            var c = k // rows
            var r = k % rows
            if c >= cols:
                break
            var cx = x + 2 + c * colw
            var sp = e[k].find("  ")
            self.scr.clip(cx, y + 1 + r, colw - 1, 1)
            var after = self.scr.text(cx, y + 1 + r, String(e[k][byte=0:sp]), p.dlg_hot, p.dlg_bg)
            _ = self.scr.text(after, y + 1 + r, String(e[k][byte=sp:]), p.dlg_fg, p.dlg_bg)
            self.scr.no_clip()
        if cut_short:
            _ = self.scr.text(x + w - 6, y + h - 1, " ... ", p.dlg_frame, p.dlg_bg)
        self.scr.shadow(x, y, w, h, p.shadow_fg, p.shadow_bg)
