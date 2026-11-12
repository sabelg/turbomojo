"""Help > Docs pane: the documentation of the name at the cursor in a window at the
right edge, beside the code, kept up to date as the cursor moves - looked up when the
cursor has rested on a name for a moment, never while typing.

Where the text comes from, first found first: the doc comments of the project's
declarations (only what `mojo doc` has already said about the file as it is on disk:
the pane never starts a compile by itself), the downloaded standard library reference
(the section of the declaration), then the language server's description. Ctrl-F1
and Describe symbol put their answers here while the pane is open, looking further
(Ctrl-F1 runs `mojo doc` if needed). Enter in the pane opens the page in the full
documentation viewer, for study; Esc goes back to the code.
"""
from std.collections import List
from appstate import *
from util import *
from window import Window, WK_EDITOR, WK_DOCPANE, WK_OUTLINE
from term import KEY_ESC, KEY_ENTER
from markdown import md_render
from docs import docs_for
from doclib import path_markdown, find_help, parse_query, cut, IK_API
from docpane import md_section
from watch import file_sig
from lsp import LSP_READY, path_to_uri
from app_outline import *
from app_docs import *
from app_nav import *
from app_pickers import *

comptime DOCPANE_IDLE_MS = 350      # the cursor rests this long on a name before it is looked up


__extension App:
    def docpane_toggle(mut self):
        """Help > Docs pane: open it at the right edge (left of the outline, if that is
        open), the editors making room; or close it, and they get the room back."""
        var pi = self.docpane_index()
        if pi >= 0:
            var x = self.wins[pi].x
            var right = x + self.wins[pi].w
            _ = self.wins.pop(pi)
            for i in range(len(self.wins)):
                if self.wins[i].kind == WK_EDITOR and self.wins[i].x + self.wins[i].w == x:
                    self.wins[i].w = right - self.wins[i].x
            var te = self.top_editor()
            if te >= 0:
                self.focus(te)
            return
        var right = self.scr.w
        var oi = self.outline_index()
        if oi >= 0:
            right = self.wins[oi].x
        var w = max(30, min(56, self.scr.w // 3))
        var x = right - w
        if x < 20:
            self.say("The screen is too narrow for the docs pane")
            return
        var h = self.desk_h()
        var mi = self.msg_index()
        if mi >= 0:
            h = max(6, self.wins[mi].y - 1)
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].x + self.wins[i].w > x and x - self.wins[i].x >= 20:
                self.wins[i].w = x - self.wins[i].x
        var win = Window(WK_DOCPANE, "Docs", "docs:", x, 1, w, h, 0)
        self.wins.insert(0, win^)
        self.docpane_key = ""
        self.docpane_entry = -1
        self.docpane_show("Docs", "Rest the cursor on a name: its documentation appears here.\n\n**Ctrl-F1** looks further, **Enter** here opens the page in the documentation viewer, **Esc** goes back to the code.")
        self.docs_index_ready()             # (once: the standard library's names)
        self.docpane_due = now_ns()         # the name at the cursor now

    def docpane_show(mut self, title: String, md: String):
        var pi = self.docpane_index()
        if pi < 0:
            return
        var lines = md_render(md, max(16, self.wins[pi].w - 4), self.hl)
        var text = List[Int]()
        for k in range(len(lines)):
            if k > 0:
                text.append(10)
            for c in lines[k].cps:
                text.append(c)
        self.wins[pi].title = title
        self.wins[pi].buf.load(text)
        self.wins[pi].buf.modified = False
        self.wins[pi].cr = 0
        self.wins[pi].top = 0

    def docpane_tick(mut self, now: Int):
        """After each round of events: a new name under the cursor is looked up once
        the cursor has rested on it."""
        if self.docpane_index() < 0:
            self.docpane_due = 0
            return
        var ai = self.active_editor()
        if ai < 0 or self.mode != M_NORMAL:
            return
        var name = self.word_under(ai)
        if name.byte_length() == 0 or (decode(name)[0] >= 48 and decode(name)[0] <= 57):
            return                          # (what the pane shows stays)
        var key = self.wins[ai].path + "\n" + name
        if key != self.docpane_key:
            self.docpane_key = key
            self.docpane_due = now + DOCPANE_IDLE_MS * 1000000
            return
        if self.docpane_due > 0 and now >= self.docpane_due:
            self.docpane_due = 0
            self.docpane_lookup(name, False)

    def docs_known(self, path: String) -> Bool:
        """`mojo doc` has been asked about this file as it is on disk."""
        var sig = file_sig(path)
        var stamp = sig.mtime_s * 1000000000 + sig.mtime_ns
        for k in range(len(self.doc_files)):
            if self.doc_files[k] == path:
                return self.doc_sizes[k] == sig.size and self.doc_times[k] == stamp
        return False

    def docpane_api_entry(self, name: String) -> Int:
        """The standard library declaration called `name` (a struct, trait or function
        before a method of that name), or -1."""
        if not self.doc_index.built:
            return -1
        var low = name.lower()
        var best = -1
        for f in find_help(self.doc_index, self.doc_lib, parse_query("@" + name), 40):
            ref e = self.doc_index.entries[f.entry]
            var last = e.low
            var sp = last.rfind(" ")
            if sp >= 0:
                last = cut(last, sp + 1, -1)
            if last == low:
                if e.owner.byte_length() == 0:
                    return f.entry
                if best < 0:
                    best = f.entry
        return best

    def docpane_lookup(mut self, name: String, asked: Bool):
        """Put the documentation of `name` into the pane. `asked` (Ctrl-F1): look
        everywhere, running `mojo doc` if needed."""
        self.docpane_name = name
        self.docpane_entry = -1
        var md = String("")
        var n = 0
        for f in self.docs_files_for(name, asked):
            if n >= DOCS_MAX_FILES:
                break
            n += 1
            if not asked and not self.docs_known(f):
                continue
            var part = docs_for(self.docs_of_file(f), name)
            if part.byte_length() > 0:
                md += ("\n\n---\n\n" if md.byte_length() > 0 else "") + part
        if md.byte_length() == 0:
            if asked:
                self.docs_index_ready()
            var e = self.docpane_api_entry(name)
            if e >= 0:
                ref ent = self.doc_index.entries[e]
                md = md_section(path_markdown(self.doc_lib.pages[ent.page].path), ent.text, ent.nth)
                if md.byte_length() > 0:
                    self.docpane_entry = e
                    md += "\n\n*" + self.doc_lib.pages[ent.page].title + "* - **Enter** opens the page"
        if md.byte_length() > 0:
            self.docpane_show("Docs: " + name, md)
            return
        var ai = self.active_editor()
        if ai >= 0 and self.hover_request(ai):
            self.hover_pane = True
            self.docpane_show("Docs: " + name, "Asking the language server about `" + name + "`...")
            return
        self.docpane_show("Docs: " + name, "Nothing is documented for `" + name + "`" + ("" if asked else " (**Ctrl-F1** looks further)") + ".")

    def docpane_hover(mut self, text: String):
        """The language server's description, for the pane."""
        self.hover_pane = False
        if text.byte_length() == 0:
            self.docpane_show("Docs: " + self.docpane_name, "Nothing is known about `" + self.docpane_name + "`.")
        else:
            self.docpane_show("Docs: " + self.docpane_name, text)

    def docpane_key_event(mut self, k: Int) -> Bool:
        if k == KEY_ESC:
            var te = self.top_editor()
            if te >= 0:
                self.focus(te)
            return True
        if k == KEY_ENTER:
            if self.docpane_entry >= 0:
                self.docs_goto_entry(self.docpane_entry)
            else:
                self.say("This text is not from the documentation viewer's pages")
            return True
        return False
