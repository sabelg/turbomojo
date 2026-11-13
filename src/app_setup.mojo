"""Help > Check setup (P11-05): the list of what TurboMojo uses and whether it is there
(setupcheck.mojo makes the lines), with a Fix button for the marked line - it opens File
> New project, Compile > Compiler command or Help > Download documentation, or copies
the command that fixes it. The first run shows it by itself when something is missing."""
from std.collections import List
from appstate import *
from util import *
from dialog import *
from version import MOJO_BUILT_WITH
from setupcheck import *
from commands import CM_NEW_PROJECT, CM_COMPILER, CM_DOCFETCH
from app_jobs import *
from app_files import *
from app_outline import *
from app_debug import *
from app_exec import *
from app_nav import count_of


__extension App:
    def setup_facts(mut self) -> SetupFacts:
        var f = SetupFacts()
        f.built_with = MOJO_BUILT_WITH
        f.compiler = self.compiler
        if which(self.compiler).byte_length() > 0 or self.compiler.find("/") >= 0:
            f.mojo_out = bytes_to_str(run_capture(self.compiler_cmd() + " --version 2>&1 < /dev/null").out)
        f.pixi = which(self.pixi_cmd)
        f.lsp_name = self.lsp_server
        f.lsp = which(self.lsp_server)
        f.dap_name = self.debug_adapter
        f.dap = self.debug_adapter_command()
        f.docs = self.doc_home.byte_length() > 0 and is_dir(self.doc_home) and len(list_dir(self.doc_home)) > 1
        f.probed = self.term_probed
        f.color = self.scr.color_mode
        f.kitty_keys = self.term_kitty_keys
        f.tmux = env_or("TMUX", "").byte_length() > 0
        return f^

    def setup_dialog(mut self):
        self.setup_list = setup_items(self.setup_facts())
        var items = List[String]()
        var data = List[Int]()
        var missing = 0
        for k in range(len(self.setup_list)):
            ref it = self.setup_list[k]
            items.append(pad_right(it.name, 16) + pad_right(sc_mark(it.level), 8) + it.detail)
            data.append(k)
            if it.level == SC_MISSING:
                missing += 1
        var d = Dialog(D_SETUP, "Check Setup", min(100, self.scr.w - 4), min(self.scr.h - 2, len(items) + 9))
        d.has_list = True
        d.set_items(items^, data^)
        d.lines.append("Everything TurboMojo uses is there." if missing == 0 else (count_of(missing, "piece") + " missing. Fix (Enter) helps with the marked line."))
        d.lines.append("Help > Check setup shows this again.")
        d.buttons.append("~F~ix")
        d.buttons.append("~A~gain")
        d.buttons.append("Close")
        self.show(d^)

    def setup_button(mut self, b: Int, sel: Int) raises:
        if b == 1:
            self.setup_dialog()
            return
        self.mode = M_NORMAL
        if b != 0 or sel < 0 or sel >= len(self.setup_list):
            return
        var it = self.setup_list[sel].copy()
        if it.action == SC_FIX_PROJECT:
            self.exec(CM_NEW_PROJECT)
        elif it.action == SC_FIX_COMPILER:
            self.exec(CM_COMPILER)
        elif it.action == SC_FIX_DOCS:
            self.exec(CM_DOCFETCH)
        elif it.fix.byte_length() > 0:
            self.clipboard = decode(it.fix)
            self.osc52(self.clipboard.copy())
            self.info(it.name, it.fix + "   (copied)")
        else:
            self.say(it.name + ": nothing to fix")
