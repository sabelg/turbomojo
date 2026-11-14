"""IDE-side handler for file-queue IPC (`src/ipc.mojo`): handles `ping`, `open_location`,
`get_buffer`, and `apply_edits` from `tmide --reuse` and `tmide-mcp`."""
from std.collections import List
from std.os import listdir
from appstate import *
from dialog import NEXT_NONE
from grep import sort_names
from json import json_parse, JsonWriter, J_ARR
from signals import own_pid
from swap import write_bytes_atomic, delete_file
from util import (
    path_exists, read_file, bytes_to_str, str_bytes, abs_path, basename, dirname, shell_quote,
    run_system, decode,
)
from app_files import *
from app_jobs import *
from app_lsp import *
from app_problems import *
from app_layout import *


@fieldwise_init
struct IpcEdit(Copyable, Movable):
    var line_mode: Bool
    var r1: Int
    var c1: Int
    var r2: Int
    var c2: Int
    var text: String


def ipc_error_json(req_id: String, msg: String) -> String:
    var w = JsonWriter()
    w.begin_obj()
    w.kv_str("id", req_id)
    w.kv_bool("ok", False)
    w.kv_str("error", msg)
    w.end_obj()
    return w.text()


__extension App:
    def ipc_enable(mut self, dir: String):
        """Enable IPC in `dir`, clearing stale request/reply files from prior runs."""
        self.ipc_dir = dir
        if dir.byte_length() == 0:
            return
        if not path_exists(dir):
            _ = run_system("mkdir -p " + shell_quote(dir))
        try:
            for name in listdir(dir):
                var s = String(name)
                if s.startswith("req-") or s.startswith("resp-"):
                    delete_file(dir + "/" + s)
        except:
            pass
        if self.watch.active():
            _ = self.watch.watch_dir(dir)

    def ipc_tick(mut self) -> Bool:
        """Process any pending `req-*.json` files in `self.ipc_dir`. True if any handled."""
        if self.ipc_dir.byte_length() == 0 or not path_exists(self.ipc_dir):
            return False
        var reqs = List[String]()
        try:
            for name in listdir(self.ipc_dir):
                var s = String(name)
                if s.startswith("req-") and s.endswith(".json"):
                    reqs.append(s)
        except:
            return False
        if len(reqs) == 0:
            return False
        sort_names(reqs)
        for name in reqs:
            var req_path = self.ipc_dir + "/" + name
            var raw = bytes_to_str(read_file(req_path))
            delete_file(req_path)
            var fallback_id = String(name[byte=4:name.byte_length() - 5])
            var reply = self.ipc_handle_one(raw, fallback_id)
            var doc = json_parse(reply)
            var rid = doc.str(doc.get(0, "id"), fallback_id) if doc.ok else fallback_id
            var resp_path = self.ipc_dir + "/resp-" + rid + ".json"
            _ = write_bytes_atomic(resp_path, str_bytes(reply + "\n"))
        return True

    def ipc_handle_one(mut self, raw: String, fallback_id: String) -> String:
        var doc = json_parse(raw)
        if not doc.ok:
            return ipc_error_json(fallback_id, "invalid JSON: " + doc.error)
        var req_id = doc.str(doc.get(0, "id"), fallback_id)
        var op = doc.str(doc.get(0, "op"), "")
        if op == "ping":
            var w = JsonWriter()
            w.begin_obj()
            w.kv_str("id", req_id)
            w.kv_bool("ok", True)
            w.kv_int("pid", own_pid())
            w.kv_str("project_dir", self.symidx_root())
            w.end_obj()
            return w.text()
        if op == "open_location":
            var p_raw = doc.str(doc.get(0, "path"), "")
            if p_raw.byte_length() == 0:
                return ipc_error_json(req_id, "missing path")
            var p = abs_path(self.cwd, p_raw)
            var line = max(1, doc.int(doc.get(0, "line"), 1))
            var col = max(1, doc.int(doc.get(0, "col"), 1))
            try:
                self.open_path(p)
            except e:
                return ipc_error_json(req_id, String(e))
            var wi = self.find_editor(p)
            if wi >= 0:
                self.focus(wi)
                if self.tiled:
                    self.layout_sync()
                wi = self.find_editor(p)
                if wi >= 0:
                    self.wins[wi].goto(line - 1, col - 1)
                    self.say("Opened " + basename(p) + ":" + String(self.wins[wi].cr + 1))
                    self.export_ide_state()
                    var w = JsonWriter()
                    w.begin_obj()
                    w.kv_str("id", req_id)
                    w.kv_bool("ok", True)
                    w.kv_str("path", p)
                    w.kv_int("line", self.wins[wi].cr + 1)
                    w.kv_int("col", self.wins[wi].cc + 1)
                    w.end_obj()
                    return w.text()
            return ipc_error_json(req_id, "could not open editor for " + p)
        if op == "get_buffer":
            var p_raw = doc.str(doc.get(0, "path"), "")
            if p_raw.byte_length() == 0:
                return ipc_error_json(req_id, "missing path")
            var p = abs_path(self.cwd, p_raw)
            var wi = self.find_editor(p)
            if wi >= 0:
                var txt = bytes_to_str(self.wins[wi].buf.text_bytes())
                var w = JsonWriter()
                w.begin_obj()
                w.kv_str("id", req_id)
                w.kv_bool("ok", True)
                w.kv_str("path", p)
                w.kv_bool("live", True)
                w.kv_bool("modified", self.wins[wi].buf.modified)
                w.kv_int("lines", self.wins[wi].buf.count())
                w.kv_str("text", txt)
                w.end_obj()
                return w.text()
            if not path_exists(p):
                return ipc_error_json(req_id, "file not found: " + p)
            var disk_txt = bytes_to_str(read_file(p))
            var line_cnt = 1
            for b in disk_txt.as_bytes():
                if b == 10:
                    line_cnt += 1
            var w = JsonWriter()
            w.begin_obj()
            w.kv_str("id", req_id)
            w.kv_bool("ok", True)
            w.kv_str("path", p)
            w.kv_bool("live", False)
            w.kv_bool("modified", False)
            w.kv_int("lines", line_cnt)
            w.kv_str("text", disk_txt)
            w.end_obj()
            return w.text()
        if op == "apply_edits":
            var p_raw = doc.str(doc.get(0, "path"), "")
            if p_raw.byte_length() == 0:
                return ipc_error_json(req_id, "missing path")
            var p = abs_path(self.cwd, p_raw)
            var arr = doc.get(0, "edits")
            if doc.kind(arr) != J_ARR:
                return ipc_error_json(req_id, "edits must be an array")
            var wi = self.find_editor(p)
            if wi < 0:
                if not path_exists(p):
                    return ipc_error_json(req_id, "file not found: " + p)
                try:
                    self.open_path(p)
                except e:
                    return ipc_error_json(req_id, String(e))
                wi = self.find_editor(p)
            if wi < 0:
                return ipc_error_json(req_id, "could not open editor for " + p)
            var edits = List[IpcEdit]()
            for enode in doc.children(arr):
                var sl = doc.int(doc.get(enode, "start_line"), 1)
                var el = doc.int(doc.get(enode, "end_line"), sl)
                var sc = doc.int(doc.get(enode, "start_col"), 0)
                var ec = doc.int(doc.get(enode, "end_col"), 0)
                var txt = doc.str(doc.get(enode, "text"), "")
                if sc > 0 or ec > 0:
                    edits.append(IpcEdit(False, max(0, sl - 1), max(0, sc - 1), max(0, el - 1), max(0, (ec if ec > 0 else sc) - 1), txt))
                else:
                    edits.append(IpcEdit(True, max(0, sl - 1), 0, el - 1, 0, txt))
            # Sort in descending order so earlier positions stay valid
            for a in range(len(edits)):
                for b in range(a + 1, len(edits)):
                    var swap_em = False
                    if edits[b].r1 > edits[a].r1:
                        swap_em = True
                    elif edits[b].r1 == edits[a].r1 and edits[b].c1 > edits[a].c1:
                        swap_em = True
                    if swap_em:
                        var tmp = edits[a].copy()
                        edits[a] = edits[b].copy()
                        edits[b] = tmp^
            var g = self.wins[wi].new_group()
            var cr = self.wins[wi].cr
            var cc = self.wins[wi].cc
            for ed in edits:
                var nlines = self.wins[wi].buf.count()
                if ed.line_mode:
                    var clean_txt = ed.text
                    if clean_txt.endswith("\r\n"):
                        var t1 = String(clean_txt[byte=0:clean_txt.byte_length() - 2])
                        clean_txt = t1
                    elif clean_txt.endswith("\n"):
                        var t2 = String(clean_txt[byte=0:clean_txt.byte_length() - 1])
                        clean_txt = t2
                    var repl = List[Int]()
                    for cp in decode(clean_txt):
                        if cp != 13:
                            repl.append(cp)
                    var has_text = ed.text.byte_length() > 0
                    if ed.r2 < ed.r1:
                        # Pure insertion before line ed.r1
                        if ed.r1 < nlines:
                            if has_text:
                                repl.append(10)
                                _ = self.wins[wi].buf.insert(ed.r1, 0, repl, cr, cc, g)
                        else:
                            var lr = max(0, nlines - 1)
                            var ins = List[Int]()
                            ins.append(10)
                            for cp in repl:
                                ins.append(cp)
                            _ = self.wins[wi].buf.insert(lr, self.wins[wi].buf.llen(lr), ins, cr, cc, g)
                    elif not has_text:
                        # Pure deletion of lines ed.r1 .. ed.r2
                        var r_start = min(ed.r1, nlines - 1)
                        var r_end = min(ed.r2, nlines - 1)
                        if r_end + 1 < nlines:
                            _ = self.wins[wi].buf.delete(r_start, 0, r_end + 1, 0, cr, cc, g)
                        elif r_start > 0:
                            _ = self.wins[wi].buf.delete(r_start - 1, self.wins[wi].buf.llen(r_start - 1), r_end, self.wins[wi].buf.llen(r_end), cr, cc, g)
                        else:
                            _ = self.wins[wi].buf.delete(0, 0, r_end, self.wins[wi].buf.llen(r_end), cr, cc, g)
                    else:
                        # Replace lines ed.r1 .. ed.r2 inclusive
                        var r_start = min(ed.r1, nlines - 1)
                        var r_end = min(ed.r2, nlines - 1)
                        _ = self.wins[wi].buf.delete(r_start, 0, r_end, self.wins[wi].buf.llen(r_end), cr, cc, g)
                        _ = self.wins[wi].buf.insert(r_start, 0, repl, cr, cc, g)
                else:
                    var r1 = min(ed.r1, nlines - 1)
                    var r2 = min(max(r1, ed.r2), nlines - 1)
                    var c1 = min(ed.c1, self.wins[wi].buf.llen(r1))
                    var c2 = min(ed.c2, self.wins[wi].buf.llen(r2))
                    if r1 == r2 and c2 < c1:
                        c2 = c1
                    if r1 < r2 or c1 < c2:
                        _ = self.wins[wi].buf.delete(r1, c1, r2, c2, cr, cc, g)
                    if ed.text.byte_length() > 0:
                        var repl = List[Int]()
                        for cp in decode(ed.text):
                            if cp != 13:
                                repl.append(cp)
                        _ = self.wins[wi].buf.insert(r1, c1, repl, cr, cc, g)
            self.wins[wi].sel = False
            self.wins[wi].break_group()
            self.wins[wi].clamp()
            self.sync_shared_buffers(wi)
            self.lsp_send_changes(wi, now_ns(), True)
            var want_save = doc.bool(doc.get(0, "save"), False)
            if want_save:
                try:
                    _ = self.save_window(wi, NEXT_NONE)
                except:
                    pass
            self.export_ide_state()
            self.say("Applied " + String(len(edits)) + " MCP edit(s) to " + basename(p))
            var w = JsonWriter()
            w.begin_obj()
            w.kv_str("id", req_id)
            w.kv_bool("ok", True)
            w.kv_str("path", p)
            w.kv_int("applied", len(edits))
            w.kv_bool("modified", self.wins[wi].buf.modified)
            w.kv_int("lines", self.wins[wi].buf.count())
            w.end_obj()
            return w.text()
        return ipc_error_json(req_id, "unknown op: " + op)
