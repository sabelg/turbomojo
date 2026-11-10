"""The Outline window: the symbols of the file being edited, as a tree to jump from."""
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
from buffer import TextBuffer, Pos, ENC_UTF8, ENC_LATIN1
from window import Window, WK_EDITOR, WK_MESSAGE, WK_OUTLINE, ACT_OTHER, ACT_TYPE
from window_search import *
from window_multi import *
from window_lines import *
from window_draw import *
from menu import *
from commands import *
from dialog import *
from util import *
from appstate import *
from app_lsp import *
from lsp import *
from markdown import *
from app_watch import *
from watch import *
from app_swap import *
from swap import *
from app_files import *
from app_dialogs import *
from app_menus import *
from app_exec import *
from app_jobs import *
from app_pickers import *
from app_nav import *
from outline import *
from symindex import *
from app_input import *
from app_mouse import *
from app_draw import *


comptime SYMIDX_SLICE_MS = 8          # work per pass of the event loop
comptime SYMIDX_FIRST_MS = 40         # ... and when the dialog opens
comptime SYMIDX_FRESH_MS = 20000      # an index older than this is rebuilt on the next use


__extension App:
    def outline_toggle(mut self):
        """Window > Outline: show the outline window at the right edge, or close it."""
        var oi = self.outline_index()
        if oi >= 0:
            var x = self.wins[oi].x
            _ = self.wins.pop(oi)
            # the editors that made room get it back
            for i in range(len(self.wins)):
                if self.wins[i].kind == WK_EDITOR and self.wins[i].x + self.wins[i].w == x:
                    self.wins[i].w = self.scr.w - self.wins[i].x
            return
        var w = max(22, min(36, self.scr.w // 3))
        var x = self.scr.w - w
        var h = self.desk_h()
        var mi = self.msg_index()
        if mi >= 0:
            h = max(6, self.wins[mi].y - 1)
        var win = Window(WK_OUTLINE, "Outline", "", x, 1, w, h, self.free_number())
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].x + self.wins[i].w > x and x - self.wins[i].x >= 20:
                self.wins[i].w = x - self.wins[i].x
        self.wins.insert(0, win^)
        self.outline_key = ""
        self.outline_version = -1
        self.outline_asked_key = ""
        self.outline_tick(now_ns())

    def outline_show(mut self):
        """Put self.outline_items into the Outline window, one per line."""
        var oi = self.outline_index()
        if oi < 0:
            return
        var text = List[Int]()
        for k in range(len(self.outline_items)):
            if k > 0:
                text.append(10)
            for c in decode(outline_line(self.outline_items[k])):
                text.append(c)
        if len(self.outline_items) == 0:
            text = decode("(no symbols)")
        var keep = self.wins[oi].cr
        var keep_top = self.wins[oi].top
        self.wins[oi].buf.load(text)
        self.wins[oi].buf.modified = False
        self.wins[oi].cr = max(0, min(keep, self.wins[oi].buf.count() - 1))
        self.wins[oi].top = max(0, min(keep_top, self.wins[oi].buf.count() - 1))

    def outline_tick(mut self, now: Int):
        """Keep the Outline window in step with the editor in front: a scan of the text
        at once, the language server's answer when it comes; the line of the symbol the
        cursor is in is marked."""
        var oi = self.outline_index()
        if oi < 0:
            return
        var ti = self.top_editor()
        if ti < 0:
            if self.outline_key.byte_length() > 0 or self.outline_version != -2:
                self.outline_items.clear()
                self.outline_key = ""
                self.outline_version = -2
                self.outline_show()
            return
        var key = self.wins[ti].path if self.wins[ti].path.byte_length() > 0 else "untitled:" + self.wins[ti].title
        var v = self.wins[ti].buf.version
        var server = self.lsp.state == LSP_READY and self.wins[ti].path.byte_length() > 0 and self.lsp.find_doc(path_to_uri(self.wins[ti].path)) >= 0
        if key != self.outline_key or v != self.outline_version:
            # while typing with a server at hand its (slightly old) list stays until the
            # new answer comes, so the list does not jump between the two sources
            if key != self.outline_key or not (server and self.outline_from_server):
                self.outline_items = scan_outline(self.wins[ti].buf)
                self.outline_from_server = False
                self.outline_show()
            self.outline_key = key
            self.outline_version = v
        if self.outline_req_id >= 0 and now - self.outline_req_ns > 5000000000:
            self.outline_req_id = -1            # never answered
        if server and self.outline_req_id < 0 and self.wins[ti].lsp_sent_version == v and (self.outline_asked_key != key or self.outline_asked_version != v):
            var id = self.lsp.request_symbols(path_to_uri(self.wins[ti].path), now)
            if id >= 0:
                self.outline_req_id = id
                self.outline_req_ns = now
                self.outline_asked_key = key
                self.outline_asked_version = v
        oi = self.outline_index()
        if self.top() != oi:
            var cur = outline_current(self.outline_items, self.wins[ti].cr)
            if cur >= 0 and self.wins[oi].cr != cur:
                self.wins[oi].cr = cur
                self.wins[oi].follow = True

    def outline_arrived(mut self, m: RpcMessage):
        self.outline_req_id = -1
        var oi = self.outline_index()
        var ti = self.top_editor()
        if oi < 0 or ti < 0 or self.wins[ti].path != self.outline_asked_key or self.wins[ti].buf.version != self.outline_asked_version:
            return                              # for other text: outline_tick asks again
        if m.kind == RPC_ERROR:
            if self.outline_from_server:
                self.outline_from_server = False
                self.outline_version = -1       # back to the scan
            return
        var items = parse_symbols(m.doc, m.result())
        if len(items) == 0:
            # nothing from the server (or it does not do this): the scan stays
            if self.outline_from_server:
                self.outline_from_server = False
                self.outline_version = -1
            return
        var count = self.wins[ti].buf.count()
        var kept = List[OutlineItem]()
        for it in items:
            if it.row < count:
                kept.append(OutlineItem(it.name, it.kind, it.row, utf16_to_col(self.wins[ti].buf.line(it.row), it.col), it.depth))
        self.outline_items = kept^
        self.outline_from_server = True
        self.outline_show()

    def outline_go(mut self, k: Int) raises:
        """Enter on line k of the Outline window: go to that symbol in the editor."""
        if k < 0 or k >= len(self.outline_items):
            return
        var ti = self.top_editor()
        if ti < 0:
            return
        var it = self.outline_items[k].copy()
        self.focus(ti)
        self.jump_mark()
        var t = self.top()
        self.wins[t].goto(it.row, it.col)
        self.say(it.name)

    # ============================================ symbols of the whole project
    def symidx_root(self) -> String:
        return self.project_dir if self.project_dir.byte_length() > 0 else String(self.cwd)

    def symidx_tick(mut self):
        """One slice of the index pass; called on every pass of the event loop. When a
        pass finishes while the dialog is open, its list is completed."""
        if not self.symidx.building:
            return
        self.symidx.step(SYMIDX_SLICE_MS)
        if not self.symidx.building:
            if self.mode == M_DIALOG and self.dlg.kind == D_WSYMBOL and self.ws_building:
                self.wsymbol_fill()
                self.say(self.symidx.summary())

    def wsymbol_items(mut self) -> List[IndexedSymbol]:
        """The index as it stands, with open files taken from their windows (they may
        have unsaved changes) and files of this pass not yet reached left as they were."""
        var all = List[IndexedSymbol]()
        var open_paths = List[String]()
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and is_mojo_file(self.wins[i].path) and not self.wins[i].buf.large:
                open_paths.append(self.wins[i].path)
                self.symidx.add_items(self.wins[i].path, scan_outline(self.wins[i].buf), all)
        var source = self.symidx.syms.copy()
        if not self.symidx.built:
            source = self.symidx.fresh.copy()       # the first pass: what it has so far
        for s in source:
            if not (s.path in open_paths):
                all.append(s.copy())
        return all^

    def wsymbol_fill(mut self):
        """(Re)fill the open dialog's list, keeping what was typed."""
        self.ws_list = self.wsymbol_items()
        self.ws_building = self.symidx.building
        var items = List[String]()
        var data = List[Int]()
        var keys = List[String]()           # typing matches names, not file paths
        var prefix = self.symidx_root() + "/"
        for k in range(len(self.ws_list)):
            var shown = self.ws_list[k].path
            if shown.startswith(prefix):
                shown = slice_str(decode(shown), cp_len(prefix), cp_len(shown))
            var name = outline_tag(self.ws_list[k].kind) + " " + self.ws_list[k].name
            if self.ws_list[k].owner.byte_length() > 0:
                name += "  (" + self.ws_list[k].owner + ")"
            items.append(pad_right(name, 34) + " " + shown + ":" + String(self.ws_list[k].row + 1))
            data.append(k)
            keys.append(self.ws_list[k].name + " " + self.ws_list[k].owner)
        self.dlg.keys = keys^
        self.dlg.set_items(items^, data^)

    def wsymbol_dialog(mut self):
        """Search > Go to symbol in project: a list of every def / struct / trait of the
        project's Mojo files, narrowed by typing. The index is (re)built in the
        background; the list fills in when it is ready."""
        var now = now_ns()
        if not self.symidx.building and (not self.symidx.built or self.symidx.root != self.symidx_root() or now - self.symidx.built_ns > SYMIDX_FRESH_MS * 1000000):
            self.symidx.start(self.symidx_root())
            self.symidx.step(SYMIDX_FIRST_MS)       # small projects are done at once
        var d = Dialog(D_WSYMBOL, "Go to Symbol in Project", min(76, self.scr.w - 4), min(22, self.desk_h()))
        d.fields.append(Field("~S~ymbol", ""))
        d.list_filter = True
        d.buttons.append("~G~o")
        d.buttons.append("~C~ancel")
        self.show(d^)
        self.wsymbol_fill()
        if self.symidx.building:
            self.say("Reading the project's files...")
        else:
            self.say(self.symidx.summary())

    def wsymbol_go(mut self, k: Int) raises:
        if k < 0 or k >= len(self.dlg.item_data):
            return
        var idx = self.dlg.item_data[k]
        if idx < 0 or idx >= len(self.ws_list):
            return
        var s = self.ws_list[idx].copy()
        if not (self.find_editor(s.path) >= 0 or path_exists(s.path)):
            self.say(basename(s.path) + " is no longer there")
            return
        self.jump_mark()
        self.open_path(s.path)
        var t = self.top()
        if self.wins[t].kind == WK_EDITOR and self.wins[t].path == s.path:
            self.wins[t].goto(s.row, s.col)
            self.say(s.name)
