"""File > New project (P11-04): asks for a folder, writes a Mojo project there
(newproject.mojo has what goes in it), makes it the folder the IDE works in, opens
hello.mojo and its test, and runs `pixi install` with its output on the Message page.
The first run's welcome offers it when the folder has no project yet."""
from std.collections import List
from std.ffi import external_call
from appstate import *
from util import *
from dialog import *
from project import find_up
from version import MOJO_BUILT_WITH
from newproject import np_name_problem, np_platform, np_mojo_spec, np_files
from app_jobs import *
from app_files import *
from app_notify import *
from app_outline import *
from app_explorer import *
from notify import NL_INFO


def folder_is_empty(dir: String) -> Bool:
    for name in list_dir(dir):
        if name != "../":
            return False
    return True


__extension App:
    def no_project_here(mut self) -> Bool:
        """No pixi.toml at or above the folder, and no Mojo file in it."""
        if self.pixi_locate().byte_length() > 0:
            return False
        for name in list_dir(self.cwd):
            if name.endswith(".mojo") or name.endswith(".🔥"):
                return False
        return True

    def np_default_folder(self) -> String:
        """The folder itself when it is empty, otherwise a new hello-mojo beside what
        is there."""
        if folder_is_empty(self.cwd):
            return self.cwd
        var d = join_path(self.cwd, "hello-mojo")
        var n = 2
        while path_exists(d) and n < 100:
            d = join_path(self.cwd, "hello-mojo-" + String(n))
            n += 1
        return d

    def new_project_dialog(mut self, welcome: Bool = False):
        var d = Dialog(D_NEW_PROJECT, "Welcome - New Mojo Project" if welcome else "New Project", min(70, self.scr.w - 4), 11)
        if welcome:
            d.lines.append("There is no Mojo project in this folder. Make one?")
        d.lines.append("Writes a pixi.toml with Mojo, hello.mojo and a test.")
        d.lines.append("Then `pixi install` gets Mojo. The folder names the project.")
        d.fields.append(Field("~F~older", self.np_default_folder()))
        d.buttons.append("~C~reate")
        d.buttons.append("Cancel")
        self.show(d^)

    def new_project_create(mut self, folder: String) raises -> Bool:
        """Write the project in `folder` (relative to where the IDE works) and open it;
        False (and why, in a message box) when it cannot be made there."""
        var f = String(folder.strip())
        if f.byte_length() == 0:
            self.info("New Project", "Give a folder for the project")
            return False
        var dir = abs_path(self.cwd, f)
        while dir.byte_length() > 1 and dir.endswith("/"):
            var cut = String(dir[byte=0 : dir.byte_length() - 1])
            dir = cut
        var name = basename(dir)
        var why = np_name_problem(name)
        if why.byte_length() > 0:
            self.info("New Project", why + ": " + name)
            return False
        if path_exists(dir) and not is_dir(dir):
            self.info("New Project", dir + " is a file, not a folder")
            return False
        if is_dir(dir) and not folder_is_empty(dir):
            self.info("New Project", basename(dir) + " is not empty: choose a new or empty folder")
            return False
        if find_up(dirname(dir), "pixi.toml").byte_length() > 0:
            # (allowed: pixi takes the nearest manifest) - but say so
            self.notify(NL_INFO, "New project", "It is inside another pixi project (" + find_up(dirname(dir), "pixi.toml") + "); pixi uses the nearest pixi.toml, so this one.")
        _ = run_system("mkdir -p " + shell_quote(dir))
        if not is_dir(dir):
            self.info("New Project", "Could not make the folder " + dir)
            return False
        var machine = String(bytes_to_str(run_capture("uname -sm 2>/dev/null").out).strip())
        var files = np_files(name, np_platform(machine), np_mojo_spec(MOJO_BUILT_WITH))
        for k in range(0, len(files), 2):
            if not write_file(join_path(dir, files[k]), str_bytes(files[k + 1])):
                self.info("New Project", "Could not write " + join_path(dir, files[k]))
                return False
        # the IDE now works in the project: its tasks, explorer and language server
        var cz = dir.copy()
        _ = external_call["chdir", Int32](cz.as_c_string_span())
        self.cwd = dir
        self.project_dir = ""
        self.pixi_for = ""
        _ = self.pixi_locate()
        var ex = self.explorer_index()
        if ex >= 0:
            self.ex.set_root(self.symidx_root())
            self.explorer_show()
        # (an untouched NONAME window in front gives its place to the first: open_path)
        self.open_path(join_path(dir, "test_hello.mojo"))
        self.open_path(join_path(dir, "hello.mojo"))
        self.np_install(dir)
        return True

    def np_install(mut self, dir: String):
        """`pixi install` in the new project, so Mojo is there for running and the
        language server; told how to do it when pixi is missing."""
        if which(self.pixi_cmd).byte_length() == 0:
            self.info("New Project", "Made. To get Mojo, install pixi (pixi.sh), then run `pixi install`")
            return
        if self.job.active:
            self.say("Project made in " + dir + " - run `pixi install` there once the running job is done")
            return
        var cmd = "cd " + shell_quote(dir) + " && exec " + self.pixi_cmd + " install 2>&1 </dev/null"
        if self.start_job(JOB_TASK, cmd, dir, "newproject:install"):
            self.task_output("Installing Mojo for the project (this can take a minute the first time)...")
            self.say("Project made in " + dir + " - installing Mojo with pixi (Ctrl-F2 cancels)")

    def np_installed(mut self, ok: Bool, cancelled: Bool, tstr: String):
        """The end of `pixi install` (from finish_task)."""
        if cancelled:
            self.task_output("pixi install cancelled after " + tstr)
            self.say("pixi install cancelled - run `pixi install` in the project to finish it")
        elif ok:
            self.task_output("Mojo installed in " + tstr)
            self.say("Project ready - Ctrl-F9 runs hello.mojo, Run > Pixi tasks runs its test")
        else:
            self.task_output("pixi install failed after " + tstr)
            self.say("pixi install failed - its output is on the Message page")
