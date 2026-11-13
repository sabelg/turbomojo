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
from util import to_str, decode, basename, run_system

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
  delete N[-M]     remove lines
  undo             take back the last change
  save             write the current file
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
            var r = 0
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
