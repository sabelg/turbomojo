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
from responsive import explorer_width, outline_width, docpane_width
from std.collections import List
from appstate import *
from util import *
from window import Window, WK_EDITOR, WK_DOCPANE, WK_OUTLINE
from term import KEY_ESC, KEY_ENTER
from markdown import md_render_rich, MdLine
from docs import docs_for
from doclib import path_markdown, find_help, parse_query, cut, IK_API
from docpane import md_section, md_mojo_blocks, infer_receiver_owner
from pydocs import dotted_at
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
        var w = docpane_width(self.scr.w)
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
        self.docpane_md = md
        var w = max(16, self.wins[pi].w - 4)
        var links = List[String]()
        self.docpane_lines = md_render_rich(md, w, self.hl, links, True)
        self.docpane_lines_w = w
        var text = List[Int]()
        for k in range(len(self.docpane_lines)):
            if k > 0:
                text.append(10)
            for c in self.docpane_lines[k].cps:
                text.append(c)
        self.wins[pi].title = title
        self.wins[pi].buf.load(text)
        self.wins[pi].buf.modified = False
        self.wins[pi].cr = 0
        self.wins[pi].top = 0

    def docpane_draw(mut self, pi: Int):
        """Draw the docs pane's Markdown with full rich styling over the window interior."""
        if pi < 0 or pi >= len(self.wins) or self.wins[pi].w < 6 or self.wins[pi].h < 4:
            return
        var w = max(16, self.wins[pi].w - 4)
        if w != self.docpane_lines_w and self.docpane_md.byte_length() > 0:
            var links = List[String]()
            self.docpane_lines = md_render_rich(self.docpane_md, w, self.hl, links, True)
            self.docpane_lines_w = w
            var text = List[Int]()
            for k in range(len(self.docpane_lines)):
                if k > 0:
                    text.append(10)
                for c in self.docpane_lines[k].cps:
                    text.append(c)
            var keep_cr = self.wins[pi].cr
            var keep_top = self.wins[pi].top
            self.wins[pi].buf.load(text)
            self.wins[pi].buf.modified = False
            self.wins[pi].cr = max(0, min(keep_cr, self.wins[pi].buf.count() - 1))
            self.wins[pi].top = max(0, min(keep_top, self.wins[pi].buf.count() - 1))
        var lines = self.docpane_lines.copy()
        self.draw_md(self.wins[pi].x + 1, self.wins[pi].y + 1, max(2, self.wins[pi].w - 2), max(1, self.wins[pi].h - 2), lines, self.wins[pi].top)

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
        var chain = dotted_at(self.wins[ai].buf.line(self.wins[ai].cr), self.wins[ai].cc)
        var key = self.wins[ai].path + "\n" + name + "\n" + chain
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

    def docpane_api_entry(self, name: String, owner_hint: String = "") -> Int:
        """The standard library declaration called `name` (preferring `owner_hint` when
        given, or a struct, trait or function before a method of that name), or -1."""
        if not self.doc_index.built:
            return -1
        var low = name.lower()
        var olow = owner_hint.lower()
        var best = -1
        var top_level = -1
        for f in find_help(self.doc_index, self.doc_lib, parse_query("@" + name), 40):
            ref e = self.doc_index.entries[f.entry]
            var last = e.low
            var sp = last.rfind(" ")
            if sp >= 0:
                last = cut(last, sp + 1, -1)
            if last == low:
                if olow.byte_length() > 0 and e.owner.lower() == olow:
                    return f.entry
                if e.owner.byte_length() == 0 and top_level < 0:
                    top_level = f.entry
                if best < 0:
                    best = f.entry
        if top_level >= 0:
            return top_level
        return best

    def docpane_lookup(mut self, name: String, asked: Bool):
        """Put the documentation of `name` into the pane. `asked` (Ctrl-F1): look
        everywhere, running `mojo doc` if needed."""
        self.docpane_name = name
        self.docpane_entry = -1
        var owner_hint = String("")
        var ai_cur = self.active_editor()
        if ai_cur >= 0:
            var chain = dotted_at(self.wins[ai_cur].buf.line(self.wins[ai_cur].cr), self.wins[ai_cur].cc)
            if chain.find(".") >= 0:
                owner_hint = infer_receiver_owner(to_str(self.wins[ai_cur].buf.all_text()), self.wins[ai_cur].cr, chain)
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
            var e = self.docpane_api_entry(name, owner_hint)
            if e >= 0:
                ref ent = self.doc_index.entries[e]
                md = md_section(path_markdown(self.doc_lib.pages[ent.page].path), ent.text, ent.nth)
                if md.byte_length() > 0:
                    self.docpane_entry = e
                    md += "\n\n*" + self.doc_lib.pages[ent.page].title + "* - **Enter** opens the page, **C** copies code, **T** tries snippet"
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

    def docpane_snippet(self) -> String:
        """Code example from the docs pane (preferring a body example over the signature fence)."""
        var blocks = md_mojo_blocks(self.docpane_md)
        if len(blocks) >= 2:
            return blocks[1]
        if len(blocks) == 1:
            return blocks[0]
        return ""

    def docpane_key_event(mut self, k: Int) raises -> Bool:
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
        if k == 99 or k == 67:                  # C: copy code block
            var code = self.docpane_snippet()
            if code.byte_length() == 0:
                self.say("No code block in the docs pane")
            else:
                var cps = decode(code)
                self.clipboard = cps.copy()
                self.osc52(cps)
                self.say("Copied code snippet to the clipboard")
            return True
        if k == 116 or k == 84:                 # T: try code block in scratch buffer
            var code = self.docpane_snippet()
            if code.byte_length() == 0:
                self.say("No code block in the docs pane")
            else:
                self.open_scratch_snippet(code, self.docpane_name if self.docpane_name.byte_length() > 0 else String("snippet"))
            return True
        return False
