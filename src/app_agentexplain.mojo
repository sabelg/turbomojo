"""Help > Ask agent about this error / this code: the agent panel gets a grounded
prompt (src/agentexplain.mojo) - the code with line numbers, the message, TurboMojo's
explanation of it, and the downloaded documentation of the names involved - and is
asked to answer from it and name the pages. The chat shows a one-line request, not
the whole prompt. When the answer is done, the imports in its code are built with
the installed Mojo and the panel says which ones do not exist.
"""
from std.collections import List
from appstate import *
from util import *
from window import WK_EDITOR, WK_MESSAGE
from agentexplain import *
from errhelp import explain_for, err_body
from docpane import md_section
from doclib import path_markdown, has_legacy_mojo_code
from outline import scan_outline, scope_path
from agentchat import CE_AGENT, CE_USER
from acp import AS_READY, AS_FAILED, AS_STOPPED
from app_agent import *
from app_explain import *
from app_docpane import *
from app_docs import *

comptime EXPLAIN_AROUND = 6         # lines of code shown before and after an error's line
comptime EXPLAIN_CODE_MAX = 80      # the most lines of code sent


__extension App:
    def explain_excerpts(mut self, text: String) -> List[String]:
        """The documentation of the standard library names `text` uses (the quoted
        ones first), at most EXCERPTS_MAX pages; pages with removed pre-1.2 syntax
        are only used as a last resort."""
        var out = List[String]()
        var legacy = List[String]()
        self.docs_index_ready()
        if not self.doc_index.built:
            return out^
        var pages = List[Int]()
        var tried = 0
        for name in names_in(text):
            if len(out) >= EXCERPTS_MAX or tried >= 30:
                break
            tried += 1
            var e = self.docpane_api_entry(name)
            if e < 0:
                continue
            ref ent = self.doc_index.entries[e]
            if ent.page in pages:
                continue
            var sec = md_section(path_markdown(self.doc_lib.pages[ent.page].path), ent.text, ent.nth)
            if sec.byte_length() == 0:
                continue
            pages.append(ent.page)
            var exc = doc_excerpt(self.doc_lib.pages[ent.page].title + " - " + ent.text, sec)
            if has_legacy_mojo_code(sec):
                legacy.append(exc)
            else:
                out.append(exc)
        for exc in legacy:
            if len(out) >= EXCERPTS_MAX:
                break
            out.append(exc)
        return out^

    def code_lines(self, ei: Int, first: Int, last: Int) -> List[String]:
        var out = List[String]()
        for r in range(max(0, first), min(self.wins[ei].buf.count(), last + 1)):
            out.append(to_str(self.wins[ei].buf.line(r)))
        return out^

    def rel_path(self, path: String) -> String:
        var root = self.symidx_root()
        return String(path[byte=root.byte_length() + 1:]) if path.startswith(root + "/") else path

    def agent_explain_error(mut self) raises:
        """The problem on the Problems page's row, or on the editor's line."""
        var message: String
        var path = String("")
        var line = 0
        var row = self.explain_problems_row()
        if row.byte_length() > 0:
            var t = self.top()
            var best = -1
            for e in self.errs:
                if e.msg_line <= self.wins[t].cr and e.msg_line > best:
                    best = e.msg_line
                    path = e.path
                    line = e.row
            var k = row.find(" error: ")
            if k < 0:
                k = row.find(" warning: ")
            message = String(String(row[byte=row.find(": ", k) + 2:]).strip()) if k >= 0 else String(row.strip())
        else:
            var ms = self.explain_cursor_problems()
            var ai = self.active_editor()
            if len(ms) == 0 or ai < 0:
                self.say("Put the cursor on a line with a problem (or on a row of the Problems page) first")
                return
            message = ms[0]
            path = self.wins[ai].path
            line = self.wins[ai].cr + 1
        var ei = self.find_editor(path)
        var code = String("")
        if ei >= 0:
            code = numbered(self.code_lines(ei, line - 1 - EXPLAIN_AROUND, line - 1 + EXPLAIN_AROUND), max(1, line - EXPLAIN_AROUND))
        elif path_exists(path):
            var all = read_text(path).split("\n")
            var lines = List[String]()
            for r in range(max(0, line - 1 - EXPLAIN_AROUND), min(len(all), line + EXPLAIN_AROUND)):
                lines.append(String(all[r]))
            code = numbered(lines, max(1, line - EXPLAIN_AROUND))
        var page = explain_for(message)
        var explanation = err_body(page) if page >= 0 else String("")
        var excerpts = self.explain_excerpts(message + "\n" + code)
        var place = self.rel_path(path) + ":" + String(line)
        var full = explain_error_prompt(message, place, code, explanation, excerpts)
        self.agent_ask("Explain this error: " + place + ": " + message + "  [with " + String(len(excerpts) + (1 if page >= 0 else 0)) + " page(s) of local help]", full)

    def agent_explain_code(mut self) raises:
        """The selection, or else the function (or struct) the cursor is in."""
        var ai = self.active_editor()
        if ai < 0:
            self.say("Put the cursor in a file first")
            return
        var first: Int
        var last: Int
        if self.wins[ai].has_sel():
            var s = self.wins[ai].sel_range()
            first = s.r1
            last = s.r2 if s.c2 > 0 or s.r2 == s.r1 else s.r2 - 1
        else:
            var items = scan_outline(self.wins[ai].buf)
            var p = scope_path(items, self.wins[ai].cr)
            if len(p) > 0:
                first = items[p[len(p) - 1]].row
                last = first
                var ind = self.wins[ai].indent_of(first)
                # to the next line as little indented as the header (or the end)
                for r in range(first + 1, self.wins[ai].buf.count()):
                    var l = to_str(self.wins[ai].buf.line(r))
                    if String(l.strip()).byte_length() == 0:
                        continue
                    if self.wins[ai].indent_of(r) <= ind:
                        break
                    last = r
            else:
                first = max(0, self.wins[ai].cr - 10)
                last = min(self.wins[ai].buf.count() - 1, self.wins[ai].cr + 10)
        last = min(last, first + EXPLAIN_CODE_MAX - 1)
        var code = numbered(self.code_lines(ai, first, last), first + 1)
        var excerpts = self.explain_excerpts(code)
        var place = self.rel_path(self.wins[ai].path if self.wins[ai].path.byte_length() > 0 else self.wins[ai].title) + ":" + String(first + 1) + "-" + String(last + 1)
        self.agent_ask("Explain this code: " + place + "  [with " + String(len(excerpts)) + " page(s) of local help]", explain_code_prompt(place, code, excerpts))

    def agent_ask(mut self, shown: String, full: String) raises:
        """Send `full` to the agent; the chat shows `shown`."""
        if self.agent_index() < 0:
            self.agent_toggle()                 # (starts the agent if one is set up)
        else:
            self.focus(self.agent_index())
        if self.agent_command.byte_length() == 0:
            return                              # (the panel says how to set one up)
        if self.agent.busy():
            self.say("The agent is still working (Esc stops it)")
            return
        if self.agent.state == AS_FAILED or self.agent.state == AS_STOPPED:
            self.exec(CM_AGENT_START)
            if not self.agent.active():
                return                          # (folder trust was not given)
        self.chat.user(shown)
        var blocks = self.agent_blocks(full)
        if self.agent.state == AS_READY:
            _ = self.agent.prompt_blocks(blocks, now_ns())
        else:
            self.agent_pending = blocks         # sent once the session is open
        self.agent_explaining = True
        self.agent_scroll = 0

    def agent_check_answer(mut self):
        """After an agent answer: build any Mojo imports in its code blocks with the
        installed Mojo compiler so hallucinated 0.x/24.x imports are caught immediately."""
        self.agent_explaining = False
        var text = String("")
        for k in range(len(self.chat.entries) - 1, -1, -1):
            if self.chat.entries[k].kind == CE_AGENT:
                text = self.chat.entries[k].text
                break
            if self.chat.entries[k].kind == CE_USER:    # (the request: no answer after it)
                break
        var imports = answer_imports(text)
        if len(imports) == 0:
            return
        var dir = state_dir() + "/import-check"
        _ = run_system("mkdir -p " + shell_quote(dir))
        if not write_file(dir + "/check.mojo", str_bytes(import_check_program(imports))):
            return
        var limit = String("timeout 30 ") if which("timeout").byte_length() > 0 else String("")
        var r = run_capture("cd " + shell_quote(dir) + " && " + limit + self.compiler_cmd() + " build check.mojo -o check 2>&1")
        if r.status == 0:
            self.chat.note("✓ The answer's imports build with the installed Mojo: " + ", ".join(imports))
            return
        var bad = failed_import_lines(bytes_to_str(r.out), "check.mojo")
        var said = False
        for n in bad:
            if n >= 1 and n <= len(imports):
                self.chat.note("✗ Not in the installed Mojo: `" + imports[n - 1] + "` does not build")
                said = True
        if not said:
            self.chat.note("The answer's imports could not be checked (the check program did not build)")

    def agent_send_problems(mut self) raises:
        """Send all current LSP, build, and test diagnostics (with code snippets and local
        Mojo documentation excerpts) to the coding agent."""
        var probs = self.problems_collect()
        if len(probs) == 0:
            self.say("No diagnostics to send (run F7 or F9 first)")
            return
        var lines = List[String]()
        lines.append("Fix the following Mojo diagnostics in this project:\n")
        var shown_files = List[String]()
        var combined = String("")
        var limit = min(15, len(probs))
        for k in range(limit):
            ref p = probs[k]
            var sev = String("error") if p.severity == 1 else (String("warning") if p.severity == 2 else String("note"))
            var rel = self.rel_path(p.path) if p.path.byte_length() > 0 else String("<project>")
            lines.append("- `" + rel + ":" + String(max(1, p.line)) + ":" + String(max(1, p.col)) + "` [" + sev + "]: " + p.message)
            for m in p.more:
                lines.append("  " + m)
            combined += p.message + "\n"
            if p.path.byte_length() > 0 and len(shown_files) < 4 and p.path not in shown_files:
                shown_files.append(p.path)
                var ei = self.find_editor(p.path)
                var snippet = String("")
                var ln = max(1, p.line)
                if ei >= 0:
                    snippet = numbered(self.code_lines(ei, ln - 1 - EXPLAIN_AROUND, ln - 1 + EXPLAIN_AROUND), max(1, ln - EXPLAIN_AROUND))
                elif path_exists(p.path):
                    var all = read_text(p.path).split("\n")
                    var sl = List[String]()
                    for r in range(max(0, ln - 1 - EXPLAIN_AROUND), min(len(all), ln + EXPLAIN_AROUND)):
                        sl.append(String(all[r]))
                    snippet = numbered(sl, max(1, ln - EXPLAIN_AROUND))
                if snippet.byte_length() > 0:
                    lines.append("\n### Context: `" + rel + "`\n```mojo\n" + snippet + "\n```\n")
                    combined += snippet + "\n"
        if len(probs) > limit:
            lines.append("\n(...and " + String(len(probs) - limit) + " more diagnostic(s))")
        var excerpts = self.explain_excerpts(combined)
        if len(excerpts) > 0:
            lines.append("\n## Local Mojo 1.2 Documentation Excerpts")
            for ex in excerpts:
                lines.append(ex)
        self.agent_ask("Send diagnostics to agent: " + String(len(probs)) + " problem(s)", "\n".join(lines))
