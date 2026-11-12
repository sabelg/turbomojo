"""The plugin host in the IDE (src/plugins.mojo): start the plugins of the plugins
folder, poll them with the event loop, answer what they ask, run their commands, send
them the events they asked for, and show their status items. A plugin that dies,
writes nonsense or does not answer is stopped and said so; the IDE goes on.
"""
from std.collections import List
from appstate import *
from util import *
from json import JsonWriter, json_quote
from rpc import RpcMessage, RPC_RESPONSE, RPC_ERROR, RPC_REQUEST, RPC_NOTIFICATION
from plugins import *
from notify import NL_INFO, NL_DONE, NL_WARN, NL_ERROR
from window import ACT_OTHER, WK_EDITOR
from helpbook import TURBOMOJO_VERSION
from app_notify import *


__extension App:
    def plugins_start(mut self):
        """Find and start the plugins (at start-up, once the screen is up)."""
        if not self.plugins_on or self.plugins_dir.byte_length() == 0:
            return
        var warn = List[String]()
        self.plugins = find_plugins(self.plugins_dir, warn)
        for w in warn:
            self.config_warnings.append(w)
        for k in range(len(self.plugins)):
            self.plugin_launch(k)

    def plugin_launch(mut self, k: Int):
        ref p = self.plugins[k]
        var log = (self.plugins_log_dir + "/plugin-" + p.name + ".log") if self.plugins_log_dir.byte_length() > 0 else String("/dev/null")
        # (the process runs through `exec`: the change of folder needs a shell of its own)
        if not p.conn.start("sh -c " + shell_quote("cd " + shell_quote(p.dir) + " && exec " + p.command), log):
            p.state = PL_STOPPED
            p.why = "could not be started"
            return
        p.state = PL_STARTING
        p.started_ns = now_ns()
        var w = JsonWriter()
        w.begin_obj()
        w.kv_int("api", PLUGIN_API)
        w.kv_str("version", TURBOMOJO_VERSION)
        w.kv_str("root", self.symidx_root())
        w.end_obj()
        p.init_id = p.conn.request("initialize", w.text(), now_ns())

    def plugin_fds(self) -> List[Int]:
        var out = List[Int]()
        for p in self.plugins:
            if p.state != PL_STOPPED and p.conn.fd() >= 0:
                out.append(p.conn.fd())
        return out^

    def plugins_stop(mut self):
        for k in range(len(self.plugins)):
            if self.plugins[k].state != PL_STOPPED:
                self.plugins[k].conn.notify("shutdown", "")
                _ = self.plugins[k].conn.poll()
                _ = self.plugins[k].conn.stop()
                self.plugins[k].state = PL_STOPPED
                self.plugins[k].why = "TurboMojo ended"

    def plugin_dead(mut self, k: Int, why: String):
        """A plugin is gone (crashed, hung, nonsense): its commands go, the IDE stays."""
        var was = self.plugins[k].state
        _ = self.plugins[k].conn.stop()
        self.plugins[k].state = PL_STOPPED
        self.plugins[k].why = why
        self.plugins[k].status = ""
        if was == PL_READY:
            self.rebuild_keys(False)            # (its commands leave the menu)
        self.notify(NL_WARN, "Plugin " + self.plugins[k].name + " stopped", why)

    def plugins_tick(mut self, now: Int):
        for k in range(len(self.plugins)):
            if self.plugins[k].state == PL_STOPPED:
                continue
            var msgs = self.plugins[k].conn.poll()
            for m in msgs:
                self.plugin_message(k, m)
                if self.plugins[k].state == PL_STOPPED:
                    break
            if self.plugins[k].state == PL_STOPPED:
                continue
            if self.plugins[k].conn.ended() or not self.plugins[k].conn.alive():
                self.plugin_dead(k, "it ended" if self.plugins[k].state == PL_READY else "it ended before it was ready")
            elif self.plugins[k].state == PL_STARTING and now - self.plugins[k].started_ns > PLUGIN_INIT_MS * 1000000:
                self.plugin_dead(k, "it did not answer within " + String(PLUGIN_INIT_MS // 1000) + " s")

    def plugin_message(mut self, k: Int, m: RpcMessage):
        if m.kind == RPC_RESPONSE and m.id == self.plugins[k].init_id:
            self.plugin_ready(k, m)
            return
        if m.kind == RPC_ERROR and m.id == self.plugins[k].init_id:
            self.plugin_dead(k, "initialize failed: " + m.error_message())
            return
        if m.kind == RPC_ERROR:
            self.say("Plugin " + self.plugins[k].name + ": " + m.error_message())
            return
        if m.kind == RPC_REQUEST or m.kind == RPC_NOTIFICATION:
            self.plugin_asks(k, m)

    def plugin_ready(mut self, k: Int, m: RpcMessage):
        ref d = m.doc
        var r = m.result()
        self.plugins[k].cmds.clear()
        self.plugins[k].events.clear()
        var cs = d.get(r, "commands")
        for i in range(d.size(cs)):
            var c = d.at(cs, i)
            var id = d.str(d.get(c, "id"), "")
            var title = d.str(d.get(c, "title"), "")
            if id.byte_length() == 0 or title.byte_length() == 0:
                continue
            self.plugins[k].cmds.append(PluginCmd(id, title, d.str(d.get(c, "hint"), ""), d.str(d.get(c, "key"), "")))
        var es = d.get(r, "events")
        for i in range(d.size(es)):
            var e = d.str(d.at(es, i), "")
            if e.byte_length() > 0:
                self.plugins[k].events.append(e)
        self.plugins[k].state = PL_READY
        self.plugins[k].why = ""
        self.rebuild_keys(False)                # (its commands join the menu and the palette)
        var mine = "plugin " + self.plugins[k].name + ":"
        for w in self.plugin_warnings:
            if w.startswith(mine):
                self.notify(NL_WARN, "Plugin " + self.plugins[k].name, String(w[byte=mine.byte_length() + 1:]))

    def plugin_asks(mut self, k: Int, m: RpcMessage):
        """A request (answered) or notification from plugin k."""
        ref d = m.doc
        var p = m.params()
        var answer = m.kind == RPC_REQUEST
        if m.method == "ui/message":
            self.say(d.str(d.get(p, "text"), ""))
            if answer:
                self.plugins[k].conn.respond(m.id_json, "null")
        elif m.method == "ui/notify":
            var lv = d.str(d.get(p, "level"), "info")
            var level = NL_DONE if lv == "done" else (NL_WARN if lv == "warn" else (NL_ERROR if lv == "error" else NL_INFO))
            self.notify(level, d.str(d.get(p, "title"), self.plugins[k].name), d.str(d.get(p, "text"), ""))
            if answer:
                self.plugins[k].conn.respond(m.id_json, "null")
        elif m.method == "status/set":
            var t = d.str(d.get(p, "text"), "")
            self.plugins[k].status = String(t[byte=0:min(t.byte_length(), 40)]) if t.byte_length() > 40 else t
            if answer:
                self.plugins[k].conn.respond(m.id_json, "null")
        elif m.method == "editor/get":
            if answer:
                self.plugins[k].conn.respond(m.id_json, self.editor_json())
        elif m.method == "editor/insert":
            var te = self.top_editor()
            if te < 0:
                if answer:
                    self.plugins[k].conn.respond_error(m.id_json, -32000, "no editor is open")
                return
            self.wins[te].insert_text(decode(d.str(d.get(p, "text"), "")), ACT_OTHER)
            if answer:
                self.plugins[k].conn.respond(m.id_json, "null")
        elif answer:
            self.plugins[k].conn.respond_error(m.id_json, -32601, "TurboMojo has no method " + m.method)

    def editor_json(self) -> String:
        var w = JsonWriter()
        w.begin_obj()
        var te = self.top_editor()
        if te >= 0:
            w.kv_str("path", self.wins[te].path)
            w.kv_str("text", to_str(self.wins[te].buf.all_text()))
            w.kv_int("line", self.wins[te].cr + 1)
            w.kv_int("column", self.wins[te].cc + 1)
            w.kv_str("selection", to_str(self.wins[te].selected_text()) if self.wins[te].has_sel() else String(""))
        w.end_obj()
        return w.text()

    def plugin_run(mut self, cmd: Int):
        """One of a plugin's commands (from its menu item, key or the palette)."""
        var k = (cmd - CM_PLUGIN0) // PLUGIN_CMDS_MAX
        var c = (cmd - CM_PLUGIN0) % PLUGIN_CMDS_MAX
        if k < 0 or k >= len(self.plugins) or c >= len(self.plugins[k].cmds):
            return
        if self.plugins[k].state != PL_READY:
            self.say("The plugin " + self.plugins[k].name + " is not running (" + self.plugins[k].why + ")")
            return
        _ = self.plugins[k].conn.request("command", "{\"id\":" + json_quote(self.plugins[k].cmds[c].id) + "}", now_ns())

    def plugins_event(mut self, name: String, path: String, ok: Bool = True):
        """Tell the plugins that asked for it: "open", "save" or "build"."""
        for k in range(len(self.plugins)):
            if self.plugins[k].state == PL_READY and name in self.plugins[k].events:
                var w = JsonWriter()
                w.begin_obj()
                w.kv_str("name", name)
                w.kv_str("path", path)
                w.kv_bool("ok", ok)
                w.end_obj()
                self.plugins[k].conn.notify("event", w.text())

    def plugins_status(self) -> String:
        var out = String("")
        for p in self.plugins:
            if p.state == PL_READY and p.status.byte_length() > 0:
                out += p.status + "  "
        return out^
