"""IDE-side handler for file-queue IPC (`src/ipc.mojo`): handles `ping`, `open_location`,
`get_buffer`, `apply_edits`, `debug_inspect`, and `report_test_results` from
`tmide --reuse` and `tmide-mcp`."""
from std.collections import List
from std.os import listdir
from std.time import perf_counter_ns
from std.ffi import external_call
from appstate import *
from dap import DS_STOPPED, DS_RUNNING
from dbgview import nice_value, nice_type, console_command, console_result
from dialog import NEXT_NONE
from grep import sort_names
from json import json_parse, JsonWriter, json_quote, J_ARR
from signals import own_pid
from swap import write_bytes_atomic, delete_file
from testexp import TestFile, parse_run, apply_report
from util import (
    path_exists, read_file, bytes_to_str, str_bytes, abs_path, basename, dirname, shell_quote,
    run_system, decode, to_str, run_capture, lower_str,
)
from app_files import *
from app_jobs import *
from app_lsp import *
from app_lspextra import *
from app_problems import *
from app_layout import *
from app_debug import *
from app_tests import *
from app_outline import *
from app_gitdiff import *
from app_git import *
from lsp import path_to_uri, LSP_READY
from outline import outline_tag
from gitdiff import Side, side_hunks, unified
from svgshot import screen_svg
from nb_ai_rag import format_notebook_ipc_json
from app_v40 import *


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
        if op == "debug_inspect":
            var expr = String(doc.str(doc.get(0, "expression"), "").strip())
            var eval_ok = False
            var eval_res = String("")
            if expr.byte_length() > 0 and self.dbg.active() and self.dbg.state == DS_STOPPED:
                var fid_part = String("")
                if self.dview.sel >= 0 and self.dview.sel < len(self.dview.frames):
                    fid_part = ",\"frameId\":" + String(self.dview.frames[self.dview.sel].id)
                var seq = self.dbg.ask(
                    "evaluate",
                    "{\"expression\":" + json_quote(console_command(expr)) + fid_part + ",\"context\":\"repl\"}",
                )
                if seq > 0:
                    var deadline = Int(perf_counter_ns()) + 300_000_000
                    var got_eval = False
                    while Int(perf_counter_ns()) < deadline and not got_eval:
                        _ = self.dbg.pump()
                        for ai in range(len(self.dbg.answers)):
                            if self.dbg.answers[ai].request_seq == seq:
                                var ans = self.dbg.answers.pop(ai)
                                eval_ok = ans.success
                                var b = ans.body()
                                if ans.success:
                                    eval_res = console_result(ans.doc.str(ans.doc.get(b, "result"), ""))
                                else:
                                    eval_res = ans.message
                                got_eval = True
                                break
                        if not got_eval:
                            _ = external_call["usleep", Int32](Int32(5000))
                    if len(self.dbg.answers) > 0:
                        self.dv_answers()
            var state_str = "inactive"
            if self.dbg.active():
                state_str = "stopped" if self.dbg.state == DS_STOPPED else ("running" if self.dbg.state == DS_RUNNING else "starting")
            var dv_txt = String("")
            var dv_lines = self.dview.lines()
            for i in range(len(dv_lines)):
                if i > 0:
                    dv_txt += "\n"
                dv_txt += dv_lines[i]
            var cpu_txt = String("")
            var cpu_lines = self.cpu.lines()
            for i in range(len(cpu_lines)):
                if i > 0:
                    cpu_txt += "\n"
                cpu_txt += cpu_lines[i]
            var w = JsonWriter()
            w.begin_obj()
            w.kv_str("id", req_id)
            w.kv_bool("ok", True)
            w.kv_bool("active", self.dbg.active())
            w.kv_str("state", state_str)
            w.kv_str("program", self.dbg_source)
            w.kv_str("stop_file", self.dbg.stop_file)
            w.kv_int("stop_line", self.dbg.stop_line)
            w.kv_str("stop_reason", self.dbg.stop_text)
            w.key("frames")
            w.begin_arr()
            for f in self.dview.frames:
                w.begin_obj()
                w.kv_int("id", f.id)
                w.kv_str("name", f.name)
                w.kv_str("path", f.path)
                w.kv_int("line", f.line)
                w.end_obj()
            w.end_arr()
            w.key("locals")
            w.begin_arr()
            for nd in self.dview.nodes:
                w.begin_obj()
                w.kv_str("name", nd.name)
                w.kv_str("type", nice_type(nd.type))
                w.kv_str("value", nice_value(nd.value))
                w.kv_int("depth", nd.depth)
                w.end_obj()
            w.end_arr()
            w.key("watches")
            w.begin_arr()
            for ws in self.dview.watch_shown:
                w.str(ws)
            w.end_arr()
            w.key("registers")
            w.begin_arr()
            for rg in self.cpu.regs:
                w.begin_obj()
                w.kv_str("name", rg.name)
                w.kv_str("value", rg.value)
                w.kv_bool("changed", rg.changed)
                w.end_obj()
            for vrg in self.cpu.vregs:
                w.begin_obj()
                w.kv_str("name", vrg.name)
                w.kv_str("value", vrg.value)
                w.kv_bool("changed", vrg.changed)
                w.end_obj()
            w.end_arr()
            w.kv_str("debug_view", dv_txt)
            w.kv_str("cpu_view", cpu_txt)
            if expr.byte_length() > 0:
                w.kv_str("expression", expr)
                w.kv_bool("eval_ok", eval_ok)
                w.kv_str("eval_result", eval_res)
            w.end_obj()
            return w.text()
        if op == "report_test_results":
            var p_raw = doc.str(doc.get(0, "path"), "")
            if p_raw.byte_length() == 0:
                return ipc_error_json(req_id, "missing path")
            var p = abs_path(self.cwd, p_raw)
            var out_txt = doc.str(doc.get(0, "output"), "")
            var exit_code = doc.int(doc.get(0, "exit_code"), 0)
            var keep_skipped = doc.bool(doc.get(0, "keep_skipped"), False)
            var fi = -1
            for k in range(len(self.test_files)):
                if self.test_files[k].path == p:
                    fi = k
                    break
            if fi < 0:
                self.test_files.append(TestFile(p))
                fi = len(self.test_files) - 1
            var reports = parse_run(out_txt)
            if len(reports) > 0:
                for rep in reports:
                    apply_report(self.test_files[fi], rep, keep_skipped)
            elif exit_code != 0:
                self.test_files[fi].problem.clear()
                for ln in out_txt.split("\n"):
                    var s = String(String(ln).rstrip("\r"))
                    if s.byte_length() > 0 and len(self.test_files[fi].problem) < 20:
                        self.test_files[fi].problem.append(s)
            var cnts = self.test_files[fi].counts()
            self.tests_sync_lens()
            self.tests_show()
            self.export_ide_state()
            var w = JsonWriter()
            w.begin_obj()
            w.kv_str("id", req_id)
            w.kv_bool("ok", True)
            w.kv_str("path", p)
            w.kv_int("passed", cnts[0])
            w.kv_int("failed", cnts[1])
            w.kv_int("skipped", cnts[2])
            w.end_obj()
            return w.text()
        if op == "turbomojo_capture_screen" or op == "capture_screen":
            var fmt = doc.str(doc.get(0, "format"), "text")
            var w = JsonWriter()
            w.begin_obj()
            w.kv_str("id", req_id)
            w.kv_bool("ok", True)
            w.kv_int("cols", self.scr.w)
            w.kv_int("rows", self.scr.h)
            w.kv_str("format", fmt)
            if fmt == "svg":
                w.kv_str("svg", screen_svg(self.scr, self.pal.ed_fg, self.pal.desk_bg, "TurboMojo"))
            else:
                w.kv_str("text", to_str(self.scr.to_text()))
            w.end_obj()
            return w.text()
        if op == "turbomojo_symbol_search" or op == "symbol_search":
            var query = doc.str(doc.get(0, "query"), "")
            var q_low = lower_str(query)
            var limit = max(1, doc.int(doc.get(0, "limit"), 50))
            var syms = self.wsymbol_items()
            var w = JsonWriter()
            w.begin_obj()
            w.kv_str("id", req_id)
            w.kv_bool("ok", True)
            w.kv_str("query", query)
            w.key("symbols")
            w.begin_arr()
            var count = 0
            for s in syms:
                if count >= limit:
                    break
                if q_low.byte_length() == 0 or lower_str(s.name).find(q_low) >= 0:
                    w.begin_obj()
                    w.kv_str("name", s.name)
                    w.kv_str("kind", outline_tag(s.kind))
                    w.kv_str("file", s.path)
                    w.kv_int("line", s.row + 1)
                    w.kv_int("col", s.col + 1)
                    w.kv_str("owner", s.owner)
                    w.end_obj()
                    count += 1
            w.end_arr()
            w.kv_int("total", count)
            w.end_obj()
            return w.text()
        if op == "turbomojo_git_diff" or op == "git_diff":
            var p_raw = doc.str(doc.get(0, "path"), "")
            var diff_txt = String("")
            var hunks_count = 0
            if p_raw.byte_length() > 0:
                var p = abs_path(self.cwd, p_raw)
                var ei = self.find_editor(p)
                var old_side = Side.of("")
                var new_side = Side.of("")
                var buf_txt = doc.str(doc.get(0, "buffer_text"), "")
                if buf_txt.byte_length() > 0:
                    var disk_txt = bytes_to_str(read_file(p)) if path_exists(p) else String("")
                    old_side = Side.of(disk_txt)
                    new_side = Side.of(buf_txt)
                elif ei >= 0:
                    var sides = self.git_diff_sides(ei)
                    old_side = sides[0].copy()
                    new_side = sides[1].copy()
                elif path_exists(p):
                    var disk_txt = bytes_to_str(read_file(p))
                    var where = self.git_where(p)
                    var head_txt = String("")
                    if where[0].byte_length() > 0:
                        head_txt = bytes_to_str(run_capture("git -C " + shell_quote(where[0]) + " show :./" + shell_quote(where[1]) + " 2>/dev/null").out)
                    old_side = Side.of(head_txt)
                    new_side = Side.of(disk_txt)
                var hunks = side_hunks(old_side, new_side)
                hunks_count = len(hunks)
                var diff_rows = unified(old_side, new_side, hunks)
                for r in diff_rows:
                    diff_txt += r.text + "\n"
            else:
                var root = self.symidx_root()
                var r = run_capture("git -C " + shell_quote(root) + " diff 2>&1")
                diff_txt = bytes_to_str(r.out)
            var w = JsonWriter()
            w.begin_obj()
            w.kv_str("id", req_id)
            w.kv_bool("ok", True)
            w.kv_str("diff", diff_txt)
            w.kv_int("hunks", hunks_count)
            w.end_obj()
            return w.text()
        if op == "turbomojo_lsp_query" or op == "lsp_query":
            var qtype = doc.str(doc.get(0, "query_type"), "definition")
            var p_raw = doc.str(doc.get(0, "path"), "")
            var line = max(1, doc.int(doc.get(0, "line"), 1))
            var col = max(1, doc.int(doc.get(0, "col"), 1))
            if p_raw.byte_length() == 0:
                return ipc_error_json(req_id, "missing path")
            var p = abs_path(self.cwd, p_raw)
            var uri = path_to_uri(p)
            var xk = self.extra_for(p)
            if xk >= 0 and (not self.lsp.active() or self.lsp.find_doc(uri) < 0):
                if not self.lsp_extra[xk].client.active() or self.lsp_extra[xk].client.state != LSP_READY:
                    var w = JsonWriter()
                    w.begin_obj()
                    w.kv_str("id", req_id)
                    w.kv_bool("ok", False)
                    w.kv_str("error", "LSP server not running or not ready")
                    w.kv_str("query_type", qtype)
                    w.kv_str("path", p)
                    w.end_obj()
                    return w.text()
                if self.lsp_extra[xk].client.find_doc(uri) < 0:
                    var wi = self.find_editor(p)
                    if wi < 0:
                        try:
                            self.open_path(p)
                            wi = self.find_editor(p)
                        except:
                            pass
                    if wi >= 0:
                        self.extra_send_now(xk, wi)
                var xseq: Int
                var xnow = now_ns()
                if qtype == "hover":
                    xseq = self.lsp_extra[xk].client.request_hover(uri, line - 1, col - 1, xnow)
                elif qtype == "references":
                    xseq = self.lsp_extra[xk].client.request_references(uri, line - 1, col - 1, xnow)
                else:
                    xseq = self.lsp_extra[xk].client.request_definition(uri, line - 1, col - 1, xnow)
                if xseq < 0:
                    return ipc_error_json(req_id, "LSP server capability not available")
                var xdeadline = Int(perf_counter_ns()) + 500_000_000
                var xgot = False
                var xres_json = String("")
                while Int(perf_counter_ns()) < xdeadline and not xgot:
                    self.lsp_extra[xk].client.poll()
                    var xreps = self.lsp_extra[xk].client.take_replies()
                    for r in xreps:
                        if r.id == xseq:
                            xgot = True
                            var res_idx = r.result()
                            if res_idx >= 0:
                                xres_json = r.doc.dump(res_idx)
                            break
                        else:
                            self.lsp_extra[xk].client.replies.append(r.copy())
                    if not xgot:
                        _ = external_call["usleep", Int32](Int32(5000))
                var xw = JsonWriter()
                xw.begin_obj()
                xw.kv_str("id", req_id)
                xw.kv_bool("ok", xgot)
                xw.kv_str("query_type", qtype)
                xw.kv_str("path", p)
                xw.kv_int("line", line)
                xw.kv_int("col", col)
                if xgot:
                    xw.key("result")
                    xw.raw(xres_json if xres_json.byte_length() > 0 else "null")
                else:
                    xw.kv_str("error", "LSP query timed out")
                xw.end_obj()
                return xw.text()
            if not self.lsp.active() or self.lsp.state != LSP_READY:
                var w = JsonWriter()
                w.begin_obj()
                w.kv_str("id", req_id)
                w.kv_bool("ok", False)
                w.kv_str("error", "LSP server not running or not ready")
                w.kv_str("query_type", qtype)
                w.kv_str("path", p)
                w.end_obj()
                return w.text()
            if self.lsp.find_doc(uri) < 0:
                var wi = self.find_editor(p)
                if wi < 0:
                    try:
                        self.open_path(p)
                        wi = self.find_editor(p)
                    except:
                        pass
                if wi >= 0:
                    self.lsp_track(wi, now_ns())
            var req_seq: Int
            var now = now_ns()
            if qtype == "hover":
                req_seq = self.lsp.request_hover(uri, line - 1, col - 1, now)
            elif qtype == "references":
                req_seq = self.lsp.request_references(uri, line - 1, col - 1, now)
            else:
                req_seq = self.lsp.request_definition(uri, line - 1, col - 1, now)
            if req_seq < 0:
                return ipc_error_json(req_id, "LSP server capability not available")
            var deadline = Int(perf_counter_ns()) + 500_000_000
            var got_reply = False
            var res_json = String("")
            while Int(perf_counter_ns()) < deadline and not got_reply:
                self.lsp.poll()
                var reps = self.lsp.take_replies()
                for r in reps:
                    if r.id == req_seq:
                        got_reply = True
                        var res_idx = r.result()
                        if res_idx >= 0:
                            res_json = r.doc.dump(res_idx)
                        break
                    else:
                        self.lsp.replies.append(r.copy())
                if not got_reply:
                    _ = external_call["usleep", Int32](Int32(5000))
            var w = JsonWriter()
            w.begin_obj()
            w.kv_str("id", req_id)
            w.kv_bool("ok", got_reply)
            w.kv_str("query_type", qtype)
            w.kv_str("path", p)
            w.kv_int("line", line)
            w.kv_int("col", col)
            if got_reply:
                w.key("result")
                w.raw(res_json if res_json.byte_length() > 0 else "null")
            else:
                w.kv_str("error", "LSP query timed out")
            w.end_obj()
            return w.text()
        if op == "get_notebook_context":
            var nb_wi = self.top_editor()
            var p_nb = doc.str(doc.get(0, "path"), "")
            if p_nb.byte_length() > 0:
                var found_nb = self.find_editor(abs_path(String(self.cwd), p_nb))
                if found_nb >= 0:
                    nb_wi = found_nb
            if nb_wi < 0:
                return ipc_error_json(req_id, "no open notebook or editor")
            var ctx_nb = self.active_notebook_ai_context(nb_wi, 2)
            var w_nb = JsonWriter()
            w_nb.begin_obj()
            w_nb.kv_str("id", req_id)
            w_nb.kv_bool("ok", True)
            w_nb.key("notebook")
            w_nb.raw(format_notebook_ipc_json(ctx_nb))
            w_nb.end_obj()
            return w_nb.text()
        return ipc_error_json(req_id, "unknown op: " + op)
