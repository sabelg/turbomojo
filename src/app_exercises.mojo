"""Help > Exercises: an opt-in practice course in the style of Rustlings. Each exercise
is a small Mojo program that does not build (or builds and prints the wrong thing)
until it is fixed; Help > Exercise done? runs it and says whether it now prints what
it should. Nothing starts at launch.

The exercises are help/exercises/*.mojo, built in (src/exercise_pages.mojo). The
first time, the list asks how much Mojo you know and starts there (new to Mojo: 1,
some Python: 2, some Mojo: 5); any exercise can be opened from the list. Your copies
live in the state folder's exercises/ (Reset gives the original back), and which ones
are done in exercises/done. A failed check fills the Problems page, so F1 on the
line explains the message (P7-08); fixing one error may show the next one, which is
part of the practice.
"""
from std.collections import List
from appstate import *
from util import *
from dialog import *
from commands import CM_EX_CHECK
from exercise_pages import EX_COUNT, ex_key, ex_text
from problems import parse_compiler_output
from app_jobs import *
from app_files import *
from app_problems import *
from app_notify import *
from app_outline import *
from notify import NL_DONE

comptime EX_START_NEW = 0           # where each kind of experience starts
comptime EX_START_PYTHON = 1
comptime EX_START_MOJO = 4


def ex_expect(text: String) -> String:
    """What exercise `text` prints when it is right (its "# expect: " line)."""
    var k = text.find("# expect: ")
    if k < 0:
        return ""
    var rest = String(text[byte=k + 10:])
    var nl = rest.find("\n")
    return String(rest[byte=0:nl]) if nl >= 0 else rest


def ex_title(text: String) -> String:
    """"a new name needs var" from "# Exercise 1 of 8: a new name needs var"."""
    var nl = text.find("\n")
    var first = String(text[byte=0:nl]) if nl >= 0 else text
    var c = first.find(": ")
    return String(first[byte=c + 2:]) if c >= 0 else first


def ex_passed(output: String, expect: String) -> Bool:
    """Did a run print the expected line (as a whole line)?"""
    for l in output.split("\n"):
        if String(String(l).strip()) == expect:
            return True
    return False


__extension App:
    def ex_dir(self) -> String:
        return self.ex_home

    def ex_path(self, i: Int) -> String:
        return self.ex_dir() + "/" + ex_key(i) + ".mojo"

    def ex_done(self) -> List[String]:
        var out = List[String]()
        var p = self.ex_dir() + "/done"
        if path_exists(p):
            for l in bytes_to_str(read_file(p)).split("\n"):
                var s = String(String(l).strip())
                if s.byte_length() > 0 and s not in out:
                    out.append(s)
        return out^

    def ex_index_of(self, path: String) -> Int:
        for i in range(EX_COUNT):
            if path == self.ex_path(i):
                return i
        return -1

    def ex_original(self, i: Int) -> String:
        var key = self.reg.key_label(CM_EX_CHECK)
        return ex_text(i).replace(" ({key})", (" (" + key + ")") if key.byte_length() > 0 else String(""))

    def exercises_dialog(mut self):
        """Help > Exercises: the list, done ones marked. The first time, the buttons
        ask where to start."""
        if self.ex_home.byte_length() == 0:
            self.say("There is no folder for the exercises")
            return
        var done = self.ex_done()
        var started = path_exists(self.ex_dir())
        var items = List[String]()
        var data = List[Int]()
        var sel = 0
        for i in range(EX_COUNT):
            var ok = ex_key(i) in done
            items.append(("✓ " if ok else "  ") + String(i + 1) + ".  " + ex_title(ex_text(i)))
            data.append(i)
            if ok and sel == i and i + 1 < EX_COUNT:
                sel = i + 1                 # the first one not done
        var d = Dialog(D_EXERCISES, "Exercises", min(64, self.scr.w - 4), min(self.desk_h(), EX_COUNT + 9))
        if started:
            d.lines.append(String(len(done)) + " of " + String(EX_COUNT) + " done. Each program is wrong until you fix it.")
            d.set_items(items^, data^)
            d.list_sel = sel
            d.buttons.append("~O~pen")
            d.buttons.append("~R~eset")
            d.buttons.append("~C~lose")
        else:
            d.lines.append("Small Mojo programs that are wrong until you fix them.")
            d.lines.append("Where do you want to start?")
            d.set_items(items^, data^)
            d.buttons.append("~N~ew to Mojo")
            d.buttons.append("Some ~P~ython")
            d.buttons.append("Some ~M~ojo")
            d.buttons.append("~C~lose")
        self.show(d^)

    def exercises_button(mut self, b: Int, sel: Int) raises:
        var started = path_exists(self.ex_dir())
        if not started:
            if b > 2:
                return
            _ = run_system("mkdir -p " + shell_quote(self.ex_dir()))
            self.ex_open(EX_START_NEW if b == 0 else (EX_START_PYTHON if b == 1 else EX_START_MOJO))
            return
        var i = self.dlg.item_data[sel] if sel >= 0 and sel < len(self.dlg.item_data) else -1
        if i < 0:
            return
        if b == 0:
            self.ex_open(i)
        elif b == 1:
            var ei = self.find_editor(self.ex_path(i))
            if ei >= 0:
                self.wins[ei].buf.load(decode(self.ex_original(i)))
                self.wins[ei].buf.modified = True
                self.focus(ei)
            else:
                _ = write_file(self.ex_path(i), str_bytes(self.ex_original(i)))
                self.open_path(self.ex_path(i))
            self.say("Exercise " + String(i + 1) + " is as it was at the start")

    def ex_open(mut self, i: Int) raises:
        """Your copy of exercise i (made from the original the first time)."""
        _ = run_system("mkdir -p " + shell_quote(self.ex_dir()))
        var path = self.ex_path(i)
        if not path_exists(path):
            _ = write_file(path, str_bytes(self.ex_original(i)))
        self.open_path(path)
        self.say("Exercise " + String(i + 1) + " of " + String(EX_COUNT) + ": " + ex_title(ex_text(i)) + " - fix it, then Help > Exercise done?")

    def ex_check(mut self) raises:
        """Help > Exercise done?: save and run the exercise in front."""
        var ei = self.top_editor()
        var i = self.ex_index_of(self.wins[ei].path) if ei >= 0 else -1
        if i < 0:
            self.say("Open an exercise first (Help > Exercises)")
            return
        if self.job_busy():
            return
        if not self.ensure_saved(ei):
            return
        var dir = self.ex_dir()
        var limit = String("timeout 60 ") if which("timeout").byte_length() > 0 else String("")
        var cmd = "cd " + shell_quote(dir) + " && exec " + limit + self.compiler_cmd() + " run " + shell_quote(self.wins[ei].path) + " 2>&1"
        if self.start_job(JOB_TASK, cmd, dir, "exercise:" + ex_key(i)):
            self.task_output("Running exercise " + String(i + 1) + "...")

    def ex_finished(mut self, key: String, ok: Bool, output: String):
        """The end of a check (from finish_task)."""
        var i = -1
        for k in range(EX_COUNT):
            if ex_key(k) == key:
                i = k
        if i < 0:
            return
        var expect = ex_expect(ex_text(i))
        self.prob_build = parse_compiler_output(output, self.ex_dir())
        self.problems_show(False)
        if ok and ex_passed(output, expect):
            var done = self.ex_done()
            if key not in done:
                done.append(key)
                _ = write_file(self.ex_dir() + "/done", str_bytes("\n".join(done) + "\n"))
            var more = ("Next: Help > Exercises (" + String(i + 2) + ". " + ex_title(ex_text(i + 1)) + ")") if i + 1 < EX_COUNT else String("That was the last one.")
            self.notify_as("exercise", NL_DONE, "Exercise " + String(i + 1) + " done", more, True)
            self.say("✓ Exercise " + String(i + 1) + " done. " + more)
        elif ok:
            self.say("It runs, but it does not print \"" + expect + "\" yet")
        else:
            self.say("Not yet: " + String(len(self.prob_build)) + " problem(s) - F1 on the line explains the message")
