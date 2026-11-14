"""Install what a program uses (P11-13): after a failed build or run, a library the
output names as missing is looked up on the project's channels (`pixi search`) and, if
it is there, offered; Install adds it (`pixi add`) and builds or runs again. Without a
pixi project the offer is to make one (a pixi.toml with Mojo, as File > New project
writes) and add it there. Each library is offered once per session; nothing is
installed without a yes. See pkginstall.mojo for reading the messages.

Builds and runs of a file in a pixi project with an environment run with that
environment active (pkginstall.in_env), so that what was added is found."""
from std.collections import List
from appstate import *
from util import *
from dialog import *
from project import find_up
from pkginstall import MissingModule, missing_modules, package_for, import_note, what_it_is, in_env, PK_MOJO
from version import MOJO_BUILT_WITH
from app_jobs import *
from app_files import *
from app_dialogs import *
from app_outline import *
from pydocs import dotted_at, python_target, python_bindings, pydoc_command, pydoc_markdown
from app_lsp import *
from newproject import np_pixi_toml, np_platform, np_mojo_spec, np_name_problem


__extension App:
    def active_pixi_env(self) -> String:
        """Selected Pixi environment name (`default` unless overridden)."""
        return self.pixi_env if self.pixi_env.byte_length() > 0 else String("default")

    def env_for_tool(self, path: String, tool: String) -> String:
        """The pixi.toml whose installed environment has `tool` for files like `path`
        ('' if there is no project above it, its environment is not installed, pixi is
        not found, or the IDE already runs in that environment)."""
        if path.byte_length() == 0:
            return ""
        var dir = find_up(dirname(path), "pixi.toml")
        if dir.byte_length() == 0:
            return ""
        var env_name = self.active_pixi_env()
        var env_tool = join_path(dir, ".pixi/envs/" + env_name + "/bin/" + tool)
        if not path_exists(env_tool):
            if env_name == "default":
                return ""
            env_tool = join_path(dir, ".pixi/envs/default/bin/" + tool)
            if not path_exists(env_tool):
                return ""
        if env_name == "default" and which(tool) == env_tool:
            return ""
        if which(self.pixi_cmd).byte_length() == 0:
            return ""
        return join_path(dir, "pixi.toml")

    def env_manifest(self, path: String) -> String:
        """The pixi.toml whose environment builds and runs of `path` use ('' for the
        IDE's own Mojo: no project, no environment yet, a configured compiler, or the
        IDE already running in that environment)."""
        if self.compiler != "mojo":
            return ""
        return self.env_for_tool(path, "mojo")

    def lsp_manifest(self, path: String) -> String:
        """The same for the language server: in a project's environment it sees the
        packages installed there (MAX and the others come compiled: their documentation,
        completion and errors come from the server, P11-14)."""
        if self.lsp_server != "mojo-lsp-server":
            return ""
        return self.env_for_tool(path, "mojo-lsp-server")

    def python_for(self, path: String) -> String:
        """The Python that has the project's libraries: its environment's, else the one
        on PATH."""
        var dir = find_up(dirname(path), "pixi.toml") if path.byte_length() > 0 else String("")
        if dir.byte_length() > 0:
            var env_name = self.active_pixi_env()
            var py = join_path(dir, ".pixi/envs/" + env_name + "/bin/python3")
            if path_exists(py):
                return py
            var def_py = join_path(dir, ".pixi/envs/default/bin/python3")
            if path_exists(def_py):
                return def_py
        return "python3"

    def docs_python(mut self, ai: Int) -> Int:
        """Ctrl-F1 / F1 on a name of a Python library the file imports
        (`np.zeros` with `var np = Python.import_module("numpy")`): pydoc's text in the
        documentation window. 1 shown, 0 not such a name, -1 Python could not say."""
        var chain = dotted_at(self.wins[ai].buf.line(self.wins[ai].cr), self.wins[ai].cc)
        if chain.byte_length() == 0:
            return 0
        var target = python_target(chain, python_bindings(bytes_to_str(self.wins[ai].buf.text_bytes())))
        if target.byte_length() == 0:
            return 0
        var py = self.python_for(self.wins[ai].path)
        var r = run_capture(pydoc_command(shell_quote(py) if py != "python3" else py, target))
        var out = bytes_to_str(r.out)
        if r.status != 0 or out.byte_length() == 0:
            var why = String(out.strip())
            if why.startswith("pydoc: "):
                var rest = String(why[byte=7:])
                why = rest
            self.say("Python has no documentation for " + target + (" - " + why if why.byte_length() > 0 else String("")))
            return -1
        self.hover_lines = md_render(pydoc_markdown(target, out, py), max(20, min(76, self.scr.w - 6)), self.hl)
        if len(self.hover_lines) == 0:
            return -1
        self.hover_scroll = 0
        self.mode = M_HOVER
        self.say("")
        return 1

    def mojo_for(mut self, path: String) -> String:
        """The compiler command for a build or run of `path` (plain `mojo` inside a
        project's environment, which sets MODULAR_HOME itself)."""
        if self.env_manifest(path).byte_length() > 0:
            return self.compiler
        return self.compiler_cmd()

    def with_env(self, path: String, cmd: String) -> String:
        var m = self.env_manifest(path)
        if m.byte_length() == 0:
            return cmd
        return in_env(cmd, self.pixi_cmd, m, self.active_pixi_env())

    # ------------------------------------------------------------- the offer
    def pkg_check(mut self, output: String, file: String, after: Int) -> Bool:
        """After a failed build (after=1) or run (2): a library to offer? Then look it
        up and return True (the caller's own result box is left out)."""
        if which(self.pixi_cmd).byte_length() == 0 or self.job.active:
            return False
        for m in missing_modules(output):
            var key = String(m.kind) + ":" + m.module
            if key in self.pkg_asked:
                continue
            self.pkg_asked.append(key)
            self.pkg_kind = m.kind
            self.pkg_module = m.module
            self.pkg_package = package_for(m.kind, m.module)
            self.pkg_file = file
            self.pkg_after = after
            self.pkg_dir = find_up(dirname(file), "pixi.toml")
            if self.pkg_dir.byte_length() == 0:
                self.pkg_offer(True)
                return True
            var cmd = "cd " + shell_quote(self.pkg_dir) + " && exec " + self.pixi_cmd + " search " + shell_quote(self.pkg_package) + " 2>&1 </dev/null"
            if self.start_job(JOB_TASK, cmd, String(self.pkg_dir), "pkg:search"):
                self.say(self.pkg_module + " is not installed - looking for it on the project's channels...")
                return True
            return False
        return False

    def pkg_searched(mut self, ok: Bool, output: String):
        """The end of `pixi search` (from finish_task)."""
        if ok and output.find(self.pkg_package) >= 0:
            self.pkg_offer(False)
            return
        self.say("No package " + self.pkg_package + " on the project's channels - if " + self.pkg_module + " is a module of yours, check its name and Options > Include paths")

    def pkg_offer(mut self, make_project: Bool):
        var d = Dialog(D_PKG, "Install " + self.pkg_package, min(70, self.scr.w - 4), 11)
        d.lines.append(basename(self.pkg_file) + " uses " + self.pkg_module + ", which is not installed.")
        if make_project:
            d.lines.append("There is no pixi project here: make one in " + basename(dirname(self.pkg_file)) + "/")
            d.lines.append("(a pixi.toml with Mojo) and add " + self.pkg_package + " to it?")
            d.buttons.append("~M~ake project and install")
        else:
            d.lines.append(self.pkg_package + " (" + what_it_is(self.pkg_kind) + ") is on the project's channels.")
            d.lines.append("Add it to " + basename(self.pkg_dir) + "/pixi.toml with `pixi add`, then " + ("build" if self.pkg_after == 1 else "run") + " again?")
            d.buttons.append("~I~nstall")
        var note = import_note(self.pkg_kind, self.pkg_module)
        if note.byte_length() > 0:
            d.lines.append(note)
        d.buttons.append("~N~ot now")
        self.show(d^)

    def pkg_button(mut self, b: Int) raises:
        """Install (or Make project and install) - the first button."""
        if b != 0:
            self.say("Not installed - " + self.pkg_module + " is offered again in the next session")
            return
        if self.pkg_dir.byte_length() == 0:
            var dir = dirname(self.pkg_file)
            var name = basename(dir)
            if np_name_problem(name).byte_length() > 0:
                name = "my-project"
            var plat = np_platform(bytes_to_str(run_capture("uname -sm").out))
            if not write_file(join_path(dir, "pixi.toml"), str_bytes(np_pixi_toml(name, plat, np_mojo_spec(MOJO_BUILT_WITH)))):
                self.say("Could not write " + join_path(dir, "pixi.toml"))
                return
            self.pkg_dir = dir
            self.pixi_for = ""
        var cmd = "cd " + shell_quote(self.pkg_dir) + " && exec " + self.pixi_cmd + " add " + shell_quote(self.pkg_package) + " 2>&1 </dev/null"
        if self.start_job(JOB_TASK, cmd, String(self.pkg_dir), "pkg:add"):
            self.task_output("Installing " + self.pkg_package + " with pixi (the first time can take a few minutes)...")
            self.say("Installing " + self.pkg_package + " - Ctrl-F2 cancels")

    def pkg_added(mut self, ok: Bool, cancelled: Bool, tstr: String):
        """The end of `pixi add` (from finish_task): build or run again."""
        if cancelled:
            self.say("Installing " + self.pkg_package + " cancelled")
            return
        if not ok:
            self.task_output("pixi add " + self.pkg_package + " failed after " + tstr)
            self.say("pixi could not add " + self.pkg_package + " - its answer is on the Message page")
            return
        self.task_output(self.pkg_package + " installed in " + tstr)
        self.pixi_for = ""
        if self.lsp.active():
            self.lsp_stop()             # started again with the new package (lsp_track below)
            self.pkg_lsp_again = True
        var ei = self.find_editor(self.pkg_file)
        if ei >= 0:
            self.focus(ei)
        self.say(self.pkg_package + " installed in " + basename(self.pkg_dir) + " - " + ("building" if self.pkg_after == 1 else "running") + " again")
        if self.top_editor() >= 0 and self.wins[self.top_editor()].path == self.pkg_file:
            try:
                if self.pkg_after == 1:
                    self.build()
                else:
                    self.run_program(False)
            except e:
                self.say("Installed; " + String(e))
        if self.pkg_lsp_again:
            self.pkg_lsp_again = False
            var te = self.top_editor()
            if te >= 0 and self.wins[te].path.byte_length() > 0:
                self.lsp_track(te, now_ns())
