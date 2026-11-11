"""The editor's services to a coding agent (ACP): reading files through the editor,
proposed writes to accept or reject, and terminals for its commands.

- `fs/read_text_file`: the editor's text when the file is open (unsaved changes
  included), else the file; only files in the project or open in the editor.
- `fs/write_text_file`: never written at once. The change is a proposal shown in the
  diff view ("Proposed: name"); A accepts it (the editor's text is changed as one undo
  step and saved; a new file is created), R rejects it (the agent is told). Several
  proposals wait in turn. Only files in the project.
- `terminal/create`: the command runs only after Y in the agent panel (N refuses); then
  on a pty in the folder asked for, its output kept for the agent (the newest
  `outputByteLimit` bytes) and its last lines shown in the conversation.
  `terminal/output`, `wait_for_exit`, `kill`, `release` as the protocol has them.
"""
from std.collections import List
from appstate import *
from util import *
from window import Window, WK_EDITOR, WK_DIFF
from json import Json, json_parse, json_quote, J_ARR, J_NUM, J_OBJ
from acp import *
from agentchat import *
from agentsvc import *
from gitdiff import Side, side_hunks, unified, DR_OLD, DR_NEW
from app_outline import *
from app_gitdiff import *
from app_files import *
from app_jobs import *

comptime ERR_NOT_FOUND = -32002
comptime ERR_REFUSED = -32000
comptime ERR_PARAMS = -32602


__extension App:
    def agent_path_ok(self, path: String, write: Bool) -> Bool:
        """The agent may use this file: it is in the project (or, for reading, open in
        the editor)."""
        if not path.startswith("/"):
            return False
        var p = normalize_path(path)
        var root = self.symidx_root()
        if p == root or p.startswith(root + "/"):
            return True
        return not write and self.find_editor(p) >= 0

    def agent_file_text(self, path: String) -> Tuple[String, Bool]:
        """(text, exists): the editor's when the file is open there."""
        var ei = self.find_editor(path)
        if ei >= 0:
            return (to_str(self.wins[ei].buf.all_text()), True)
        if path_exists(path) and not is_dir(path):
            return (read_text(path), True)
        return (String(""), False)

    def agent_service(mut self, e: AcpEvent) raises:
        var doc = json_parse(e.text)
        var m = e.kind_name
        if m == "fs/read_text_file":
            var path = normalize_path(doc.str(doc.get(0, "path")))
            if not self.agent_path_ok(path, False):
                self.agent.answer_error(e.request, ERR_REFUSED, "TurboMojo only gives the agent files of the project (or open in the editor): " + path)
                return
            var got = self.agent_file_text(path)
            if not got[1]:
                self.agent.answer_error(e.request, ERR_NOT_FOUND, "no such file: " + path)
                return
            var line = doc.int(doc.get(0, "line"), 0)
            var limit = doc.int(doc.get(0, "limit"), 0)
            var text = got[0]
            if line > 0 or limit > 0:
                var first = max(1, line)
                text = lines_of(text, first, first + limit - 1 if limit > 0 else 1 << 40)
            self.agent.answer(e.request, "{\"content\":" + json_quote(text) + "}")
            return
        if m == "fs/write_text_file":
            var path = normalize_path(doc.str(doc.get(0, "path")))
            if not self.agent_path_ok(path, True):
                self.agent.answer_error(e.request, ERR_REFUSED, "TurboMojo only lets the agent write files of the project: " + path)
                return
            var got = self.agent_file_text(path)
            var new = doc.str(doc.get(0, "content"))
            if got[1] and got[0] == new:
                self.agent.answer(e.request, "{}")          # nothing to change
                return
            self.agent_props.append(Proposal(e.request, path, got[0], new, got[1]))
            self.chat.note("The agent proposes " + ("changes to " if got[1] else "a new file ") + self.agent_rel(path) + ": A accepts, R rejects (in the diff view; Enter in the empty prompt shows it again)")
            if len(self.agent_props) == 1:
                self.agent_show_proposal()
            return
        if m == "terminal/create":
            var cmd = doc.str(doc.get(0, "command"))
            var argv = List[String]()
            var args = doc.get(0, "args")
            var has_args = args >= 0 and doc.kind(args) == J_ARR and doc.size(args) > 0
            if not has_args and cmd.find(" ") > 0:
                argv.append("sh")
                argv.append("-c")
                argv.append(cmd)
            else:
                argv.append(cmd)
                if has_args:
                    for a in doc.children(args):
                        argv.append(doc.str(a))
            # shown as written: `sh -c X` (or bash -c X) as X
            var title = String("")
            if len(argv) == 3 and (argv[0] == "sh" or argv[0] == "bash") and argv[1] == "-c":
                title = argv[2]
            else:
                for k in range(len(argv)):
                    title += (" " if k > 0 else "") + argv[k]
            var cwd = doc.str(doc.get(0, "cwd"))
            if cwd.byte_length() == 0:
                cwd = self.symidx_root()
            var env = List[String]()
            var envs = doc.get(0, "env")
            if envs >= 0 and doc.kind(envs) == J_ARR:
                for en in doc.children(envs):
                    env.append(doc.str(doc.get(en, "name")) + "=" + doc.str(doc.get(en, "value")))
            var limit = doc.int(doc.get(0, "outputByteLimit"), TERM_DEFAULT_LIMIT)
            if cmd.byte_length() == 0:
                self.agent.answer_error(e.request, ERR_PARAMS, "no command")
                return
            self.agent_asks.append(RunAsk(e.request, argv^, cwd, env^, limit, title))
            self.chat.note("The agent wants to run `" + title + "` in " + cwd + ": Y runs it, N refuses")
            var ai = self.agent_index()
            if ai >= 0:
                self.focus(ai)
            return
        var tid = doc.str(doc.get(0, "terminalId"))
        var ti = self.agent_term_index(tid)
        if ti < 0:
            self.agent.answer_error(e.request, ERR_PARAMS, "no terminal " + tid)
            return
        if m == "terminal/output":
            _ = self.agent_terms[ti].pump()
            var r = "{\"output\":" + json_quote(bytes_to_str(self.agent_terms[ti].output)) + ",\"truncated\":" + ("true" if self.agent_terms[ti].truncated else "false")
            if self.agent_terms[ti].done:
                r += ",\"exitStatus\":" + self.agent_terms[ti].exit_json()
            self.agent.answer(e.request, r + "}")
        elif m == "terminal/wait_for_exit":
            if self.agent_terms[ti].done:
                self.agent.answer(e.request, self.agent_terms[ti].exit_json())
            else:
                self.agent_terms[ti].waiters.append(e.request)
        elif m == "terminal/kill":
            self.agent_terms[ti].kill()
            self.agent_term_ended(ti)
            self.agent.answer(e.request, "{}")
        elif m == "terminal/release":
            self.agent_terms[ti].kill()
            self.agent_term_ended(ti)
            _ = self.agent_terms.pop(ti)
            self.agent.answer(e.request, "{}")
        else:
            self.agent.answer_error(e.request, -32601, "TurboMojo does not offer " + m)

    def agent_rel(self, path: String) -> String:
        var root = self.symidx_root()
        return String(path[byte=root.byte_length() + 1:]) if path.startswith(root + "/") else path

    # ------------------------------------------------------------- terminals
    def agent_term_index(self, id: String) -> Int:
        for k in range(len(self.agent_terms)):
            if self.agent_terms[k].id == id:
                return k
        return -1

    def agent_ask_answer(mut self, yes: Bool):
        """Y or N to the first command the agent wants to run."""
        if len(self.agent_asks) == 0:
            return
        var a = self.agent_asks.pop(0)
        if not yes:
            self.agent.answer_error(a.request, ERR_REFUSED, "the user did not allow the command")
            self.chat.note("Refused: `" + a.title + "`")
            return
        self.agent_term_n += 1
        var id = "term_" + String(self.agent_term_n)
        var t = AgentTerm(id, a.title, a.limit)
        if not t.pty.start(a.argv, a.cwd, a.env, 24, 120):
            self.agent.answer_error(a.request, -32603, "the command could not be started")
            self.chat.note("Could not start `" + a.title + "`")
            return
        self.agent_terms.append(t^)
        self.chat.term(id, a.title)
        self.agent.answer(a.request, "{\"terminalId\":" + json_quote(id) + "}")

    def agent_term_ended(mut self, k: Int):
        """Answer those waiting for the end and show how it ended."""
        for w in self.agent_terms[k].waiters:
            self.agent.answer(w, self.agent_terms[k].exit_json())
        self.agent_terms[k].waiters.clear()
        var st = ("exit " + String(self.agent_terms[k].code)) if self.agent_terms[k].signal == 0 else signal_name(self.agent_terms[k].signal)
        self.chat.term_update(self.agent_terms[k].id, st, tail_lines(bytes_to_str(self.agent_terms[k].output), 8))

    def agent_svc_tick(mut self):
        for k in range(len(self.agent_terms)):
            var was_done = self.agent_terms[k].done
            if self.agent_terms[k].pump():
                if self.agent_terms[k].done and not was_done:
                    self.agent_term_ended(k)
                else:
                    self.chat.term_update(self.agent_terms[k].id, "", tail_lines(bytes_to_str(self.agent_terms[k].output), 8))

    def agent_term_fds(self) -> List[Int]:
        var out = List[Int]()
        for t in self.agent_terms:
            if not t.done and t.pty.master >= 0:
                out.append(t.pty.master)
        return out^

    def agent_services_end(mut self):
        """The agent is gone: its commands stop, what it asked is dropped."""
        for k in range(len(self.agent_terms)):
            self.agent_terms[k].kill()
        self.agent_terms.clear()
        self.agent_asks.clear()
        if len(self.agent_props) > 0:
            self.agent_props.clear()
            if self.gd_proposal:
                self.git_diff_close()

    # ------------------------------------------------------------- proposals
    def agent_show_proposal(mut self):
        """The first proposal in the diff view (over the editor's place)."""
        if len(self.agent_props) == 0:
            return
        var di = self.gd_index()
        var te = self.top_editor()
        if di < 0:
            var x = self.wins[te].x if te >= 0 else 0
            var y = self.wins[te].y if te >= 0 else 1
            var w = self.wins[te].w if te >= 0 else self.scr.w
            var h = self.wins[te].h if te >= 0 else self.desk_h()
            var win = Window(WK_DIFF, "Proposed", "proposal:", x, y, w, h, self.free_number())
            self.wins.append(win^)
        else:
            self.focus(di)
        self.gd_proposal = True
        self.gd_path = self.agent_props[0].path
        self.gd_stamp = -1
        var t = self.top()
        self.wins[t].cr = 0
        self.wins[t].top = 0
        self.git_diff_refresh()
        for r in range(len(self.gd_rows)):
            if self.gd_rows[r].kind == DR_OLD or self.gd_rows[r].kind == DR_NEW:
                self.wins[t].cr = r
                self.wins[t].follow = True
                break

    def agent_proposal_answer(mut self, accept: Bool) raises:
        if len(self.agent_props) == 0:
            return
        var p = self.agent_props.pop(0)
        if not accept:
            self.agent.answer_error(p.request, ERR_REFUSED, "the user rejected the change to " + p.path)
            self.chat.note("Rejected the change to " + self.agent_rel(p.path))
        else:
            var ok = True
            if not p.exists:
                _ = run_system("mkdir -p " + shell_quote(dirname(p.path)))
                ok = write_file(p.path, str_bytes(p.new))
            if ok:
                self.open_path(p.path)
                var ei = self.find_editor(p.path)
                if ei >= 0:
                    self.replace_text_min(ei, decode(p.new))
                    ok = self.save_window(ei, NEXT_NONE)
                else:
                    ok = False
            if ok:
                self.agent.answer(p.request, "{}")
                self.chat.note("Accepted the change to " + self.agent_rel(p.path) + " (saved; Undo in the editor takes it back)")
            else:
                self.agent.answer_error(p.request, -32603, "the change could not be written: " + p.path)
                self.chat.note("Could not write " + self.agent_rel(p.path))
        if len(self.agent_props) > 0:
            self.agent_show_proposal()
        else:
            self.git_diff_close()
            var ai = self.agent_index()
            if ai >= 0:
                self.focus(ai)
