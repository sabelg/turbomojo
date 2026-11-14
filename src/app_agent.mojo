"""The agent panel: a coding agent (ACP, src/acp.mojo) in a window at the right edge.

The conversation is shown as Markdown and grows while the agent answers. The prompt is
written on the panel's last lines; Enter sends it, Esc stops a turn that is running (or
returns to the editor). `@path` and `@path:12-20` in a prompt send that file or those
lines along (from the editor when the file is open there, so unsaved changes count).
File > Agent panel (Ctrl-F11) opens it; Shift-F11 puts the editor's selection (or file)
into the prompt.

The agent is the command `tools.agent` of the configuration; it runs in the project
folder, so it needs folder trust like a build. Until the editor offers its services
(P6-03) and asks before the agent may do something (P6-04), the agent cannot read or
write files through the editor and what it asks permission for is refused.
"""
from std.collections import List
from appstate import *
from app_notify import *
from util import *
from window import Window, WK_EDITOR, WK_AGENT
from term import KEY_ENTER, KEY_ESC, KEY_TAB, KEY_BACKSPACE, KEY_DELETE, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_UP, KEY_DOWN, KEY_PGUP, KEY_PGDN, K_BASE, MOD_ALT, ctrl
from dialog import Dialog, Field, D_AGENT_MODEL, D_AGENT_MODE, D_AGENT_THINKING, D_AGENT_FILE
from filestate import state_name
from toml import toml_quote
from json import JsonWriter
from acp import *
from agentchat import *
from markdown import MdLine, md_render
from app_outline import *
from app_problems import *
from agentsvc import allow_key, option_of
from app_agentsvc import *
from app_agentexplain import *


__extension App:
    def agent_index(self) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_AGENT:
                return i
        return -1

    def agent_toggle(mut self) raises:
        """Open the panel (and start the agent); in front: back to the editor; again
        from the editor... the panel closes when it is in front and asked again."""
        var ai = self.agent_index()
        if ai >= 0:
            if self.top() == ai:
                var x = self.wins[ai].x
                _ = self.wins.pop(ai)
                for i in range(len(self.wins)):
                    if self.wins[i].kind == WK_EDITOR and self.wins[i].x + self.wins[i].w == x:
                        self.wins[i].w = self.scr.w - self.wins[i].x
                var te = self.top_editor()
                if te >= 0:
                    self.focus(te)
            else:
                self.focus(ai)
            return
        var w = max(36, min(80, self.scr.w * 2 // 5))
        var x = self.scr.w - w
        var h = self.desk_h()
        var mi = self.msg_index()
        if mi >= 0:
            h = max(8, self.wins[mi].y - 1)
        var win = Window(WK_AGENT, "Agent", "agent:", x, 1, w, h, self.free_number())
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].x + self.wins[i].w > x and x - self.wins[i].x >= 20:
                self.wins[i].w = x - self.wins[i].x
        self.wins.append(win^)
        if not self.agent.active():
            if self.agent_command.byte_length() == 0:
                self.chat.note("No agent is set up. Name a coding agent that speaks ACP under [tools] in turbomojo.toml, for example agent = \"claude-agent-acp\", agent = \"gemini --experimental-acp\" or agent = \"codex-acp\" (each must be installed and signed in once in a terminal).")
            else:
                self.exec(CM_AGENT_START)

    def agent_session_file(self, root: String) -> String:
        if self.agent_sessions_dir.byte_length() == 0 or root.byte_length() == 0:
            return ""
        return self.agent_sessions_dir + "/" + state_name(root) + ".sid"

    def agent_start(mut self):
        if self.agent_command.byte_length() == 0:
            self.say("No agent is set up (tools.agent)")
            return
        var root = self.symidx_root()
        self.chat.note("Starting " + self.agent_command + " in " + root + "...")
        var log = state_dir() + "/agent.log"
        _ = run_system("mkdir -p " + shell_quote(state_dir()))   # (its stderr goes there: a first run has no folder yet)
        self.agent.services = True              # files and terminals through the editor
        self.agent.resume_session_id = ""
        var sf = self.agent_session_file(root)
        if sf.byte_length() > 0 and path_exists(sf):
            self.agent.resume_session_id = String(read_text(sf).strip())
        self.agent_forget()                     # a new session allows nothing yet
        _ = self.agent.start(self.agent_command, root, log, now_ns())

    def agent_new_session(mut self) raises:
        """Forget this project's saved session id, clear the conversation, and start a
        fresh session."""
        var sf = self.agent_session_file(self.symidx_root())
        if sf.byte_length() > 0 and path_exists(sf):
            _ = run_system("rm -f " + shell_quote(sf))
        self.agent.resume_session_id = ""
        if self.agent.active():
            self.agent.stop()
            self.agent_services_end()
            self.agent_forget()
        self.chat.clear()
        self.chat.note("Starting a fresh agent session...")
        if self.agent_index() < 0:
            self.agent_toggle()
        else:
            self.focus(self.agent_index())
            if self.agent_command.byte_length() > 0:
                self.exec(CM_AGENT_START)

    def agent_title(self) -> String:
        var name = self.agent.agent_name if self.agent.agent_name.byte_length() > 0 else String("Agent")
        if self.agent.busy():
            return name + " (working)"
        if self.agent.state == AS_STARTING or self.agent.state == AS_OPENING:
            return name + " (starting)"
        if self.agent.state == AS_FAILED:
            return name + " (stopped)"
        return name

    # -------------------------------------------------------------- events
    def agent_tick(mut self, now: Int) raises:
        if len(self.agent_terms) > 0:
            self.agent_svc_tick()
        if not self.agent.conn.proc.running and len(self.agent.events) == 0:
            return
        if self.agent.active() and not self.trust_ok():
            # the folder's trust was taken back: the agent may not go on
            self.agent.stop()
            self.agent_services_end()
            self.agent_forget()
            self.chat.note("The agent was stopped: the folder is not trusted any more")
            return
        self.agent.pump(now)
        for e in self.agent.take_events():
            if e.kind == AE_MESSAGE:
                self.chat.chunk(CE_AGENT, e.text)
            elif e.kind == AE_THOUGHT:
                self.chat.chunk(CE_THOUGHT, e.text)
            elif e.kind == AE_USER:
                self.chat.chunk(CE_USER, e.text)
            elif e.kind == AE_TOOL:
                var places = e.locations.copy()
                self.chat.tool(e.id, e.title, e.status, places)
            elif e.kind == AE_TOOL_UPDATE:
                self.chat.tool_update(e.id, e.title, e.status, e.text, e.diffs)
            elif e.kind == AE_PLAN:
                self.chat.plan(e.entries)
            elif e.kind == AE_PERMISSION:
                var key = allow_key(e.tool_kind, e.title)
                var auto_allow = self.agent_auto_exec() or (self.agent_auto_edits() and e.tool_kind == "edit")
                if key in self.agent_allowed or auto_allow:
                    # allowed for this session already, or by auto / accept-edits mode
                    var opt = option_of(e.option_kinds, e.option_ids, "allow_once")
                    if opt.byte_length() == 0:
                        opt = option_of(e.option_kinds, e.option_ids, "allow_always")
                    _ = self.agent.answer_permission(e.request, opt)
                    var why = String("this session") if key in self.agent_allowed else (self.agent_effective_mode() + " mode")
                    self.chat.note("Allowed (" + why + "): " + self.agent_what(e))
                else:
                    if self.top() != self.agent_index():
                        # (the panel does not come to the front by itself: a key typed
                        # for the editor would answer)
                        self.notify_as("agent", NL_WARN, "The agent asks for permission", self.agent_what(e) + " - " + self.reg.key_label(CM_AGENT) + " to answer")
                    self.agent_perms.append(e.copy())
                    self.chat.note("The agent asks to " + self.agent_what(e) + ": Y allows it once, A for this session, N refuses")
            elif e.kind == AE_TURN_END:
                self.chat.cancel_open_tools()
                self.agent_check_answer()
                self.export_ide_state()
                if self.top() != self.agent_index():
                    self.notify_as("agent", NL_DONE if e.stop_reason == "end_turn" else NL_WARN, (self.agent.agent_name if self.agent.agent_name.byte_length() > 0 else String("The agent")) + " has finished", "" if e.stop_reason == "end_turn" else e.stop_reason)
                if e.stop_reason == "error":
                    self.chat.note("The agent reported an error: " + e.text)
                elif e.stop_reason != "end_turn":
                    var why = e.stop_reason
                    if why == "cancelled":
                        why = "stopped"
                    elif why == "max_tokens":
                        why = "stopped: the answer reached the agent's length limit"
                    elif why == "max_turn_requests":
                        why = "stopped: the agent reached its limit of steps for one prompt"
                    elif why == "refusal":
                        why = "the agent refused to go on"
                    self.chat.note(why)
            elif e.kind == AE_SERVICE:
                self.agent_service(e)
            elif e.kind == AE_MODE:
                if e.text.byte_length() > 0:
                    self.chat.note(e.text)
                else:
                    self.chat.note("Mode: " + self.agent.mode_name(e.status))
                self.export_ide_state()
            elif e.kind == AE_MODEL:
                if e.text.byte_length() > 0:
                    self.chat.note(e.text)
                else:
                    var mname = self.agent.model_name(e.status)
                    self.chat.note("Model: " + mname)
                    self.say("Agent model: " + mname)
                self.export_ide_state()
            elif e.kind == AE_THINKING:
                if e.text.byte_length() > 0:
                    self.chat.note(e.text)
                else:
                    var tname = self.agent.thinking_name(e.status)
                    self.chat.note("Thinking: " + tname)
                    self.say("Agent thinking: " + tname)
                self.export_ide_state()
            elif e.kind == AE_READY:
                var sf = self.agent_session_file(self.agent.cwd)
                if sf.byte_length() > 0 and self.agent.session_id.byte_length() > 0:
                    _ = run_system("mkdir -p " + shell_quote(self.agent_sessions_dir))
                    _ = write_file(sf, str_bytes(self.agent.session_id + "\n"))
                var info = "Connected to " + self.agent.agent_name + " (" + self.agent_command + ")"
                if self.agent.resumed:
                    info += ", resumed session"
                if self.agent.current_model.byte_length() > 0:
                    info += ", model " + self.agent.model_name(self.agent.current_model)
                if self.agent.thinking.byte_length() > 0:
                    info += ", thinking " + self.agent.thinking_name(self.agent.thinking)
                if self.agent.mode.byte_length() > 0:
                    info += ", mode " + self.agent.mode_name(self.agent.mode)
                self.chat.note(info)
                # the agent's own tools may change files without asking the editor: by
                # default it works in the mode in which it asks first
                var want = self.agent_mode
                if want == "ask":
                    want = self.agent.asking_mode()
                    if want.byte_length() == 0 and len(self.agent.mode_ids) > 0:
                        self.chat.note("This agent has no mode that asks before it changes files; set tools.agent_mode to choose one")
                if want.byte_length() > 0 and want != self.agent.mode:
                    if not self.agent.set_mode(want, now):
                        self.chat.note("The agent has no mode \"" + want + "\" (tools.agent_mode)")
                self.export_ide_state()
                if self.agent_pending.byte_length() > 0:
                    _ = self.agent.prompt_blocks(self.agent_pending, now)
                    self.agent_pending = ""
            elif e.kind == AE_FAILED:
                self.notify_as("agent", NL_ERROR, "The agent stopped", e.text)
                self.chat.note("The agent is not running: " + e.text + ". Ctrl-F11 twice starts it again.")
                self.agent_pending = ""
                self.agent_services_end()
                self.agent_forget()
                self.log_error("agent: " + e.text)
            if self.agent_index() >= 0:
                self.agent_scroll = 0           # follow what comes

    def agent_what(self, e: AcpEvent) -> String:
        var what = e.title if e.title.byte_length() > 0 else String("use a tool")
        return what + ((" (" + e.tool_kind + ")") if e.tool_kind.byte_length() > 0 else String(""))

    def agent_perm_answer(mut self, how: Int):
        """The user's answer to the first permission request: 1 once, 2 this session,
        0 no."""
        if len(self.agent_perms) == 0:
            return
        var e = self.agent_perms.pop(0)
        var opt = String("")
        if how == 0:
            opt = option_of(e.option_kinds, e.option_ids, "reject_once")
            if opt.byte_length() == 0:
                opt = option_of(e.option_kinds, e.option_ids, "reject_always")
            self.chat.note("Refused: " + self.agent_what(e))
        else:
            opt = option_of(e.option_kinds, e.option_ids, "allow_once")
            if opt.byte_length() == 0:
                opt = option_of(e.option_kinds, e.option_ids, "allow_always")
            if how == 2:
                var key = allow_key(e.tool_kind, e.title)
                if key not in self.agent_allowed:
                    self.agent_allowed.append(key)
                self.chat.note("Allowed for this session: " + key)
            else:
                self.chat.note("Allowed once: " + self.agent_what(e))
        # (no option of that kind: the request is answered "cancelled")
        _ = self.agent.answer_permission(e.request, opt)

    def agent_forget(mut self):
        """The session is over: what it asked and was allowed goes."""
        self.agent_perms.clear()
        self.agent_allowed.clear()

    # -------------------------------------------------------------- prompts
    def agent_blocks(mut self, text: String) -> String:
        """The prompt as ACP content blocks: the text, then each mentioned file (or its
        lines) - embedded when the agent takes embedded context, else as a link."""
        var w = JsonWriter()
        w.begin_arr()
        w.begin_obj()
        w.kv_str("type", "text")
        w.kv_str("text", text)
        w.end_obj()
        var root = self.symidx_root()
        var seen = List[String]()
        for m in find_mentions(text):
            var path = abs_path(root, m.path)
            if not path_exists(path) or is_dir(path):
                continue
            var key = path + ":" + String(m.first) + "-" + String(m.last)
            if key in seen:
                continue
            seen.append(key)
            var uri = "file://" + path + (("#L" + String(m.first) + "-L" + String(m.last)) if m.first > 0 else String(""))
            w.begin_obj()
            if self.agent.embedded_context:
                var ei = self.find_editor(path)
                var body = to_str(self.wins[ei].buf.all_text()) if ei >= 0 else read_text(path)
                w.kv_str("type", "resource")
                w.key("resource")
                w.begin_obj()
                w.kv_str("uri", uri)
                w.kv_str("mimeType", mime_for(path))
                w.kv_str("text", lines_of(body, m.first, m.last))
                w.end_obj()
            else:
                w.kv_str("type", "resource_link")
                w.kv_str("uri", uri)
                w.kv_str("name", basename(path))
            w.end_obj()
        w.end_arr()
        return w.text()

    def agent_send(mut self) raises:
        var text = String(to_str(self.agent_input).strip())
        if text.byte_length() == 0:
            return
        if self.agent.busy():
            self.say("The agent is still working (Esc stops it)")
            return
        if self.agent.state == AS_FAILED or self.agent.state == AS_STOPPED:
            if self.agent_command.byte_length() == 0:
                self.say("No agent is set up (tools.agent)")
                return
            self.exec(CM_AGENT_START)
            if not self.agent.active():
                return                          # (folder trust was not given)
        if len(self.agent_history) == 0 or self.agent_history[len(self.agent_history) - 1] != text:
            self.agent_history.append(text)
        self.agent_hist_idx = -1
        self.agent_draft.clear()
        self.chat.user(text)
        var blocks = self.agent_blocks(text)
        if self.agent.state == AS_READY:
            _ = self.agent.prompt_blocks(blocks, now_ns())
        else:
            self.agent_pending = blocks         # sent once the session is open
        self.agent_input.clear()
        self.agent_cur = 0
        self.agent_scroll = 0

    # ------------------------------------------------- pickers & @completion
    def agent_model_dialog(mut self):
        if self.agent.state != AS_READY:
            self.say("Start the agent first (Ctrl-F11) to choose its model")
            return
        if len(self.agent.model_ids) == 0:
            self.say("This agent does not report available models")
            return
        var d = Dialog(D_AGENT_MODEL, "Agent Model", min(72, self.scr.w - 4), min(18, self.desk_h()))
        d.fields.append(Field("~F~ilter", ""))
        d.list_filter = True
        var items = List[String]()
        var data = List[Int]()
        var active = 0
        for k in range(len(self.agent.model_ids)):
            var id = self.agent.model_ids[k]
            var name = self.agent.model_names[k] if self.agent.model_names[k].byte_length() > 0 else id
            if id == self.agent.current_model:
                active = k
            items.append(("* " if id == self.agent.current_model else "  ") + pad_right(name, 34) + " " + id)
            data.append(k)
        d.set_items(items^, data^)
        d.muted_col = 37
        d.list_sel = active
        d.focus = 0
        d.buttons.append("~O~K")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def agent_model_choose(mut self, idx: Int):
        if idx < 0 or idx >= len(self.agent.model_ids):
            return
        var id = self.agent.model_ids[idx]
        if id == self.agent.current_model:
            self.say("Agent model: " + self.agent.model_name(id))
            return
        _ = self.agent.set_model(id, now_ns())

    def agent_mode_dialog(mut self):
        var ids = List[String]()
        var names = List[String]()
        var descs = List[String]()
        if len(self.agent.mode_ids) > 0:
            ids = self.agent.mode_ids.copy()
            names = self.agent.mode_names.copy()
            descs = self.agent.mode_texts.copy()
        else:
            ids.append("auto")
            names.append("Auto")
            descs.append("Edit files and run commands automatically")
            ids.append("accept-edits")
            names.append("Accept edits")
            descs.append("Accept file edits automatically, ask before running commands")
            ids.append("ask")
            names.append("Ask (default)")
            descs.append("Always ask before editing files or running commands")
            ids.append("plan")
            names.append("Plan")
            descs.append("Plan first before making changes")
        var cur = self.agent_effective_mode()
        if cur == "ask" and len(self.agent.mode_ids) > 0:
            var ak = self.agent.asking_mode()
            if ak.byte_length() > 0:
                cur = ak
        var d = Dialog(D_AGENT_MODE, "Agent Mode", min(72, self.scr.w - 4), min(16, self.desk_h()))
        var items = List[String]()
        var data = List[Int]()
        var active = 0
        for k in range(len(ids)):
            if ids[k] == cur:
                active = k
            items.append(("* " if ids[k] == cur else "  ") + pad_right(names[k], 20) + " " + descs[k])
            data.append(k)
        d.set_items(items^, data^)
        d.muted_col = 23
        d.list_sel = active
        d.focus = 0
        d.buttons.append("~O~K")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def agent_mode_choose(mut self, idx: Int):
        var id = String("")
        if len(self.agent.mode_ids) > 0:
            if idx >= 0 and idx < len(self.agent.mode_ids):
                id = self.agent.mode_ids[idx]
        else:
            var std_ids = ["auto", "accept-edits", "ask", "plan"]
            if idx >= 0 and idx < len(std_ids):
                id = std_ids[idx]
        if id.byte_length() == 0:
            return
        self.agent_mode = id
        self.persist_option("tools", "agent_mode", toml_quote(id))
        if self.agent.state == AS_READY:
            var target = self.agent.asking_mode() if id == "ask" else id
            if target.byte_length() > 0 and target in self.agent.mode_ids and target != self.agent.mode:
                _ = self.agent.set_mode(target, now_ns())
        self.say("Agent mode: " + id)
        self.export_ide_state()

    def agent_thinking_dialog(mut self):
        if self.agent.state != AS_READY:
            self.say("Start the agent first (Ctrl-F11) to choose its thinking level")
            return
        if len(self.agent.thinking_ids) == 0:
            self.say("This agent does not offer thinking levels")
            return
        var d = Dialog(D_AGENT_THINKING, "Agent Thinking", 50, min(14, self.desk_h()))
        var items = List[String]()
        var data = List[Int]()
        var active = 0
        for k in range(len(self.agent.thinking_ids)):
            var id = self.agent.thinking_ids[k]
            var name = self.agent.thinking_names[k] if self.agent.thinking_names[k].byte_length() > 0 else id
            if id == self.agent.thinking:
                active = k
            items.append(("* " if id == self.agent.thinking else "  ") + pad_right(name, 20) + " " + id)
            data.append(k)
        d.set_items(items^, data^)
        d.muted_col = 23
        d.list_sel = active
        d.focus = 0
        d.buttons.append("~O~K")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def agent_thinking_choose(mut self, idx: Int):
        if idx < 0 or idx >= len(self.agent.thinking_ids):
            return
        var id = self.agent.thinking_ids[idx]
        if id == self.agent.thinking:
            self.say("Agent thinking: " + self.agent.thinking_name(id))
            return
        _ = self.agent.set_thinking(id, now_ns())

    def agent_complete_at(mut self):
        """Complete `@file` before the cursor in the agent prompt: inline when one
        project file matches, or via a searchable picker when several match."""
        var at_pos = -1
        var p = self.agent_cur - 1
        while p >= 0 and self.agent_input[p] != 32:
            if self.agent_input[p] == 64 and (p == 0 or self.agent_input[p - 1] == 32):
                at_pos = p
                break
            p -= 1
        if at_pos < 0:
            if self.agent_cur > 0 and self.agent_input[self.agent_cur - 1] != 32:
                self.agent_input.insert(self.agent_cur, 32)
                self.agent_cur += 1
            at_pos = self.agent_cur
            self.agent_input.insert(self.agent_cur, 64)
            self.agent_cur += 1
        var prefix = slice_str(self.agent_input, at_pos + 1, self.agent_cur)
        var root = self.symidx_root()
        if not self.fidx.building and (not self.fidx.built or self.fidx.root != root):
            self.fidx.start(root)
            self.fidx.step(200)
        var raw = self.fidx.files.copy() if self.fidx.built else self.fidx.fresh.copy()
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].path.byte_length() > 0 and self.wins[i].path not in raw:
                raw.append(self.wins[i].path)
        var rels = List[String]()
        var matches = List[String]()
        for fp in raw:
            var rel = String(fp[byte=root.byte_length() + 1:]) if fp.startswith(root + "/") else fp
            rels.append(rel)
            if fuzzy_score(rel, prefix) >= 0:
                matches.append(rel)
        if len(matches) == 0:
            self.say("No project file matches @" + prefix)
            return
        if len(matches) == 1 and prefix.byte_length() > 0:
            self.agent_replace_at(at_pos, matches[0])
            return
        self.agent_at_start = at_pos
        self.agent_files = rels^
        var d = Dialog(D_AGENT_FILE, "Mention File (@)", min(72, self.scr.w - 4), min(20, self.desk_h()))
        d.fields.append(Field("~F~ile", prefix))
        d.list_filter = True
        var items = List[String]()
        var data = List[Int]()
        var keys = List[String]()
        for k in range(len(self.agent_files)):
            var rel = self.agent_files[k]
            var name = basename(rel)
            var where = dirname(rel) if rel != name else String("")
            items.append(pad_right(name, 30) + " " + where)
            keys.append(name + "  " + rel)
            data.append(k)
        d.keys = keys^
        d.set_items(items^, data^)
        d.muted_col = 31
        d.focus = 0
        d.buttons.append("~I~nsert")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def agent_replace_at(mut self, at_pos: Int, rel: String):
        if at_pos < 0 or at_pos > self.agent_cur or self.agent_cur > len(self.agent_input):
            return
        while self.agent_cur > at_pos:
            _ = self.agent_input.pop(at_pos)
            self.agent_cur -= 1
        for c in decode("@" + rel + " "):
            self.agent_input.insert(self.agent_cur, c)
            self.agent_cur += 1

    def agent_file_choose(mut self, idx: Int):
        if idx < 0 or idx >= len(self.agent_files):
            return
        var start = self.agent_at_start
        var chosen = self.agent_files[idx]
        self.agent_replace_at(start, chosen)
        var ai = self.agent_index()
        if ai >= 0:
            self.focus(ai)

    def agent_mention(mut self) raises:
        """The editor's selection (as @file:first-last) or its file (@file) into the
        prompt; the panel comes to the front."""
        var ei = self.top_editor()
        if ei < 0 or self.wins[ei].path.byte_length() == 0:
            self.say("Only a saved file can be mentioned")
            return
        var root = self.symidx_root()
        var p = self.wins[ei].path
        var rel = String(p[byte=root.byte_length() + 1:]) if p.startswith(root + "/") else p
        var token = "@" + rel
        if self.wins[ei].has_sel():
            var s = self.wins[ei].sel_range()
            var last = s.r2 if s.c2 > 0 or s.r2 == s.r1 else s.r2 - 1
            token += ":" + String(s.r1 + 1) + "-" + String(last + 1)
        if self.agent_index() < 0:
            self.agent_toggle()
        else:
            self.focus(self.agent_index())
        if self.agent_cur > 0 and self.agent_input[self.agent_cur - 1] != 32:
            token = " " + token
        for c in decode(token + " "):
            self.agent_input.insert(self.agent_cur, c)
            self.agent_cur += 1

    # ---------------------------------------------------------------- keys
    def agent_key(mut self, k: Int) raises -> Bool:
        """A key for the panel in front (False: the IDE's)."""
        var t = self.top()
        if t < 0 or self.wins[t].kind != WK_AGENT:
            return False
        # typing here too: nothing pops up under it (sending is a pause, like a save)
        self.typed_ns = 0 if k == KEY_ENTER else now_ns()
        var n = len(self.agent_input)
        if len(self.agent_perms) > 0:
            # the agent waits for a permission
            if k == 121 or k == 89:
                self.agent_perm_answer(1)
            elif k == 97 or k == 65:
                self.agent_perm_answer(2)
            elif k == 110 or k == 78:
                self.agent_perm_answer(0)
            elif not (k >= 32 and k < K_BASE) and k != KEY_ENTER:
                return k == KEY_ESC and self.agent_esc()
            return True
        if len(self.agent_asks) > 0:
            # a command waits for a yes or a no
            if k == 121 or k == 89:
                self.agent_ask_answer(True)
                return True
            if k == 97 or k == 65:
                var key = allow_key("execute", self.agent_asks[0].title)
                if key not in self.agent_allowed:
                    self.agent_allowed.append(key)
                self.chat.note("Allowed for this session: " + key)
                self.agent_ask_answer(True)
                return True
            if k == 110 or k == 78:
                self.agent_ask_answer(False)
                return True
            if k >= 32 and k < K_BASE:
                return True
        if k == KEY_ENTER and n == 0 and len(self.agent_props) > 0:
            self.agent_show_proposal()
        elif k == KEY_ENTER:
            self.agent_send()
        elif k == KEY_ESC:
            _ = self.agent_esc()
        elif k == KEY_BACKSPACE:
            if self.agent_cur > 0:
                _ = self.agent_input.pop(self.agent_cur - 1)
                self.agent_cur -= 1
        elif k == KEY_DELETE:
            if self.agent_cur < n:
                _ = self.agent_input.pop(self.agent_cur)
        elif k == KEY_LEFT:
            self.agent_cur = max(0, self.agent_cur - 1)
        elif k == KEY_RIGHT:
            self.agent_cur = min(n, self.agent_cur + 1)
        elif k == KEY_HOME:
            self.agent_cur = 0
        elif k == KEY_END:
            self.agent_cur = n
        elif k == KEY_TAB or k == ctrl(32):
            self.agent_complete_at()
        elif k == (KEY_UP | MOD_ALT):
            if len(self.agent_history) > 0:
                if self.agent_hist_idx < 0:
                    self.agent_draft = self.agent_input.copy()
                    self.agent_hist_idx = len(self.agent_history) - 1
                elif self.agent_hist_idx > 0:
                    self.agent_hist_idx -= 1
                self.agent_input = decode(self.agent_history[self.agent_hist_idx])
                self.agent_cur = len(self.agent_input)
        elif k == (KEY_DOWN | MOD_ALT):
            if self.agent_hist_idx >= 0:
                self.agent_hist_idx += 1
                if self.agent_hist_idx >= len(self.agent_history):
                    self.agent_hist_idx = -1
                    self.agent_input = self.agent_draft.copy()
                else:
                    self.agent_input = decode(self.agent_history[self.agent_hist_idx])
                self.agent_cur = len(self.agent_input)
        elif k == KEY_UP:
            self.agent_scroll += 1
        elif k == KEY_DOWN:
            self.agent_scroll = max(0, self.agent_scroll - 1)
        elif k == KEY_PGUP:
            self.agent_scroll += max(1, self.wins[t].h - 6)
        elif k == KEY_PGDN:
            self.agent_scroll = max(0, self.agent_scroll - max(1, self.wins[t].h - 6))
        elif k >= 32 and k < K_BASE:
            self.agent_input.insert(self.agent_cur, k)
            self.agent_cur += 1
        else:
            return False
        return True

    def agent_esc(mut self) raises -> Bool:
        """Esc in the panel: stop the turn (refusing what it asked), else back to the
        editor."""
        if self.agent.busy():
            while len(self.agent_asks) > 0:
                self.agent_ask_answer(False)
            while len(self.agent_props) > 0:
                self.agent_proposal_answer(False)
            self.agent_perms.clear()            # (cancel answers them "cancelled")
            self.agent.cancel()
            self.say("Stopping the agent's turn...")
        else:
            var te = self.top_editor()
            if te >= 0:
                self.focus(te)
        return True

    def agent_paste(mut self, text: List[Int]) -> Bool:
        var t = self.top()
        if t < 0 or self.wins[t].kind != WK_AGENT:
            return False
        for c in text:
            var ch = c
            if ch == 10 or ch == 13 or ch == 9:
                ch = 32                         # the prompt is one paragraph
            self.agent_input.insert(self.agent_cur, ch)
            self.agent_cur += 1
        return True

    # ---------------------------------------------------------------- draw
    def agent_input_rows(self, width: Int) -> List[List[Int]]:
        """The prompt as it is shown: "› " and the text, cut into rows of `width` (or
        the question about a command the agent wants to run)."""
        var rows = List[List[Int]]()
        var cur = decode("› ")
        var shown = self.agent_input.copy()
        if len(self.agent_perms) > 0:
            cur = List[Int]()
            shown = decode("Allow " + self.agent_what(self.agent_perms[0]) + "? Y once, A this session, N no")
        elif len(self.agent_asks) > 0:
            cur = List[Int]()
            shown = decode("Run `" + self.agent_asks[0].title + "`? Y runs it, A always (this session), N refuses")
        for c in shown:
            if len(cur) >= width:
                rows.append(cur^)
                cur = decode("  ")
            cur.append(c)
        rows.append(cur^)
        return rows^

    def agent_draw(mut self, i: Int, active: Bool):
        var p = self.pal.copy()
        var x = self.wins[i].x + 1
        var y = self.wins[i].y + 1
        var w = self.wins[i].w - 2
        var h = self.wins[i].h - 2
        if w < 8 or h < 4:
            return
        var rows = self.agent_input_rows(w - 1)
        var keep = min(len(rows), max(1, h // 3))
        var area = h - keep - 1
        if self.agent_lines_ver != self.chat.version or self.agent_lines_w != w:
            self.agent_lines = md_render(self.chat.markdown(self.agent.agent_name), w - 2, self.hl)
            self.agent_lines_ver = self.chat.version
            self.agent_lines_w = w
        var n = len(self.agent_lines)
        self.agent_scroll = min(self.agent_scroll, max(0, n - area))
        var first = max(0, n - area - self.agent_scroll)
        var lines = self.agent_lines.copy()
        self.draw_md(x, y, w, area, lines, first)
        # the line between: what the agent is doing
        var sep = String("")
        if self.agent.busy():
            sep = " working - Esc stops "
        elif self.agent_scroll > 0:
            sep = " " + String(self.agent_scroll) + " rows back - Down / PgDn "
        elif self.agent.current_model.byte_length() > 0:
            sep = " " + self.agent.model_name(self.agent.current_model) + " · " + self.agent_effective_mode() + " "
        self.scr.fill(x, y + area, w, 1, 0x2500, p.frame_inact, p.ed_bg)
        if sep.byte_length() > 0:
            _ = self.scr.text(x + 1, y + area, sep, p.frame_act, p.ed_bg)
        # the prompt
        self.scr.fill(x, y + area + 1, w, keep, 32, p.ed_fg, p.ed_bg)
        var r0 = len(rows) - keep
        for r in range(keep):
            var xx = x
            for c in rows[r0 + r]:
                xx = self.scr.draw_cp(xx, y + area + 1 + r, c, p.ed_fg, p.ed_bg)

    def agent_cursor(mut self, i: Int):
        """The terminal's cursor on the prompt (called after the windows are drawn)."""
        if len(self.agent_asks) > 0 or len(self.agent_perms) > 0:
            return                              # a question, not a prompt, is shown
        var x = self.wins[i].x + 1
        var y = self.wins[i].y + 1
        var w = self.wins[i].w - 2
        var h = self.wins[i].h - 2
        if w < 8 or h < 4:
            return
        var rows = self.agent_input_rows(w - 1)
        var keep = min(len(rows), max(1, h // 3))
        var area = h - keep - 1
        var per = w - 3                     # characters of the prompt on a row
        var row = self.agent_cur // per
        var col = 2 + self.agent_cur % per
        if row >= len(rows):
            row = len(rows) - 1
            col = len(rows[row])
        var r0 = len(rows) - keep
        if row >= r0:
            var cx = x
            for q in range(min(col, len(rows[row]))):
                cx += char_width(rows[row][q])
            self.scr.cx = cx
            self.scr.cy = y + area + 1 + row - r0
            self.scr.cvis = True
            self.scr.cblock = False
