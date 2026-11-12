"""The bottom panel's Problems page, for every source: what the language server
reports, the errors and warnings of the last build, and the tests that failed. Keys on
the page: E, W, N show or hide errors, warnings and notes; F only the current file's;
/ a text the rows must contain; C everything again. On the Message page / and C filter
the output's lines the same way.
"""
from std.collections import List
from appstate import *
from util import *
from dialog import *
from commands import CM_LSP
from window import WK_EDITOR, WK_MESSAGE
from lsp import uri_to_path, utf16_to_col
from problems import *
from testexp import TS_FAIL, def_line
from app_jobs import *
from app_layout import *


__extension App:
    def problems_collect(self) -> List[Problem]:
        var out = List[Problem]()
        for k in range(len(self.lsp.diags)):
            var path = uri_to_path(self.lsp.diags[k].uri)
            var wi = self.find_editor(path)
            for d in self.lsp.diags[k].items:
                var col = d.ch + 1
                if wi >= 0 and d.line >= 0 and d.line < self.wins[wi].buf.count():
                    col = utf16_to_col(self.wins[wi].buf.line(d.line), d.ch) + 1
                var lines = d.message.split("\n")
                var p = Problem(PS_SERVER, d.severity if d.severity >= 1 and d.severity <= 4 else SEV_ERROR, path, d.line + 1, col, String(lines[0]) if len(lines) > 0 else String(""))
                for j in range(1, len(lines)):
                    p.more.append(String(lines[j]))
                out.append(p^)
        # the other language servers' problems ([lsp.<name>])
        for x in range(len(self.lsp_extra)):
            ref c = self.lsp_extra[x].client
            for k in range(len(c.diags)):
                var path = uri_to_path(c.diags[k].uri)
                for d in c.diags[k].items:
                    var lines = d.message.split("\n")
                    var p = Problem(PS_SERVER, d.severity if d.severity >= 1 and d.severity <= 4 else SEV_ERROR, path, d.line + 1, d.ch + 1, String(lines[0]) if len(lines) > 0 else String(""))
                    for j in range(1, len(lines)):
                        p.more.append(String(lines[j]))
                    out.append(p^)
        for p in self.prob_build:
            out.append(p.copy())
        for f in self.test_files:
            for t in f.tests:
                if t.state != TS_FAIL:
                    continue
                var path = f.path
                var line = 0
                var col = 1
                # (see tests_go: a build cache can name another folder with this file)
                if t.path.byte_length() > 0 and t.line > 0 and (basename(t.path) == basename(f.path) or path_exists(t.path)):
                    if basename(t.path) != basename(f.path):
                        path = t.path
                    line = t.line
                    col = max(1, t.col)
                else:
                    line = def_line(read_text(f.path), t.name)
                var why = String("")
                if len(t.message) > 0:
                    why = String(t.message[0].strip())
                    var m = why.find(".mojo:")
                    if why.startswith("At ") and m > 0:
                        var after = why.find(": ", m + 6)
                        if after > 0:
                            var rest = String(why[byte=after + 2:])
                            why = rest
                out.append(Problem(PS_TEST, SEV_ERROR, path, line, col, t.name + " failed" + ((": " + why) if why.byte_length() > 0 else String(""))))
        return out^

    def problems_current(self) -> String:
        var te = self.top_editor()
        return self.wins[te].path if te >= 0 else String("")

    def problems_show(mut self, front: Bool):
        """Make the Problems page again. With `front` (new problems from the server) it
        comes to the front unless another page was chosen meanwhile; otherwise it is
        brought up to date where it is."""
        if front and not (self.panel_pinned and self.msg_page != PG_PROBLEMS and self.msg_index() >= 0):
            self.panel_page(PG_PROBLEMS)
        var probs = self.problems_collect()
        var v = view_problems(probs, self.prob_filter, self.problems_current())
        var lines = List[String]()
        lines.append("Problems reported by the language server, the last build and the tests")
        lines.append(self.prob_filter.describe())
        var errs = List[ErrLoc]()
        var last = -1
        for r in range(len(v.rows)):
            if v.of[r] != last:
                last = v.of[r]
                ref p = probs[v.of[r]]
                errs.append(ErrLoc(p.path, max(1, p.line), p.col, len(lines)))
            lines.append(v.rows[r])
        var total = v.errors + v.warnings + v.infos
        var hidden = total - v.shown
        var footer = String("No problems found")
        if v.shown > 0:
            footer = String(v.shown) + " problem(s)" + (" in " + String(v.files) + " files" if v.files > 1 else "")
            if hidden > 0:
                footer += ", " + String(hidden) + " not shown (C shows all)"
        elif total > 0:
            footer = "No problems shown: " + String(hidden) + " hidden by the filter (C shows all)"
        elif not self.lsp.conn.proc.running:
            footer = "No problems reported (" + self.reg.key_label(CM_LSP) + " starts the language server)"
        if self.lsp_last_latency_ms >= 0 and len(self.lsp.diags) > 0:
            footer += "  (server answered in " + String(self.lsp_last_latency_ms) + " ms)"
        lines.append(footer)
        for p in probs:
            if p.message.find("'std' is required") >= 0:
                lines.append("The Mojo standard library was not found: start TurboMojo with `pixi run`.")
                break
        var text = List[Int]()
        for k in range(len(lines)):
            if k > 0:
                text.append(10)
            for c in decode(lines[k]):
                text.append(c)
        var mi = self.msg_index()
        if self.msg_page == PG_PROBLEMS and mi >= 0:
            var keep = self.wins[mi].cr
            self.wins[mi].buf.load(text)
            self.wins[mi].buf.modified = False
            self.wins[mi].cr = max(0, min(keep, self.wins[mi].buf.count() - 1))
            self.errs = errs^
            self.err_idx = -1
            self.errs_from_search = False
        else:
            # behind another page: kept for when it is turned to
            self.pg_text[PG_PROBLEMS] = text^
            self.pg_errs[PG_PROBLEMS] = errs^
            self.pg_idx[PG_PROBLEMS] = -1
            self.pg_search[PG_PROBLEMS] = False

    # ------------------------------------------------------------------ keys
    def panel_filter_key(mut self, k: Int) -> Bool:
        """Filter keys of the Problems and Message pages (False: not one)."""
        if self.msg_page == PG_PROBLEMS:
            if k == 101 or k == 69:             # E
                self.prob_filter.errors = not self.prob_filter.errors
            elif k == 119 or k == 87:           # W
                self.prob_filter.warnings = not self.prob_filter.warnings
            elif k == 110 or k == 78:           # N
                self.prob_filter.infos = not self.prob_filter.infos
            elif k == 102 or k == 70:           # F
                self.prob_filter.this_file = not self.prob_filter.this_file
            elif k == 99 or k == 67:            # C
                self.prob_filter = ProblemFilter()
            elif k == 47:                       # /
                var now = self.prob_filter.text
                self.panel_filter_dialog(now)
            else:
                return False
            self.problems_show(False)
            return True
        if self.msg_page == PG_MESSAGE:
            if k == 47:
                var now = self.out_filter
                self.panel_filter_dialog(now)
                return True
            if (k == 99 or k == 67) and self.out_filtered:
                self.output_filter("")
                return True
        return False

    def panel_filter_dialog(mut self, now: String):
        var d = Dialog(D_PANEL_FILTER, "Filter", min(60, self.scr.w - 4), 9)
        d.lines.append("Show only the lines containing (any case; empty: all):")
        d.fields.append(Field("~T~ext", now))
        d.fields[0].fresh = True
        d.buttons.append("~O~K")
        d.buttons.append("Cancel")
        self.show(d^)

    def panel_filter_set(mut self, text: String):
        if self.msg_page == PG_PROBLEMS:
            self.prob_filter.text = text
            self.problems_show(False)
        elif self.msg_page == PG_MESSAGE:
            self.output_filter(text)

    # ---------------------------------------------------------- Message page
    def output_filter(mut self, text: String):
        """Show the Message page's lines that contain `text` (its first line, the
        header, always); '' shows everything again. Places to jump to follow."""
        var mi = self.msg_index()
        if mi < 0:
            return
        if not self.out_filtered:
            self.out_full.clear()
            for r in range(self.wins[mi].buf.count()):
                self.out_full.append(to_str(self.wins[mi].buf.line(r)))
        var shown = List[String]()
        if text.byte_length() == 0:
            shown = self.out_full.copy()
            self.out_filtered = False
            self.out_filter = ""
        else:
            var keep = filter_lines(self.out_full, text)
            if len(self.out_full) > 0:
                shown.append(self.out_full[0])
            for k in keep:
                if k > 0:
                    shown.append(self.out_full[k])
            shown.append("(" + String(len(shown) - 1) + " of " + String(max(0, len(self.out_full) - 1)) + " lines contain \"" + text + "\"; C shows all)")
            self.out_filtered = True
            self.out_filter = text
        var t = List[Int]()
        self.errs.clear()
        self.err_idx = -1
        for r in range(len(shown)):
            if r > 0:
                t.append(10)
            var cps = decode(shown[r])
            if (str_contains(shown[r], "error:") and not shown[r].startswith("mojo: ")) or str_contains(shown[r], "warning:"):
                var loc = self.parse_loc(cps)
                if loc.row > 0:
                    loc.msg_line = r
                    loc.path = abs_path(self.msg_base if self.msg_base.byte_length() > 0 else String(self.cwd), loc.path)
                    self.errs.append(loc^)
            for c in cps:
                t.append(c)
        self.wins[mi].buf.load(t)
        self.wins[mi].buf.modified = False
        self.wins[mi].cr = 0
        self.wins[mi].top = 0
        self.wins[mi].follow = True
