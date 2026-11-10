"""List pickers: command palette, symbols, keyboard reference, word completion."""
from std.collections import List, Dict
from std.time import perf_counter_ns
from std.ffi import external_call
from term import (
    Terminal, Event, EV_KEY, EV_MOUSE, EV_PASTE, K_BASE, KEY_ESC, KEY_ENTER, KEY_TAB,
    KEY_BACKSPACE, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_PGUP,
    KEY_PGDN, KEY_INSERT, KEY_DELETE, MOD_SHIFT, MOD_ALT, MOD_CTRL, KEY_MASK, fkey, ctrl, alt,
    MB_LEFT, MB_WHEEL_UP, MB_WHEEL_DOWN,
)
from screen import Screen
from palette import Palette, theme, THEME_COUNT
from highlight import Highlighter
from buffer import TextBuffer, Pos
from window import Window, WK_EDITOR, WK_MESSAGE, ACT_OTHER, ACT_TYPE
from window_search import *
from window_draw import *
from menu import *
from commands import *
from dialog import *
from util import *
from appstate import *
from app_lsp import *
from lsp import *
from app_watch import *
from watch import *
from app_swap import *
from swap import *
from app_files import *
from app_dialogs import *
from app_menus import *
from app_exec import *
from app_jobs import *
from app_input import *
from app_mouse import *
from app_draw import *


__extension App:
    def palette_dialog(mut self):
        var d = Dialog(D_PALETTE, "Command Palette", min(66, self.scr.w - 4), min(20, self.desk_h()))
        d.fields.append(Field(">", ""))
        d.list_filter = True
        var items = List[String]()
        var data = List[Int]()
        var seen = List[Int]()
        for m in self.menus:
            var title = plain(m.title)
            if title == "≡":
                title = "System"
            for it in m.items:
                if it.cmd == CM_NONE or it.cmd in seen:
                    continue
                seen.append(it.cmd)
                items.append(pad_right(title + ": " + plain(it.label), 40) + self.reg.all_keys_label(it.cmd))
                data.append(it.cmd)
        d.set_items(items^, data^)
        d.buttons.append("~R~un")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def symbol_dialog(mut self):
        var ai = self.active_editor()
        if ai < 0:
            return
        var d = Dialog(D_SYMBOL, "Go to Symbol", min(64, self.scr.w - 4), min(20, self.desk_h()))
        d.fields.append(Field("~S~ymbol", ""))
        d.list_filter = True
        var items = List[String]()
        var data = List[Int]()
        for r in range(self.wins[ai].buf.count()):
            var ind = self.wins[ai].indent_of(r)
            var line = self.wins[ai].buf.lines[r].c.copy()
            var rest = slice_str(line, ind, len(line))
            var kw = String("")
            for k in ["def ", "fn ", "struct ", "trait ", "comptime "]:
                if rest.startswith(k):
                    kw = String(k)
            if kw.byte_length() == 0:
                continue
            if kw == "comptime " and ind > 0:
                continue
            var s0 = ind + cp_len(kw)
            var e = s0
            while e < len(line) and is_ident(line[e]):
                e += 1
            if e == s0:
                continue
            var name = slice_str(line, s0, e)
            var pad = String("")
            for _ in range(self.wins[ai].vcol(r, ind) // max(1, self.wins[ai].buf.indent_size)):
                pad += "  "
            var tag = String("ƒ ") if kw == "def " or kw == "fn " else (String("◆ ") if kw == "struct " else (String("◇ ") if kw == "trait " else String("= ")))
            items.append(pad_right(pad + tag + name, 44) + ":" + String(r + 1))
            data.append(r)
        if len(items) == 0:
            self.say("No symbols found")
            return
        d.set_items(items^, data^)
        d.buttons.append("~G~o")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def help_dialog(mut self):
        """Keyboard reference generated from the command registry."""
        var d = Dialog(D_HELP, "Keyboard Reference", min(72, self.scr.w - 4), min(24, self.desk_h()))
        var items = List[String]()
        for mi in range(1, len(self.reg.menu_titles)):
            var lines = List[String]()
            for p in self.reg.layout:
                if p.menu != mi or p.cmd == CM_NONE:
                    continue
                var keys = self.reg.all_keys_label(p.cmd)
                if keys.byte_length() == 0:
                    continue
                var ci = self.reg.index_of(p.cmd)
                var title = plain(self.reg.cmds[ci].title)
                if title.endswith("..."):
                    var tc = decode(title)
                    title = slice_str(tc, 0, len(tc) - 3)
                lines.append("  " + pad_right(keys, 24) + title)
            if len(lines) == 0:
                continue
            if len(items) > 0:
                items.append("")
            items.append(lower_to_upper(plain(self.reg.menu_titles[mi])))
            for l in lines:
                items.append(l)
        for l in [
            "",
            "MENUS",
            "  F10                     Open the menu bar",
            "  Alt-<letter>            Open the menu with that highlighted letter",
            "  Alt-1..9                Go to window number",
            "  Esc                     Close a menu or dialog",
            "",
            "EDITING",
            "  Arrows, Home, End       Move (Home toggles indent / column 1)",
            "  Ctrl-Left/Right         Move by word",
            "  Ctrl-Home/End           Start / end of file",
            "  PgUp/PgDn               Page; Ctrl-Up/Down scrolls the view",
            "  Shift + movement        Select",
            "  Tab / Shift-Tab         Indent / outdent (selection or line)",
            "  Ins                     Insert / overwrite mode",
            "",
            "MOUSE",
            "  Click, drag, wheel      Place cursor, select, scroll",
            "  Title bar / corner      Move / resize a window",
            "  [■] / [↑]               Close / zoom a window",
        ]:
            items.append(String(l))
        var data = List[Int]()
        for _ in range(len(items)):
            data.append(0)
        d.set_items(items^, data^)
        d.focus = 0
        d.buttons.append("~O~K")
        self.show(d^)

    # ============================================================ completion
    def collect_completions(self, ai: Int, prefix: String) -> List[String]:
        var seen = Dict[String, Int]()
        var out = List[String]()
        var pc = decode(prefix)
        var np = len(pc)
        for r in range(self.wins[ai].buf.count()):
            var line = self.wins[ai].buf.lines[r].c.copy()
            var i = 0
            var n = len(line)
            while i < n:
                if is_alpha(line[i]) and (i == 0 or not is_ident(line[i - 1])):
                    var j = i
                    while j < n and is_ident(line[j]):
                        j += 1
                    if j - i > np and j - i >= 2:
                        var ok = True
                        for k in range(np):
                            if line[i + k] != pc[k]:
                                ok = False
                                break
                        if ok and not (r == self.wins[ai].cr and j == self.wins[ai].cc):
                            var w = slice_str(line, i, j)
                            if w not in seen:
                                seen[w] = 1
                                out.append(w)
                    i = j
                else:
                    i += 1
            if len(out) > 200:
                break
        for lst in [self.hl.kws.copy(), self.hl.types.copy(), self.hl.builtins.copy()]:
            for w in lst:
                if w.startswith(prefix) and w != prefix and w not in seen:
                    seen[w] = 1
                    out.append(w)
        return out^

    def start_complete(mut self):
        var ai = self.active_editor()
        if ai < 0:
            return
        var start = self.wins[ai].word_start()
        var prefix = slice_str(self.wins[ai].buf.lines[self.wins[ai].cr].c, start, self.wins[ai].cc)
        if prefix.byte_length() == 0:
            self.say("Type the start of an identifier, then Ctrl-Space")
            return
        var items = self.collect_completions(ai, prefix)
        if len(items) == 0:
            self.say("No completions for '" + prefix + "'")
            self.mode = M_NORMAL
            return
        if len(items) == 1 and self.mode != M_COMPLETE:
            var cps = decode(items[0])
            var rest = List[Int]()
            for k in range(len(decode(prefix)), len(cps)):
                rest.append(cps[k])
            self.wins[ai].insert_text(rest, ACT_TYPE)
            return
        self.comp_items = items^
        self.comp_sel = 0
        self.comp_start = start
        self.mode = M_COMPLETE

    def complete_key(mut self, k: Int) -> Bool:
        var ai = self.active_editor()
        if ai < 0:
            self.mode = M_NORMAL
            return False
        var n = len(self.comp_items)
        if k == KEY_UP:
            self.comp_sel = (self.comp_sel - 1 + n) % n
            return True
        if k == KEY_DOWN:
            self.comp_sel = (self.comp_sel + 1) % n
            return True
        if k == KEY_PGUP:
            self.comp_sel = max(0, self.comp_sel - 8)
            return True
        if k == KEY_PGDN:
            self.comp_sel = min(n - 1, self.comp_sel + 8)
            return True
        if k == KEY_ESC:
            self.mode = M_NORMAL
            return True
        if k == KEY_ENTER or k == KEY_TAB:
            var cps = decode(self.comp_items[self.comp_sel])
            var plen = self.wins[ai].cc - self.comp_start
            var rest = List[Int]()
            for q in range(plen, len(cps)):
                rest.append(cps[q])
            self.wins[ai].insert_text(rest, ACT_TYPE)
            self.wins[ai].break_group()
            self.mode = M_NORMAL
            return True
        if k < K_BASE and is_ident(k):
            self.wins[ai].type_char(k, True)
            self.start_complete()
            return True
        if k == KEY_BACKSPACE:
            self.wins[ai].backspace()
            if self.wins[ai].cc <= self.comp_start:
                self.mode = M_NORMAL
            else:
                self.start_complete()
            return True
        self.mode = M_NORMAL
        return False
