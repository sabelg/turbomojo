"""The plugin host in the IDE (src/plugins.mojo): start the plugins of the plugins
folder, poll them with the event loop, answer what they ask, run their commands, send
them the events they asked for, and show their status items. A plugin that dies,
writes nonsense or does not answer is stopped and said so; the IDE goes on.
"""
from std.collections import List
from appstate import *
from util import *
from json import Json, JsonWriter, json_quote
from rpc import RpcMessage, RPC_RESPONSE, RPC_ERROR, RPC_REQUEST, RPC_NOTIFICATION
from plugins import *
from notify import NL_INFO, NL_DONE, NL_WARN, NL_ERROR
from window import Window, ACT_OTHER, WK_EDITOR, WK_PANEL
from term import KEY_ENTER, KEY_ESC
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
        var pi = len(self.panels) - 1
        while pi >= 0:
            if self.panels[pi].plugin == k:
                self.panel_remove(pi, False)    # (its panels close)
            pi -= 1
        if was == PL_READY:
            self.rebuild_keys(False)            # (its commands leave the menu)
        self.notify(NL_WARN, "Plugin " + self.plugins[k].name + " stopped", why)

    def plugins_tick(mut self, now: Int):
        # panels whose window the user closed: the plugin is told, the room given back
        var pi = len(self.panels) - 1
        while pi >= 0:
            if self.panel_window(pi) < 0:
                self.panel_remove(pi, True)
            pi -= 1
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
        elif m.method == "panel/open":
            self.panel_open(k, d.str(d.get(p, "id"), ""), d.str(d.get(p, "title"), ""), d.str(d.get(p, "kind"), "list") == "table", d, d.get(p, "columns"))
            if answer:
                self.plugins[k].conn.respond(m.id_json, "null")
        elif m.method == "panel/set":
            var pi = self.panel_find(k, d.str(d.get(p, "id"), ""))
            if pi < 0:
                if answer:
                    self.plugins[k].conn.respond_error(m.id_json, -32000, "no panel " + d.str(d.get(p, "id"), "") + " is open")
                return
            self.panel_fill(pi, d, d.get(p, "rows"))
            if answer:
                self.plugins[k].conn.respond(m.id_json, "null")
        elif m.method == "panel/close":
            var pi = self.panel_find(k, d.str(d.get(p, "id"), ""))
            if pi >= 0:
                self.panel_remove(pi, False)
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

    # ---------------------------------------------------------------- panels
    def panel_path(self, pi: Int) -> String:
        return "panel:" + self.plugins[self.panels[pi].plugin].name + "/" + self.panels[pi].id

    def panel_find(self, k: Int, id: String) -> Int:
        for pi in range(len(self.panels)):
            if self.panels[pi].plugin == k and self.panels[pi].id == id:
                return pi
        return -1

    def panel_window(self, pi: Int) -> Int:
        var path = self.panel_path(pi)
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_PANEL and self.wins[i].path == path:
                return i
        return -1

    def panel_of_window(self, i: Int) -> Int:
        for pi in range(len(self.panels)):
            if self.panel_path(pi) == self.wins[i].path:
                return pi
        return -1

    def panel_open(mut self, k: Int, id: String, title: String, table: Bool, d: Json, columns: Int):
        """panel/open: a window at the right edge (the editors make room), or the panel
        that is open already, brought to the front."""
        if id.byte_length() == 0:
            return
        var pi = self.panel_find(k, id)
        if pi < 0:
            self.panels.append(PluginPanel(k, id))
            pi = len(self.panels) - 1
        self.panels[pi].title = title if title.byte_length() > 0 else id
        self.panels[pi].table = table
        self.panels[pi].columns.clear()
        for c in range(d.size(columns)):
            self.panels[pi].columns.append(d.str(d.at(columns, c), ""))
        var wi = self.panel_window(pi)
        if wi < 0:
            var w = max(30, min(60, self.scr.w // 3))
            var x = self.scr.w - w
            var h = self.desk_h()
            var mi = self.msg_index()
            if mi >= 0:
                h = max(6, self.wins[mi].y - 1)
            for i in range(len(self.wins)):
                if self.wins[i].kind == WK_EDITOR and self.wins[i].x + self.wins[i].w > x and x - self.wins[i].x >= 20:
                    self.wins[i].w = x - self.wins[i].x
            var win = Window(WK_PANEL, self.panels[pi].title, self.panel_path(pi), x, 1, w, h, self.free_number())
            self.wins.append(win^)
            self.panels[pi].x = x
            self.panels[pi].w = w
        else:
            self.focus(wi)
        self.ppanel_show(pi)

    def panel_fill(mut self, pi: Int, d: Json, rows: Int):
        """panel/set: the rows, each {"text"} or {"cells"}, with "style" and "data"."""
        self.panels[pi].cells.clear()
        self.panels[pi].styles.clear()
        self.panels[pi].data.clear()
        for r in range(d.size(rows)):
            var row = d.at(rows, r)
            var cells = List[String]()
            var cs = d.get(row, "cells")
            if cs >= 0:
                for c in range(d.size(cs)):
                    cells.append(d.str(d.at(cs, c), ""))
            else:
                cells.append(d.str(d.get(row, "text"), ""))
            self.panels[pi].cells.append(cells^)
            self.panels[pi].styles.append(style_mark(d.str(d.get(row, "style"), "")))
            self.panels[pi].data.append(d.str(d.get(row, "data"), ""))
        self.ppanel_show(pi)

    def ppanel_show(mut self, pi: Int):
        var wi = self.panel_window(pi)
        if wi < 0:
            return
        var lines = panel_lines(self.panels[pi])
        var text = List[Int]()
        for k in range(len(lines)):
            if k > 0:
                text.append(10)
            for c in decode(lines[k]):
                text.append(c)
        var keep = self.wins[wi].cr
        self.wins[wi].title = self.panels[pi].title
        self.wins[wi].buf.load(text)
        self.wins[wi].buf.modified = False
        var marks = List[Int]()
        var head = self.panels[pi].header_rows()
        for _ in range(head):
            marks.append(4)                     # (the column titles: dim)
        for s in self.panels[pi].styles:
            marks.append(s)
        self.wins[wi].row_marks = marks^
        self.wins[wi].cr = max(head, min(keep, self.wins[wi].buf.count() - 1))

    def panel_remove(mut self, pi: Int, tell: Bool):
        """Close a panel: its window goes, the editors get the room back; with `tell`
        (the user closed it) the plugin hears panel/closed."""
        var wi = self.panel_window(pi)
        if wi >= 0:
            _ = self.wins.pop(wi)
        var x = self.panels[pi].x
        var right = x + self.panels[pi].w
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].x + self.wins[i].w == x:
                self.wins[i].w = right - self.wins[i].x
        var k = self.panels[pi].plugin
        if tell and k < len(self.plugins) and self.plugins[k].state == PL_READY:
            self.plugins[k].conn.notify("panel/closed", "{\"id\":" + json_quote(self.panels[pi].id) + "}")
        _ = self.panels.pop(pi)
        var te = self.top_editor()
        if te >= 0 and wi >= 0:
            self.focus(te)

    def panel_key(mut self, k: Int) -> Bool:
        """Keys in a panel: Enter chooses the row (the plugin hears panel/select), Esc
        goes back to the code."""
        var t = self.top()
        var pi = self.panel_of_window(t)
        if pi < 0:
            return False
        if k == KEY_ESC:
            var te = self.top_editor()
            if te >= 0:
                self.focus(te)
            return True
        if k == KEY_ENTER:
            var row = self.wins[t].cr - self.panels[pi].header_rows()
            if row < 0 or row >= len(self.panels[pi].cells):
                return True
            var pk = self.panels[pi].plugin
            if self.plugins[pk].state != PL_READY:
                self.say("The plugin " + self.plugins[pk].name + " is not running")
                return True
            var w = JsonWriter()
            w.begin_obj()
            w.kv_str("id", self.panels[pi].id)
            w.kv_int("row", row)
            w.kv_str("data", self.panels[pi].data[row])
            w.end_obj()
            self.plugins[pk].conn.notify("panel/select", w.text())
            return True
        return False
