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
from buffer import TextBuffer, Pos, ENC_UTF8, ENC_LATIN1
from window import Window, WK_EDITOR, WK_MESSAGE, ACT_OTHER, ACT_TYPE
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
            var line = self.wins[ai].buf.line(r)
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
            var line = self.wins[ai].buf.line(r)
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

    def comp_rebuild(mut self, prefix: String, words: List[String]):
        """Fill the popup's lists: the server's items that fit what is typed, in the
        server's order, then words from the text that the server did not offer."""
        self.comp_items.clear()
        self.comp_insert.clear()
        self.comp_kind.clear()
        self.comp_detail.clear()
        self.comp_doc.clear()
        self.comp_raw.clear()
        var seen = Dict[String, Int]()
        if self.comp_srv_have:
            for k in range(len(self.comp_srv)):
                if prefix.byte_length() > 0 and not self.comp_srv[k].filter.startswith(prefix):
                    continue
                if self.comp_srv[k].label in seen:
                    continue
                seen[self.comp_srv[k].label] = 1
                self.comp_items.append(self.comp_srv[k].label)
                self.comp_insert.append(self.comp_srv[k].insert)
                self.comp_kind.append(self.comp_srv[k].kind)
                self.comp_detail.append(self.comp_srv[k].detail)
                self.comp_doc.append(self.comp_srv[k].doc)
                self.comp_raw.append(self.comp_srv[k].raw)
        for w in words:
            if w in seen:
                continue
            seen[w] = 1
            self.comp_items.append(w)
            self.comp_insert.append(w)
            self.comp_kind.append(-1)
            self.comp_detail.append("")
            self.comp_doc.append("")
            self.comp_raw.append("")

    def lsp_request_completion(mut self, ai: Int, start: Int, trigger: String) -> Bool:
        """Ask the language server what could come at the cursor. The answer arrives
        later (completion_arrived). False if there is no server to ask."""
        var path = self.wins[ai].path
        if path.byte_length() == 0 or self.lsp.state != LSP_READY or not self.lsp.table.completion:
            return False
        var uri = path_to_uri(path)
        if self.lsp.find_doc(uri) < 0:
            return False
        var now = now_ns()
        self.lsp_send_changes(ai, now, False)          # the server must see what was just typed
        var id = self.lsp.request_completion(uri, self.wins[ai].cr, self.wins[ai].buf.utf16_col(self.wins[ai].cr, self.wins[ai].cc), trigger, now)
        if id < 0:
            return False
        self.comp_req_id = id
        self.comp_req_path = path
        self.comp_req_row = self.wins[ai].cr
        self.comp_req_start = start
        self.comp_req_trigger = trigger
        self.comp_retry_due = 0
        return True

    def completion_retry(mut self, now: Int):
        """The server was still analysing the last edit when it was asked: ask again,
        if the cursor is still in the same word."""
        self.comp_retry_due = 0
        var ai = self.active_editor()
        if ai < 0 or self.wins[ai].path != self.comp_req_path or self.wins[ai].cr != self.comp_req_row or self.wins[ai].word_start() != self.comp_req_start:
            self.comp_waiting = False
            return
        var keep = self.comp_waiting
        var trig = String(self.comp_req_trigger)
        if not self.lsp_request_completion(ai, self.comp_req_start, trig):
            self.comp_waiting = False
            return
        self.comp_waiting = keep

    def start_complete(mut self):
        var ai = self.active_editor()
        if ai < 0:
            return
        self.wins[ai].collapse()
        var start = self.wins[ai].word_start()
        var prefix = slice_str(self.wins[ai].buf.line(self.wins[ai].cr), start, self.wins[ai].cc)
        # the server's list is good for as long as the same word is being typed
        var same = self.comp_srv_have and not self.comp_srv_incomplete and self.comp_srv_path == self.wins[ai].path and self.comp_srv_row == self.wins[ai].cr and self.comp_srv_start == start
        var asked = False
        if not same:
            self.comp_srv_have = False
            self.comp_retries = 0
            asked = self.lsp_request_completion(ai, start, "")
        var words = List[String]()
        var line = self.wins[ai].buf.line(self.wins[ai].cr)
        var member = start > 0 and start <= len(line) and line[start - 1] == 46
        if prefix.byte_length() > 0 and not (member and same and len(self.comp_srv) > 0):
            words = self.collect_completions(ai, prefix)
        self.comp_rebuild(prefix, words)
        self.comp_waiting = False
        if len(self.comp_items) == 0:
            self.mode = M_NORMAL
            if asked:
                self.comp_waiting = True
                self.say("Asking the language server...")
            elif prefix.byte_length() == 0:
                self.say("Type the start of an identifier, then Ctrl-Space")
            else:
                self.say("No completions for '" + prefix + "'")
            return
        if len(self.comp_items) == 1 and self.mode != M_COMPLETE and not asked and self.comp_kind[0] < 0:
            var cps = decode(self.comp_items[0])
            var rest = List[Int]()
            for k in range(len(decode(prefix)), len(cps)):
                rest.append(cps[k])
            self.wins[ai].insert_text(rest, ACT_TYPE)
            return
        self.comp_sel = 0
        self.comp_start = start
        self.mode = M_COMPLETE
        self.comp_want_details()

    def completion_arrived(mut self, m: RpcMessage):
        """The server's answer to a completion request."""
        self.comp_req_id = -1
        var waiting = self.comp_waiting
        self.comp_waiting = False
        var ai = self.active_editor()
        if m.kind == RPC_ERROR:
            # "not now" answers are followed by another try a moment later
            var again = retry_later(m)
            if again and self.comp_retries < COMP_MAX_RETRIES and (waiting or self.mode == M_COMPLETE):
                self.comp_retries += 1
                self.comp_retry_due = now_ns() + COMP_RETRY_MS * 1000000
                self.comp_waiting = waiting
                return
            self.log_error("language server: completion failed: " + m.error_message())
            if waiting:
                self.say("Language server: " + m.error_message())
            return
        self.comp_retries = 0
        if m.kind != RPC_RESPONSE or ai < 0 or (self.mode != M_COMPLETE and not waiting):
            return
        # only if the cursor is still in the word the question was about
        if self.wins[ai].path != self.comp_req_path or self.wins[ai].cr != self.comp_req_row or self.wins[ai].word_start() != self.comp_req_start:
            return
        var lst = parse_completion(m.doc, m.result())
        self.comp_srv = lst.items.copy()
        self.comp_srv_have = True
        self.comp_srv_incomplete = lst.incomplete
        self.comp_srv_path = self.comp_req_path
        self.comp_srv_row = self.comp_req_row
        self.comp_srv_start = self.comp_req_start
        var start = self.comp_req_start
        var prefix = slice_str(self.wins[ai].buf.line(self.wins[ai].cr), start, self.wins[ai].cc)
        # if the user has already moved the bar, it stays on that item
        var keep = String("")
        if self.mode == M_COMPLETE and self.comp_sel > 0 and self.comp_sel < len(self.comp_items):
            keep = self.comp_items[self.comp_sel]
        var words = List[String]()
        var line = self.wins[ai].buf.line(self.wins[ai].cr)
        var member = start > 0 and start <= len(line) and line[start - 1] == 46
        if prefix.byte_length() > 0 and not (member and len(self.comp_srv) > 0):
            # after "x." the server's members are the answer; keywords would be noise
            words = self.collect_completions(ai, prefix)
        self.comp_rebuild(prefix, words)
        if len(self.comp_items) == 0:
            if waiting:
                self.say("No completions here")
            self.mode = M_NORMAL
            return
        self.comp_sel = 0
        # the user's choice stays under the cursor bar if it is still in the list
        if keep.byte_length() > 0:
            for k in range(len(self.comp_items)):
                if self.comp_items[k] == keep:
                    self.comp_sel = k
                    break
        self.comp_start = start
        self.mode = M_COMPLETE
        self.comp_want_details()

    def comp_want_details(mut self):
        """Ask the server for the documentation of the selected item if it came
        without (servers often send it only on request)."""
        if self.mode != M_COMPLETE or self.comp_sel >= len(self.comp_items):
            return
        var k = self.comp_sel
        if self.comp_kind[k] < 0 or self.comp_doc[k].byte_length() > 0 or self.comp_raw[k].byte_length() == 0:
            return
        if self.comp_resolve_label == self.comp_items[k]:
            return                          # already asked for this one
        var id = self.lsp.request_resolve(self.comp_raw[k], now_ns())
        if id >= 0:
            self.comp_resolve_id = id
            self.comp_resolve_label = self.comp_items[k]

    def resolve_arrived(mut self, m: RpcMessage):
        self.comp_resolve_id = -1
        if m.kind != RPC_RESPONSE or m.result() < 0:
            return
        var it = parse_completion_item(m.doc, m.result())
        for k in range(len(self.comp_items)):
            if self.comp_items[k] == self.comp_resolve_label and self.comp_kind[k] >= 0:
                if it.detail.byte_length() > 0:
                    self.comp_detail[k] = it.detail
                self.comp_doc[k] = it.doc
        for k in range(len(self.comp_srv)):
            if self.comp_srv[k].label == self.comp_resolve_label:
                if it.detail.byte_length() > 0:
                    self.comp_srv[k].detail = it.detail
                self.comp_srv[k].doc = it.doc

    def comp_accept(mut self, ai: Int):
        """Put the selected item into the text in place of what was typed of it."""
        var k = self.comp_sel
        var text = decode(self.comp_insert[k])
        var typed = self.wins[ai].buf.get_text(self.wins[ai].cr, self.comp_start, self.wins[ai].cr, self.wins[ai].cc)
        var extends = len(text) >= len(typed)
        if extends:
            for q in range(len(typed)):
                if text[q] != typed[q]:
                    extends = False
                    break
        if extends:
            # the usual case: only the missing part is typed for the user
            var rest = List[Int]()
            for q in range(len(typed), len(text)):
                rest.append(text[q])
            self.wins[ai].insert_text(rest, ACT_TYPE)
        else:
            self.wins[ai].sel = True
            self.wins[ai].ar = self.wins[ai].cr
            self.wins[ai].ac = self.comp_start
            self.wins[ai].insert_text(text, ACT_OTHER)
        self.wins[ai].break_group()
        self.comp_srv_have = False
        self.mode = M_NORMAL

    def maybe_trigger_completion(mut self, ch: Int):
        """After a character was typed in the editor: if it is one of the server's
        trigger characters (such as "."), ask for completions at once."""
        if self.lsp.state != LSP_READY or len(self.lsp.table.completion_triggers) == 0:
            return
        var ai = self.active_editor()
        if ai < 0 or self.wins[ai].has_multi():
            return
        var one = List[Int]()
        one.append(ch)
        var s = to_str(one)
        if not (s in self.lsp.table.completion_triggers):
            return
        self.comp_srv_have = False
        self.comp_retries = 0
        if self.lsp_request_completion(ai, self.wins[ai].cc, s):
            self.comp_waiting = True

    # ================================================================== hover
    def hover_command(mut self):
        """Search > Describe symbol: ask the language server about the symbol at the
        cursor; the answer opens in a small window (hover_arrived)."""
        var ai = self.active_editor()
        if ai < 0:
            return
        self.wins[ai].collapse()
        self.hover_retries = 0
        if not self.hover_request(ai):
            if self.lsp.state == LSP_READY and not self.lsp.table.hover:
                self.say("This language server does not describe symbols")
            else:
                self.say("Start the language server first (" + self.reg.key_label(CM_LSP) + ")")
            return
        self.say("Asking the language server...")

    def hover_request(mut self, ai: Int) -> Bool:
        var path = self.wins[ai].path
        if path.byte_length() == 0 or self.lsp.state != LSP_READY or not self.lsp.table.hover:
            return False
        var uri = path_to_uri(path)
        if self.lsp.find_doc(uri) < 0:
            return False
        var now = now_ns()
        self.lsp_send_changes(ai, now, False)
        var id = self.lsp.request_hover(uri, self.wins[ai].cr, self.wins[ai].buf.utf16_col(self.wins[ai].cr, self.wins[ai].cc), now)
        if id < 0:
            return False
        self.hover_req_id = id
        self.hover_req_path = path
        self.hover_req_row = self.wins[ai].cr
        self.hover_req_col = self.wins[ai].cc
        self.hover_retry_due = 0
        return True

    def hover_still_wanted(self) -> Bool:
        """The cursor has not moved since the question was asked."""
        var ai = self.active_editor()
        return ai >= 0 and self.mode == M_NORMAL and self.wins[ai].path == self.hover_req_path and self.wins[ai].cr == self.hover_req_row and self.wins[ai].cc == self.hover_req_col

    def hover_arrived(mut self, m: RpcMessage):
        self.hover_req_id = -1
        if not self.hover_still_wanted():
            return
        if m.kind == RPC_ERROR:
            if retry_later(m) and self.hover_retries < COMP_MAX_RETRIES:
                self.hover_retries += 1
                self.hover_retry_due = now_ns() + COMP_RETRY_MS * 1000000
                return
            self.say("Language server: " + m.error_message())
            return
        var text = hover_markdown(m.doc, m.result())
        if text.byte_length() == 0:
            self.say("Nothing is known about this place")
            return
        self.hover_lines = md_render(text, max(20, min(72, self.scr.w - 6)), self.hl)
        if len(self.hover_lines) == 0:
            self.say("Nothing is known about this place")
            return
        self.hover_scroll = 0
        self.mode = M_HOVER
        self.say("")

    # ========================================================== parameter tip
    def sig_command(mut self):
        """Search > Parameter info: show the signature of the call the cursor is in."""
        var ai = self.active_editor()
        if ai < 0:
            return
        self.sig_retries = 0
        if not self.sig_request(ai, "", self.sig_on):
            if self.lsp.state == LSP_READY and not self.lsp.table.signature_help:
                self.say("This language server does not describe parameters")
            else:
                self.say("Start the language server first (" + self.reg.key_label(CM_LSP) + ")")
            return
        self.sig_asked = True

    def sig_request(mut self, ai: Int, trigger: String, again: Bool) -> Bool:
        var path = self.wins[ai].path
        if path.byte_length() == 0 or self.lsp.state != LSP_READY or not self.lsp.table.signature_help:
            return False
        var uri = path_to_uri(path)
        if self.lsp.find_doc(uri) < 0:
            return False
        var now = now_ns()
        self.lsp_send_changes(ai, now, False)
        var id = self.lsp.request_signature(uri, self.wins[ai].cr, self.wins[ai].buf.utf16_col(self.wins[ai].cr, self.wins[ai].cc), trigger, again, now)
        if id < 0:
            return False
        self.sig_req_id = id
        self.sig_path = path
        self.sig_row = self.wins[ai].cr
        self.sig_col = self.wins[ai].cc
        self.sig_version = self.wins[ai].buf.version
        self.sig_retry_due = 0
        return True

    def sig_close(mut self):
        self.sig_on = False
        self.sig_asked = False
        self.sig_req_id = -1
        self.sig_retry_due = 0

    def sig_active(self) -> Bool:
        """A tip is showing or on its way."""
        return self.sig_on or self.sig_req_id >= 0 or self.sig_retry_due > 0

    def maybe_trigger_signature(mut self, ch: Int):
        """After a character was typed in the editor: "(" and "," (whatever the server
        names) bring up the parameter tip."""
        if self.lsp.state != LSP_READY or len(self.lsp.table.signature_triggers) == 0:
            return
        var ai = self.active_editor()
        if ai < 0 or self.wins[ai].has_multi():
            return
        var one = List[Int]()
        one.append(ch)
        var s = to_str(one)
        if not (s in self.lsp.table.signature_triggers):
            return
        self.sig_retries = 0
        self.sig_asked = False
        _ = self.sig_request(ai, s, self.sig_on)

    def sig_follow(mut self):
        """After every key and click: while a tip is showing (or on its way) and the
        cursor or the text moved, ask again - the server says which parameter is now
        being typed, or that the cursor has left the call."""
        if not self.sig_active():
            return
        var ai = self.active_editor()
        if ai < 0 or (self.mode != M_NORMAL and self.mode != M_COMPLETE) or self.wins[ai].path != self.sig_path or self.wins[ai].has_multi():
            self.sig_close()
            return
        if self.wins[ai].cr == self.sig_row and self.wins[ai].cc == self.sig_col and self.wins[ai].buf.version == self.sig_version:
            return
        self.sig_retries = 0
        if not self.sig_request(ai, "", self.sig_on):
            self.sig_close()

    def sig_arrived(mut self, m: RpcMessage):
        self.sig_req_id = -1
        var asked = self.sig_asked
        if m.kind == RPC_ERROR:
            if retry_later(m) and self.sig_retries < COMP_MAX_RETRIES:
                self.sig_retries += 1
                self.sig_retry_due = now_ns() + COMP_RETRY_MS * 1000000
                return
            self.sig_close()
            if asked:
                self.say("Language server: " + m.error_message())
            return
        var info = parse_signature(m.doc, m.result())
        if not info.ok:
            self.sig_close()
            if asked:
                self.say("The cursor is not inside a call")
            return
        self.sigtip = info^
        self.sig_on = True
        self.sig_asked = False

    def hover_page(self) -> Int:
        """Lines of the hover window that fit on the screen."""
        return max(3, min(14, self.scr.h - 6))

    def hover_key(mut self, k: Int) -> Bool:
        """Keys while a hover window is open. True if the key was used up; any other key
        closes the window and then does what it normally does."""
        var page = self.hover_page()
        var most = max(0, len(self.hover_lines) - page)
        if k == KEY_UP:
            self.hover_scroll = max(0, self.hover_scroll - 1)
            return True
        if k == KEY_DOWN:
            self.hover_scroll = min(most, self.hover_scroll + 1)
            return True
        if k == KEY_PGUP:
            self.hover_scroll = max(0, self.hover_scroll - page)
            return True
        if k == KEY_PGDN:
            self.hover_scroll = min(most, self.hover_scroll + page)
            return True
        self.mode = M_NORMAL
        return k == KEY_ESC or k == KEY_ENTER

    def complete_key(mut self, k: Int) -> Bool:
        var ai = self.active_editor()
        if ai < 0:
            self.mode = M_NORMAL
            return False
        var n = len(self.comp_items)
        if k == KEY_UP:
            self.comp_sel = (self.comp_sel - 1 + n) % n
            self.comp_want_details()
            return True
        if k == KEY_DOWN:
            self.comp_sel = (self.comp_sel + 1) % n
            self.comp_want_details()
            return True
        if k == KEY_PGUP:
            self.comp_sel = max(0, self.comp_sel - 8)
            self.comp_want_details()
            return True
        if k == KEY_PGDN:
            self.comp_sel = min(n - 1, self.comp_sel + 8)
            self.comp_want_details()
            return True
        if k == KEY_ESC:
            self.mode = M_NORMAL
            self.comp_srv_have = False
            return True
        if k == KEY_ENTER or k == KEY_TAB:
            self.comp_accept(ai)
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
