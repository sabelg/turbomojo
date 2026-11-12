"""The tips of src/tips.mojo in the IDE: the editor's keys and the Find dialog feed
the rules; a tip comes as a notice, so while you type it waits for the pause (P7-12),
and a screen reader hears it then. Each tip is given once (kept in the state folder's
tips-shown); Help > No more tips (or ui.tips = false) stops them for good.
"""
from std.collections import List
from appstate import *
from util import *
from commands import CM_SYMBOL, CM_AGAIN, CM_QUICK
from notify import NL_INFO
from term import KEY_PGUP, KEY_PGDN, KEY_LEFT, KEY_RIGHT, KEY_BACKSPACE
from tips import *
from app_notify import *
from app_jobs import *


__extension App:
    def tips_load(mut self, path: String):
        self.tips_file = path
        self.tips_shown = parse_shown(bytes_to_str(read_file(path))) if path_exists(path) else List[String]()

    def tip_kind_of_key(self, k: Int) -> Int:
        if k == KEY_PGUP or k == KEY_PGDN:
            return TK_PAGE
        if k == KEY_LEFT or k == KEY_RIGHT:
            return TK_LR
        if k == KEY_BACKSPACE:
            return TK_BS
        return TK_OTHER

    def tip_feed(mut self, kind: Int):
        if not self.tips_on:
            return
        var t = self.tip_rules.feed(kind, now_ns())
        if t < 0 or tip_name(t) in self.tips_shown:
            return
        var text = self.tip_text(t)
        if text.byte_length() == 0:
            return                      # (no key for it in this keymap: nothing to tell)
        self.tips_shown.append(tip_name(t))
        if self.tips_file.byte_length() > 0:
            _ = write_file(self.tips_file, str_bytes("\n".join(self.tips_shown) + "\n"))
        self.notify(NL_INFO, "Tip", text + " (Help > No more tips stops these)")

    def tip_text(self, t: Int) -> String:
        if t == TIP_PAGE:
            var k = self.reg.key_label(CM_SYMBOL)
            if k.byte_length() > 0:
                return k + " goes to a function by its name (Go to symbol), without paging"
            return self.reg.key_label(CM_QUICK) + " and @ go to a function by its name, without paging"
        if t == TIP_WORDS:
            return "Ctrl-Left / Ctrl-Right move a word at a time"
        if t == TIP_BACKSPACE:
            return "Ctrl-Backspace deletes the word to the left"
        if t == TIP_AGAIN:
            var k = self.reg.key_label(CM_AGAIN)
            if k.byte_length() == 0:
                return ""
            return k + " finds the next match again, without the Find dialog"
        return ""

    def tips_off(mut self):
        self.tips_on = False
        self.persist_option("ui", "tips", "false")
        self.say("No more tips (ui.tips = false)")
