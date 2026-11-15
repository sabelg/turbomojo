"""The line mode (P10-14b): TurboMojo without cursor addressing, for TERM=dumb and
`tmide --lines`. It reads commands as lines and answers in lines - prompts, the file's
text, compiler messages, notices - the way an Emacs shell buffer or a braille display
wants them: nothing is drawn, nothing moves, every answer is text that stays where it
was said. It drives the same App the screen does (the same buffers, undo, builds,
error list, dialogs), so a file edited here is edited the same way.

A dialog the IDE opens (Save as, a file that changed on disk, ...) is read out - its
title, its text, its fields, its numbered buttons - and the next line answers it: a
digit presses a button, y / n answer a question, other text is typed into the field
and Enter pressed, an empty line or "cancel" closes it."""
from std.collections import List
from std.ffi import external_call
from appstate import App, M_DIALOG, M_NORMAL
from window import WK_EDITOR
from app import *
from commands import CM_BUILD
from app_notify import spoken_notice
from term import key_event, wait_readable, KEY_ENTER
from util import to_str, decode, basename, run_system, run_capture, bytes_to_str, shell_quote, path_exists, read_file
from cells import parse_cells, cell_at_row
from snippets import synthesize_mojo_quickfixes
from docs import docs_for
from doclib import find_help, parse_query, path_markdown
from docpane import md_section
from outline import scan_outline, scope_path, outline_tag

comptime LINE_PROMPT = "tm> "

comptime LINE_HELP = """Commands (one per line; N and M are line numbers):
  open PATH        open a file (it becomes the current one)
  files            the open files; * marks unsaved changes
  use N            make the Nth file in `files` the current one
  print [N[-M]]    show lines (no number: ten lines from the cursor)
  N                go to line N and show it
  find TEXT        the next line containing TEXT, from the cursor
  set N TEXT       replace line N with TEXT
  insert N TEXT    a new line N (TEXT; what was there moves down)
  append TEXT      a new line after the last
  replace [N] A B  replace text A with B on current line or line N
  delete N[-M]     remove lines
  undo, redo       take back or redo changes
  save             write the current file
  doc SYMBOL       show documentation for symbol
  cell [next|prev] list or navigate code cells
  fix              apply quickfix to current line
  git [status|diff] show git status or diff
  build            compile it; the messages and the result
  errors           the compiler's messages with places
  next, prev       the next (previous) message: where, and the line
  run, test        run the program (or its tests); its output follows
  help             this text
  quit             leave (asks if files are unsaved); quit! leaves anyway"""


def read_line(fd: Int = 0) -> Tuple[String, Bool]:
    """One line from `fd` without the newline; False at the end of the input."""
    var bytes = List[UInt8]()
    var b = List[UInt8](length=1, fill=0)
    while True:
        var n = external_call["read", Int](Int32(fd), b.unsafe_ptr(), Int(1))
        if n <= 0:
            if len(bytes) == 0:
                return (String(""), False)
            break
        if b[0] == 10:
            break
        if b[0] != 13:
            bytes.append(b[0])
    return (String(from_utf8_lossy=bytes), True)


def line_range(arg: String, count: Int, cur: Int) -> Tuple[Int, Int]:
    """`N`, `N-M` or nothing (ten lines from `cur`), as 0-based (first, last);
    (-1, -1) if it is not a range. Clamped to the file."""
    var a = String(arg.strip())
    if a.byte_length() == 0:
        return (cur, min(count - 1, cur + 9))
    var dash = a.find("-")
    try:
        if dash < 0:
            var n = atol(a) - 1
            return (max(0, min(n, count - 1)), max(0, min(n, count - 1)))
        var f = atol(String(a[byte=0:dash])) - 1
        var l = atol(String(a[byte=dash + 1:])) - 1
        if l < f:
            return (-1, -1)
        return (max(0, min(f, count - 1)), max(0, min(l, count - 1)))
    except:
        return (-1, -1)


def is_number(s: String) -> Bool:
    if s.byte_length() == 0:
        return False
    for b in s.as_bytes():
        if Int(b) < 48 or Int(b) > 57:
            return False
    return True


def text_after(s: String, words: Int) -> String:
    """`s` after its first `words` words and the one space after each: the text of
    `set N TEXT` as typed, its indentation kept."""
    var t = String(s)
    for _ in range(words):
        var lead = String(t.lstrip())
        t = lead
        var sp = t.find(" ")
        if sp < 0:
            return String("")
        var rest = String(t[byte=sp + 1:])
        t = rest
    return t^


def split_first(s: String) -> Tuple[String, String]:
    var t = String(s.strip())
    var sp = t.find(" ")
    if sp < 0:
        return (t, String(""))
    return (String(t[byte=0:sp]), String(String(t[byte=sp + 1:]).lstrip()))


__extension App:
    def numbered_line(self, i: Int, r: Int) -> String:
        return String(r + 1) + ": " + to_str(self.wins[i].buf.line(r))

    def dialog_lines(self) -> List[String]:
        """The dialog that is open, read out."""
        var out = List[String]()
        out.append("dialog: " + self.dlg.title)
        for l in self.dlg.lines:
            if String(l.strip()).byte_length() > 0:
                out.append("  " + String(l.strip()))
        for f in self.dlg.fields:
            out.append("  field " + f.label + ": " + to_str(f.text))
        var b = List[String]()
        for k in range(len(self.dlg.buttons)):
            b.append(String(k + 1) + " " + self.dlg.buttons[k].replace("~", ""))
        if len(b) > 0:
            out.append("  buttons: " + ", ".join(b))
        out.append("  (answer: a button's number, y or n, text for the field, or an empty line to cancel)")
        return out^

    def dialog_answer(mut self, text: String) raises -> List[String]:
        var t = String(text.strip())
        if t.byte_length() == 0 or t == "cancel":
            self.handle(key_event(27))
            if self.mode == M_DIALOG:
                self.mode = M_NORMAL
            return ["cancelled"]
        var one = t.byte_length() == 1 and (is_number(t) or t == "y" or t == "n")
        if one or len(self.dlg.fields) == 0:
            for c in decode(t):
                self.handle(key_event(c))
        else:
            # the text is the field's value (what was pre-filled goes), then Enter
            var k = self.dlg.focus if self.dlg.focus < len(self.dlg.fields) else 0
            self.dlg.fields[k].text = decode(t)
            self.dlg.fields[k].cur = len(self.dlg.fields[k].text)
            self.dlg.fields[k].fresh = False
        if not one and self.mode == M_DIALOG:
            self.handle(key_event(KEY_ENTER))
        return List[String]()

    def wait_job(mut self, seconds: Int) raises:
        var left = seconds * 20
        while self.job.active and left > 0:
            var fds = List[Int]()
            fds.append(self.job.fd)
            _ = wait_readable(fds, 50)
            self.poll_job()
            left -= 1

    def unsaved_names(self) -> List[String]:
        var out = List[String]()
        for w in self.wins:
            if w.kind == WK_EDITOR and w.buf.modified:
                out.append(basename(w.path) if w.path.byte_length() > 0 else String("(untitled)"))
        return out^

    def build_report(mut self, mut out: List[String]) raises:
        """Wait for the build that is running; its messages, the summary and the
        notice, as lines."""
        self.wait_job(600)
        var mi = self.msg_index()
        if mi >= 0:
            for k in range(self.wins[mi].buf.count()):
                var l = to_str(self.wins[mi].buf.line(k))
                if String(l.strip()).byte_length() > 0:
                    out.append(l)
        var notice = self.status
        if self.mode == M_DIALOG and self.dlg.title == "Compiling":
            # the Turbo summary box: said as lines, not a question
            for l in self.dlg.lines:
                var t = String(l.replace("~", "").strip())
                if t.byte_length() > 0 and t.find("Press any key") < 0:
                    out.append(t)
            self.handle(key_event(27))
            self.mode = M_NORMAL
        self.status = notice

    def line_command(mut self, text: String) raises -> List[String]:
        """Run one line of the line mode; what it answers, as lines. A status message
        or notice the command leaves comes last ("build: error: Build failed: ...")."""
        if self.mode == M_DIALOG:
            var a = self.dialog_answer(text)
            if self.job.active and self.mode != M_DIALOG:
                # the answer let a build start (the folder is trusted now)
                if len(a) == 0 and self.status.byte_length() > 0:
                    a.append(self.status)
                    self.status = ""
                self.build_report(a)
            return self.line_tail(a^)
        var out = List[String]()
        var parts = split_first(text)
        var cmd = parts[0]
        var arg = parts[1]
        self.status = ""
        var i = self.top_editor()
        if cmd.byte_length() == 0:
            return out^
        if cmd == "help" or cmd == "?":
            for l in String(LINE_HELP).split("\n"):
                out.append(String(l))
            return out^
        if cmd == "quit" or cmd == "q" or cmd == "quit!" or cmd == "q!":
            var names = self.unsaved_names()
            if len(names) > 0 and not cmd.endswith("!"):
                out.append("unsaved: " + ", ".join(names) + " - save them, or quit! to leave anyway")
                return out^
            self.running = False
            out.append("bye")
            return out^
        if cmd == "open":
            if arg.byte_length() == 0:
                out.append("open what? (open PATH)")
                return out^
            self.open_path(arg)
            i = self.top_editor()
            if i >= 0:
                out.append("opened " + self.wins[i].path + ", " + String(self.wins[i].buf.count()) + " lines")
            return self.line_tail(out^)
        if cmd == "files":
            var n = 0
            for k in range(len(self.wins)):
                if self.wins[k].kind == WK_EDITOR:
                    n += 1
                    out.append(String(n) + ("* " if self.wins[k].buf.modified else "  ") + (self.wins[k].path if self.wins[k].path.byte_length() > 0 else String("(untitled)")) + (" (current)" if k == i else ""))
            if n == 0:
                out.append("no files open")
            return out^
        if cmd == "use":
            var n = 0
            for k in range(len(self.wins)):
                if self.wins[k].kind == WK_EDITOR:
                    n += 1
                    if String(n) == arg:
                        self.focus(k)
                        var t = self.top_editor()
                        out.append("current: " + self.wins[t].path)
                        return out^
            out.append("no file " + arg + " (see files)")
            return out^
        # the rest works on the current file
        if i < 0:
            out.append("no file open (open PATH)")
            return out^
        var count = self.wins[i].buf.count()
        if is_number(cmd) and arg.byte_length() == 0:
            var r = line_range(cmd, count, self.wins[i].cr)
            self.wins[i].goto(r[0], 0)
            out.append(self.numbered_line(i, r[0]))
            return out^
        if cmd == "print" or cmd == "p":
            var r = line_range(arg, count, self.wins[i].cr)
            if r[0] < 0:
                out.append("print N or print N-M")
                return out^
            for k in range(r[0], r[1] + 1):
                out.append(self.numbered_line(i, k))
            self.wins[i].goto(r[1], 0)
            return out^
        if cmd == "find" or cmd == "/":
            if arg.byte_length() == 0:
                out.append("find what?")
                return out^
            for d in range(1, count + 1):
                var r = (self.wins[i].cr + d) % count
                if to_str(self.wins[i].buf.line(r)).find(arg) >= 0:
                    self.wins[i].goto(r, 0)
                    out.append(self.numbered_line(i, r))
                    return out^
            out.append("not found: " + arg)
            return out^
        if cmd == "set" or cmd == "insert":
            var p = split_first(arg)
            if not is_number(p[0]):
                out.append(cmd + " N TEXT")
                return out^
            var r: Int
            try:
                r = atol(p[0]) - 1
            except:
                r = -1
            var g = self.wins[i].new_group()
            var cr = self.wins[i].cr
            var cc = self.wins[i].cc
            if cmd == "set":
                if r < 0 or r >= count:
                    out.append("no line " + p[0] + " (the file has " + String(count) + ")")
                    return out^
                var old = self.wins[i].buf.line(r)
                _ = self.wins[i].buf.delete(r, 0, r, len(old), cr, cc, g)
                _ = self.wins[i].buf.insert(r, 0, decode(text_after(text, 2)), cr, cc, g)
            else:
                if r < 0 or r > count:
                    out.append("no line " + p[0] + " (the file has " + String(count) + ")")
                    return out^
                if r == count:
                    var last = len(self.wins[i].buf.line(count - 1))
                    var t = List[Int]()
                    t.append(10)
                    t += decode(text_after(text, 2))
                    _ = self.wins[i].buf.insert(count - 1, last, t, cr, cc, g)
                else:
                    var t = decode(text_after(text, 2))
                    t.append(10)
                    _ = self.wins[i].buf.insert(r, 0, t, cr, cc, g)
            self.wins[i].break_group()
            self.wins[i].goto(r, 0)
            out.append(self.numbered_line(i, r))
            return out^
        if cmd == "append":
            return self.line_command("insert " + String(count + 1) + " " + text_after(text, 1))
        if cmd == "delete" or cmd == "d":
            var r = line_range(arg, count, self.wins[i].cr)
            if r[0] < 0 or arg.byte_length() == 0:
                out.append("delete N or delete N-M")
                return out^
            var g = self.wins[i].new_group()
            var cr = self.wins[i].cr
            var cc = self.wins[i].cc
            if r[1] + 1 < count:
                _ = self.wins[i].buf.delete(r[0], 0, r[1] + 1, 0, cr, cc, g)
            elif r[0] > 0:
                _ = self.wins[i].buf.delete(r[0] - 1, len(self.wins[i].buf.line(r[0] - 1)), r[1], len(self.wins[i].buf.line(r[1])), cr, cc, g)
            else:
                _ = self.wins[i].buf.delete(0, 0, r[1], len(self.wins[i].buf.line(r[1])), cr, cc, g)
            self.wins[i].break_group()
            var n = r[1] - r[0] + 1
            self.wins[i].goto(min(r[0], self.wins[i].buf.count() - 1), 0)
            out.append("deleted " + String(n) + (" line" if n == 1 else " lines") + "; the file has " + String(self.wins[i].buf.count()))
            return out^
        if cmd == "undo" or cmd == "u":
            if len(self.wins[i].buf.undos) == 0:
                out.append("nothing to undo")
                return out^
            self.wins[i].undo()
            out.append("undone; at " + self.numbered_line(i, self.wins[i].cr))
            return out^
        if cmd == "redo" or cmd == "r":
            if len(self.wins[i].buf.redos) == 0:
                out.append("nothing to redo")
                return out^
            self.wins[i].redo()
            out.append("redone; at " + self.numbered_line(i, self.wins[i].cr))
            return out^
        if cmd == "replace":
            var p = split_first(arg)
            var target_r = self.wins[i].cr
            var old_str: String
            var new_str: String
            if is_number(p[0]):
                try:
                    target_r = atol(p[0]) - 1
                except:
                    target_r = -1
                var p2 = split_first(p[1])
                old_str = p2[0]
                new_str = p2[1]
            else:
                old_str = p[0]
                new_str = p[1]
            if target_r < 0 or target_r >= count:
                out.append("no line " + p[0] + " (the file has " + String(count) + ")")
                return out^
            if old_str.byte_length() == 0:
                out.append("replace OLD NEW or replace N OLD NEW")
                return out^
            var cur_line = to_str(self.wins[i].buf.line(target_r))
            var byte_idx = cur_line.find(old_str)
            if byte_idx < 0:
                out.append("not found on line " + String(target_r + 1) + ": " + old_str)
                return out^
            var cp_idx = len(decode(String(cur_line[byte=0:byte_idx])))
            var old_cp_len = len(decode(old_str))
            var g = self.wins[i].new_group()
            var cr = self.wins[i].cr
            var cc = self.wins[i].cc
            _ = self.wins[i].buf.delete(target_r, cp_idx, target_r, cp_idx + old_cp_len, cr, cc, g)
            _ = self.wins[i].buf.insert(target_r, cp_idx, decode(new_str), cr, cc, g)
            self.wins[i].break_group()
            self.wins[i].goto(target_r, cp_idx)
            out.append(self.numbered_line(i, target_r))
            return out^
        if cmd == "cell":
            var cells = parse_cells(self.wins[i].buf)
            if len(cells) == 0:
                out.append("no code cells (# %%) in file")
                return out^
            var sub = split_first(arg)[0]
            var cur_idx = cell_at_row(cells, self.wins[i].cr)
            if sub == "next":
                var nxt = cur_idx + 1 if cur_idx + 1 < len(cells) else 0
                var tr = max(cells[nxt].header_row, cells[nxt].start_row)
                self.wins[i].goto(tr, 0)
                out.append("cell " + String(nxt + 1) + "/" + String(len(cells)) + ": " + cells[nxt].title)
                out.append(self.numbered_line(i, tr))
                return out^
            elif sub == "prev":
                var prv = cur_idx - 1 if cur_idx - 1 >= 0 else (len(cells) - 1)
                var tr = max(cells[prv].header_row, cells[prv].start_row)
                self.wins[i].goto(tr, 0)
                out.append("cell " + String(prv + 1) + "/" + String(len(cells)) + ": " + cells[prv].title)
                out.append(self.numbered_line(i, tr))
                return out^
            else:
                for c in cells:
                    out.append("cell " + String(c.index + 1) + ": " + c.title + " (lines " + String(c.start_row + 1) + "-" + String(c.end_row + 1) + ")")
                return out^
        if cmd == "fix" or cmd == "quickfix":
            var cr = self.wins[i].cr
            var cc = self.wins[i].cc
            var fixes = synthesize_mojo_quickfixes(self.wins[i].buf, cr, cc, List[String](), List[Int](), List[Int]())
            if len(fixes) == 0:
                out.append("no quickfix available at line " + String(cr + 1))
                return out^
            var qf = fixes[0].copy()
            var g = self.wins[i].new_group()
            _ = self.wins[i].buf.delete(qf.r1, qf.c1, qf.r2, qf.c2, cr, cc, g)
            _ = self.wins[i].buf.insert(qf.r1, qf.c1, decode(qf.new_text), cr, cc, g)
            self.wins[i].break_group()
            out.append("fixed: " + qf.title)
            out.append(self.numbered_line(i, qf.r1))
            return out^
        if cmd == "git":
            var sub = split_first(arg)[0]
            var git_cmd = "git status --porcelain"
            if sub == "diff":
                git_cmd = "git diff"
            elif arg.byte_length() > 0:
                git_cmd = "git " + arg
            var res = run_capture("cd " + shell_quote(self.cwd) + " && " + git_cmd + " 2>&1")
            var txt = bytes_to_str(res.out)
            if txt.strip().byte_length() == 0:
                out.append("git: clean")
            else:
                for l in txt.split("\n"):
                    if String(l.strip()).byte_length() > 0:
                        out.append(String(l))
            return out^
        if cmd == "doc":
            if arg.byte_length() == 0:
                out.append("doc SYMBOL")
                return out^
            var doc_path = self.wins[i].path
            var doc_text = docs_for(self.docs_of_file(doc_path), arg)
            if doc_text.byte_length() == 0:
                for k in range(len(self.doc_entries)):
                    var extra = docs_for(self.doc_entries[k], arg)
                    if extra.byte_length() > 0:
                        doc_text = extra
                        break
            if doc_text.byte_length() == 0:
                if not self.doc_index.built and self.doc_home.byte_length() > 0 and path_exists(self.doc_home):
                    self.docs_index_ready()
                if self.doc_index.built:
                    var api_e = -1
                    if len(self.doc_lib.pages) > 0:
                        api_e = self.docpane_api_entry(arg)
                        if api_e < 0:
                            var hits = find_help(self.doc_index, self.doc_lib, parse_query(arg), 3)
                            if len(hits) > 0:
                                api_e = hits[0].entry
                    else:
                        var low_arg = arg.lower()
                        for ei in range(len(self.doc_index.entries)):
                            if self.doc_index.entries[ei].low.find(low_arg) >= 0:
                                api_e = ei
                                break
                    if api_e >= 0:
                        ref ent = self.doc_index.entries[api_e]
                        if ent.page >= 0 and ent.page < len(self.doc_lib.pages):
                            var ppath = self.doc_lib.pages[ent.page].path
                            if ppath.byte_length() > 0 and path_exists(ppath):
                                doc_text = md_section(path_markdown(ppath), ent.text, ent.nth)
                        if doc_text.byte_length() == 0:
                            doc_text = ent.text
            if doc_text.byte_length() == 0:
                for k in range(len(self.symidx.syms)):
                    if self.symidx.syms[k].name == arg:
                        var spath = self.symidx.syms[k].path
                        var sname = self.symidx.syms[k].name
                        var skind = self.symidx.syms[k].kind
                        var sowner = self.symidx.syms[k].owner
                        var srow = self.symidx.syms[k].row
                        var file_doc = docs_for(self.docs_of_file(spath), arg)
                        if file_doc.byte_length() > 0:
                            doc_text = file_doc
                            break
                        var owner_part = " (in " + sowner + ")" if sowner.byte_length() > 0 else String("")
                        var header = outline_tag(skind) + " " + sname + owner_part + " — " + spath + ":" + String(srow + 1)
                        var src_lines = bytes_to_str(read_file(spath)).split("\n")
                        if srow >= 0 and srow < len(src_lines):
                            header += "\n" + String(src_lines[srow])
                        doc_text = header
                        break
            if doc_text.byte_length() > 0:
                for l in doc_text.split("\n"):
                    out.append(String(l))
            else:
                out.append("no documentation found for " + arg)
            return out^
        if cmd == "save" or cmd == "w":
            if self.ensure_saved(i) and self.mode != M_DIALOG:
                out.append("saved " + self.wins[i].path)
                self.status = ""
            return self.line_tail(out^)
        if cmd == "build" or cmd == "b":
            self.exec(CM_BUILD)
            if self.mode == M_DIALOG:
                return self.line_tail(out^)
            self.build_report(out)
            return self.line_tail(out^)
        if cmd == "errors":
            if len(self.errs) == 0:
                out.append("no compiler messages")
            var mi = self.msg_index()
            for k in range(len(self.errs)):
                var e = self.errs[k].copy()
                var text = String("")
                if mi >= 0 and e.msg_line < self.wins[mi].buf.count():
                    text = to_str(self.wins[mi].buf.line(e.msg_line))
                out.append(String(k + 1) + ". " + text)
            return out^
        if cmd == "next" or cmd == "prev":
            if len(self.errs) == 0:
                out.append("no compiler messages")
                return out^
            self.goto_error(1 if cmd == "next" else -1)
            var t = self.top_editor()
            var e = self.errs[self.err_idx].copy()
            out.append(String(self.err_idx + 1) + "/" + String(len(self.errs)) + ": " + self.status)
            if t >= 0 and e.path.byte_length() > 0:
                out.append(basename(self.wins[t].path) + " " + self.numbered_line(t, self.wins[t].cr))
            self.status = ""
            return out^
        if cmd == "run" or cmd == "test":
            if not self.ensure_saved(i) or self.mode == M_DIALOG:
                return self.line_tail(out^)
            var core = self.run_core(cmd == "test")
            out.append("$ mojo run " + basename(self.wins[i].path))
            self.line_print(out)
            out.clear()
            var st = run_system(core)
            out.append(cmd + ": exited with status " + String((st >> 8) & 255))
            return out^
        out.append("unknown command: " + cmd + " (help lists them)")
        return out^

    def line_tail(mut self, var out: List[String]) -> List[String]:
        """What a command answers, then the status message it left, then the dialog it
        opened (read out, to be answered by the next line)."""
        if self.status.byte_length() > 0:
            out.append(self.status)
            self.status = ""
        if self.mode == M_DIALOG:
            for l in self.dialog_lines():
                out.append(l)
        return out^

    def line_print(self, lines: List[String]):
        for l in lines:
            print(l)

    def run_lines(mut self) raises:
        """The line mode's loop: a prompt, a line, the answer - until quit or the end
        of the input."""
        self.reader = True
        print("TurboMojo line mode - help lists the commands, quit leaves.")
        var i = self.top_editor()
        if i >= 0 and self.wins[i].path.byte_length() > 0:
            print("current: " + self.wins[i].path + ", " + String(self.wins[i].buf.count()) + " lines")
        self.running = True
        while self.running:
            print(LINE_PROMPT if self.mode != M_DIALOG else "answer> ", end="", flush=True)
            var got = read_line()
            if not got[1]:
                print()
                var names = self.unsaved_names()
                if len(names) > 0:
                    print("end of input; unsaved: " + ", ".join(names) + " (not saved)")
                break
            try:
                self.line_print(self.line_command(got[0]))
            except e:
                print("error: " + String(e))

def announce_reader_context(mut app: App) -> String:
    """Announce window focus, scope, fold, and diagnostic changes when `app.reader` is True."""
    return app.announce_reader_context()
