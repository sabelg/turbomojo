"""Portable file-queue IPC between CLI (`tmide --reuse`), MCP (`tmide-mcp`), and a live IDE.

Requests are written atomically (`write_bytes_atomic`) into `state_dir()/ipc/req-<id>.json`
and answered at `resp-<id>.json`. On Linux `Watcher` (`inotify`) wakes the event loop as
soon as a request lands; on other platforms the main loop checks the folder without spawning
subprocesses (`std.os.listdir`)."""
from std.collections import List
from std.ffi import external_call
from json import json_parse, JsonWriter
from signals import own_pid
from swap import write_bytes_atomic, delete_file, pid_alive
from util import (
    path_exists, read_file, bytes_to_str, str_bytes, abs_path, normalize_path, is_digit, decode, slice_str,
)


@fieldwise_init
struct FileLoc(Copyable, Movable):
    var path: String
    var line: Int       # 1-based (0: none given)
    var col: Int        # 1-based (0: none given)


def parse_positive_int(s: String) -> Int:
    if s.byte_length() == 0:
        return -1
    var n = 0
    for b in s.as_bytes():
        var c = Int(b)
        if not is_digit(c):
            return -1
        n = n * 10 + (c - 48)
    return n if n > 0 else -1


def parse_file_loc(raw: String) -> FileLoc:
    """Split `path[:line[:col]]` when the full string is not itself an existing path."""
    if raw.byte_length() == 0 or path_exists(raw):
        return FileLoc(raw, 0, 0)
    var last = raw.rfind(":")
    if last <= 0:
        return FileLoc(raw, 0, 0)
    var tail1 = String(raw[byte=last + 1:])
    var n1 = parse_positive_int(tail1)
    if n1 < 0:
        return FileLoc(raw, 0, 0)
    var head1 = String(raw[byte=0:last])
    var prev = head1.rfind(":")
    if prev > 0 and not path_exists(head1):
        var tail2 = String(head1[byte=prev + 1:])
        var n2 = parse_positive_int(tail2)
        if n2 > 0:
            var head2 = String(head1[byte=0:prev])
            return FileLoc(head2, n2, n1)
    return FileLoc(head1, n1, 0)


def ipc_live_dir(state_file: String) -> String:
    """Return `ipc_dir` from `ide-state.json` when the recorded IDE `pid` is alive, else ''."""
    if state_file.byte_length() == 0 or not path_exists(state_file):
        return ""
    var doc = json_parse(bytes_to_str(read_file(state_file)))
    if not doc.ok:
        return ""
    var pid = doc.int(doc.get(0, "pid"), 0)
    var dir = doc.str(doc.get(0, "ipc_dir"), "")
    if pid <= 0 or not pid_alive(pid) or dir.byte_length() == 0 or not path_exists(dir):
        return ""
    return dir


def ipc_send_request(state_file: String, req_id: String, payload_json: String, timeout_ms: Int = 1500) -> String:
    """Send a JSON request to the running IDE and wait up to `timeout_ms` for its JSON reply."""
    var dir = ipc_live_dir(state_file)
    if dir.byte_length() == 0:
        return ""
    var req_path = dir + "/req-" + req_id + ".json"
    var resp_path = dir + "/resp-" + req_id + ".json"
    delete_file(resp_path)
    if not write_bytes_atomic(req_path, str_bytes(payload_json + "\n")):
        return ""
    var waited = 0
    while waited < timeout_ms:
        if path_exists(resp_path):
            var reply = bytes_to_str(read_file(resp_path))
            delete_file(resp_path)
            return reply
        _ = external_call["usleep", Int32](UInt32(10000))
        waited += 10
    delete_file(req_path)
    return ""


def ipc_open_in_running_ide(state_file: String, cwd: String, raw_targets: List[String]) -> Bool:
    """Send `open_location` requests for `raw_targets` (or `ping` when empty) to a live IDE.
    Returns True if a running IDE acknowledged them."""
    var dir = ipc_live_dir(state_file)
    if dir.byte_length() == 0:
        return False
    var pid_s = String(own_pid())
    if len(raw_targets) == 0:
        var req_id = pid_s + "-0"
        var w = JsonWriter()
        w.begin_obj()
        w.kv_str("id", req_id)
        w.kv_str("op", "ping")
        w.end_obj()
        var rep = ipc_send_request(state_file, req_id, w.text())
        var doc = json_parse(rep)
        return rep.byte_length() > 0 and doc.ok and doc.bool(doc.get(0, "ok"), False)
    var any_ok = False
    for k in range(len(raw_targets)):
        var loc = parse_file_loc(raw_targets[k])
        var full = abs_path(cwd, loc.path)
        var req_id = pid_s + "-" + String(k + 1)
        var w = JsonWriter()
        w.begin_obj()
        w.kv_str("id", req_id)
        w.kv_str("op", "open_location")
        w.kv_str("path", full)
        w.kv_int("line", loc.line if loc.line > 0 else 1)
        w.kv_int("col", loc.col if loc.col > 0 else 1)
        w.end_obj()
        var rep = ipc_send_request(state_file, req_id, w.text())
        var doc = json_parse(rep)
        if rep.byte_length() > 0 and doc.ok and doc.bool(doc.get(0, "ok"), False):
            any_ok = True
    return any_ok
