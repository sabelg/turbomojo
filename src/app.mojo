"""TurboMojo application entry: the event loop. Import this module with
`from app import *` to get App together with all of its extension methods."""
from std.collections import List, Dict
from std.time import perf_counter_ns
from std.ffi import external_call
from term import (
    Terminal, Event, EV_KEY, EV_MOUSE, EV_PASTE, K_BASE, KEY_ESC, KEY_ENTER, KEY_TAB,
    KEY_BACKSPACE, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_PGUP,
    KEY_PGDN, KEY_INSERT, KEY_DELETE, MOD_SHIFT, MOD_ALT, MOD_CTRL, KEY_MASK, fkey, ctrl, alt,
    MB_LEFT, MB_WHEEL_UP, MB_WHEEL_DOWN,
)
from screen import Screen
from caps import COLOR_TRUE, COLOR_16, width_verdict
from palette import Palette, theme, THEME_COUNT
from highlight import Highlighter
from buffer import TextBuffer, Pos, ENC_UTF8, ENC_LATIN1
from window import Window, WK_EDITOR, WK_MESSAGE, WK_OUTLINE, WK_EXPLORER, ACT_OTHER, ACT_TYPE
from window_search import *
from window_multi import *
from window_lines import *
from window_draw import *
from menu import *
from commands import *
from dialog import *
from util import *
from appstate import *
from app_keyecho import *
from app_notify import *
from app_agent import *
from app_problems import *
from app_lsp import *
from lsp import *
from app_watch import *
from watch import *
from app_swap import *
from swap import *
from app_files import *
from app_dialogs import *
from app_menus import *
from app_exec import *
from app_pickers import *
from app_nav import *
from app_outline import *
from app_layout import *
from app_explorer import *
from app_docs import *
from app_debug import *
from app_terminal import *
from app_tests import *
from app_gitdiff import *
from app_gitcmd import *
from app_git import *
from app_jobs import *
from app_input import *
from app_mouse import *
from app_draw import *
from app_docpane import *
from app_keybox import *
from app_plugins import *
from app_lspextra import *
from app_newproject import *
from app_setup import *
from app_presets import *
from app_report import *
from app_gpu import *
from app_codegen import *
from app_ipc import *
from version import MOJO_BUILT_WITH
from mojover import mojo_mismatch, mojo_summary


__extension App:
    # ================================================================= loop
    def emergency_save(mut self) -> Int:
        """Keep every modified buffer as a swap file (never touching the user's own
        files). Used when the IDE is told to terminate. Returns the number kept."""
        var n = self.write_all_swaps()
        self.recovered += n
        return n

    def on_signal(mut self, sig: Int):
        if sig == SIGTERM or sig == SIGHUP or sig == SIGINT:
            _ = self.emergency_save()
            self.running = False
        elif sig == SIGTSTP:
            self.suspend()
        elif sig == SIGCONT:
            # resumed after an external stop: the terminal may have been changed meanwhile
            self.term.enter()
            self.scr.force = True
        # SIGWINCH needs no action here: the loop re-reads the size on every pass

    def inject_fault(mut self) raises:
        """Deliberate failures for the crash tests (TURBOMOJO_FAULT=index|raise)."""
        var kind = self.fault
        self.fault = ""
        if kind == "index":
            var empty = List[Int]()
            self.status = String(empty[len(self.wins) + 3])   # out of bounds -> trap
        elif kind == "raise":
            raise Error("injected failure")

    def suspend(mut self):
        """Give the terminal back, stop like any other job, and repaint on resume."""
        self.term.leave()
        send_signal(own_pid(), SIGSTOP)
        self.term.enter()
        self.scr.force = True

    def enable_history(mut self):
        """Start keeping undo histories and cursor positions in the state directory (if
        the setting allows). Called before the first file is opened, so that files named
        on the command line get theirs back."""
        if self.persistent_undo and self.history_dir.byte_length() == 0:
            self.history_dir = state_dir() + "/history"
            self.prune_history()

    def apply_widths(mut self, widths: List[Int]):
        """Draw by what the terminal was measured to do with doubtful glyphs: a
        terminal that joins emoji sequences by itself (without saying so through mode
        2027) gets the clustered layout; emoji it draws one column wide are padded."""
        var v = width_verdict(widths)
        if not v.measured:
            return
        if v.clusters:
            self.scr.clustered = True
        self.scr.emoji_narrow = v.emoji_narrow

    def gfx_decide(mut self, answered: Bool, tmux: String, kitty_window: String, ghostty: String, sixel: Bool = False):
        """Whether the reader shows pictures, and how: `ui.images = "kitty"` or
        "sixel" says so; "auto" takes kitty graphics when the terminal answered its
        query - or, inside tmux (which does not pass the query on), when tmux runs in
        kitty or Ghostty (their variables are inherited) - and else sixel when DA1
        listed it. Never in screen-reader mode; kitty graphics not with 16 colours (the
        image id is a 256-colour index)."""
        self.gfx_tmux = tmux.byte_length() > 0
        var outside = self.gfx_tmux and (kitty_window.byte_length() > 0 or ghostty.byte_length() > 0)
        var kitty = self.images_mode == "kitty" or (self.images_mode == "auto" and (answered or outside))
        var six = not kitty and (self.images_mode == "sixel" or (self.images_mode == "auto" and sixel))
        if kitty and self.scr.color_mode == COLOR_16:
            kitty = False
        self.gfx_on = (kitty or six) and not self.reader
        self.gfx_sixel = six and self.gfx_on

    def mojo_version_check(mut self, built_with: String = MOJO_BUILT_WITH):
        """Ask the configured compiler its version, once; if it is not the release this
        TurboMojo was built with, say so (src/mojover.mojo)."""
        self.mojo_checked = True
        if built_with.byte_length() == 0:
            return
        var r = run_capture(self.compiler_cmd() + " --version 2>&1 < /dev/null")
        self.mojo_warning = mojo_mismatch(built_with, bytes_to_str(r.out))
        if self.mojo_warning.byte_length() > 0:
            self.log_error("toolchain: " + self.mojo_warning)
            var msg = self.mojo_warning.copy()
            self.say(msg)

    def run(mut self) raises:
        self.frec_path = state_dir() + "/opened"
        self.frec.decode_text(read_text(self.frec_path))
        self.cmd_rec_path = state_dir() + "/commands-used"
        self.cmd_rec.decode_text(read_text(self.cmd_rec_path), False)
        self.log_path = state_dir() + "/crash.log"
        self.term.crash_log = self.log_path
        for w in self.config_warnings:
            self.log_error("config: " + w)
        self.term.crash_header = "TurboMojo " + VERSION + "  pid " + String(own_pid()) + "  started " + timestamp()
        self.swap_enabled = True
        self.enable_history()
        self.watch_enabled = True
        _ = self.watch.open()
        if self.ipc_dir.byte_length() > 0:
            _ = self.watch.watch_dir(self.ipc_dir)
        self.export_ide_state()
        self.term.enter()
        var caps = self.term.probe(CAPS_TIMEOUT_MS, True)
        self.scr.color_mode = caps.color
        self.term_probed = True
        self.term_kitty_keys = caps.kitty_keyboard
        self.caps_lines = caps.describe()
        if caps.color != COLOR_TRUE:
            # the theme's colours as designed for 256 or 16 colours
            self.theme_apply()
        self.scr.sync = caps.sync_output
        self.scr.styled_ul = caps.styled_underline
        if caps.kitty_keyboard:
            self.term.set_kitty(True)
        else:
            self.term.set_modify_other_keys(True)
        if caps.grapheme:
            self.term.set_grapheme(True)
            self.scr.clustered = True
        self.apply_widths(caps.widths)
        self.gfx_decide(caps.kitty_graphics, env_or("TMUX", ""), env_or("KITTY_WINDOW_ID", ""), env_or("GHOSTTY_RESOURCES_DIR", ""), caps.sixel)
        if caps.cell_w > 0:
            self.gfx_cell_w = caps.cell_w
            self.gfx_cell_h = caps.cell_h
        _ = self.sig.open()
        _ = self.first_run_theme()
        var early = self.term.take_early()
        while self.running:
            var sz = self.term.size()
            if sz[0] != self.scr.w or sz[1] != self.scr.h:
                self.scr.resize(sz[0], sz[1])
                self.fit_windows()
            if self.gpu_status_on and not self.gpu_asked:
                self.gpu_start()
            if self.explorer_at_start:
                self.explorer_at_start = False      # (once: closing it later is the user's)
                self.explorer_start()
            if not self.reduce_motion:
                var anim_now = now_ns()
                for wi in range(len(self.wins)):
                    _ = self.wins[wi].step_anim(anim_now)
            self.draw()
            self.sixel_prepare()
            if self.gfx_out.byte_length() > 0:
                append_str(self.term.out, self.gfx_out)    # pictures before the cells that show them
                self.gfx_out = ""
            self.scr.render(self.term.out)
            var six = self.sixel_take()
            if six.byte_length() > 0:
                append_str(self.term.out, six)
            self.term.flush()
            if not self.mojo_checked:
                self.mojo_version_check()       # (after the first frame: start-up stays quick)
            if not self.lsp_auto_checked:
                self.lsp_auto_checked = True
                var ai0 = self.active_editor()
                if self.lsp_auto_start and ai0 >= 0 and not self.wins[ai0].buf.large and self.log_path.byte_length() > 0 and not self.trust_held and self.trust_ok() and is_mojo_file(self.wins[ai0].path) and not self.lsp.active():
                    self.lsp_track(ai0, now_ns())
            if self.fault.byte_length() > 0:
                self.inject_fault()
            # sleep until input, compiler output or the next timer
            var fds = List[Int]()
            fds.append(0)
            if self.job.active:
                fds.append(self.job.fd)
            if self.aux_job.active:
                fds.append(self.aux_job.fd)
            if self.sig.active():
                fds.append(self.sig.fd)
            if self.watch.active():
                fds.append(self.watch.fd)
            if self.lsp.fd() >= 0:
                fds.append(self.lsp.fd())
            if self.dbg.fd() >= 0:
                fds.append(self.dbg.fd())
            for tf in self.term_fds():
                fds.append(tf)
            if self.git_fd() >= 0:
                fds.append(self.git_fd())
            if self.agent.fd() >= 0:
                fds.append(self.agent.fd())
            for af in self.agent_term_fds():
                fds.append(af)
            for pf in self.plugin_fds():
                fds.append(pf)
            for xf in self.extra_fds():
                fds.append(xf)
            for gf in self.gpu_fds():
                fds.append(gf)
            if self.fim_fd >= 0:
                fds.append(self.fim_fd)
            if self.cell_mojo_proc.running and self.cell_mojo_proc.out_fd >= 0:
                fds.append(self.cell_mojo_proc.out_fd)
            if self.cell_py_proc.running and self.cell_py_proc.out_fd >= 0:
                fds.append(self.cell_py_proc.out_fd)
            _ = wait_readable(fds, self.next_timeout_ms(now_ns(), self.term.pending(), secs_to_next_minute()))
            for sg in self.sig.read_all():
                self.on_signal(sg)
            if not self.running:
                break
            var evs = self.term.poll()
            if len(early) > 0:
                # keys typed while the terminal was being probed come first
                for ev in evs:
                    early.append(ev.copy())
                evs = early.copy()
                early.clear()
            for k in range(len(evs)):
                try:
                    self.handle(evs[k])
                except err:
                    self.mode = M_NORMAL
                    self.log_error(String(err))
                    self.info("Error", String(err))
            self.lsp_tick(now_ns())
            try:
                self.debug_tick()
            except err:
                self.log_error(String(err))
            self.term_tick()
            self.outline_tick(now_ns())
            self.docpane_tick(now_ns())
            self.chord_tick(now_ns())
            self.notes_tick(now_ns())
            self.plugins_tick(now_ns())
            self.extra_tick(now_ns())
            self.symidx_tick()
            self.gpu_tick()
            self.fim_tick()
            self.quick_tick()
            self.explorer_tick(now_ns())
            self.git_tick(now_ns())
            self.theme_tick()
            try:
                self.agent_tick(now_ns())
            except err:
                self.log_error(String(err))
            self.session_tick(now_ns())
            self.swap_tick(now_ns())
            self.fsearch_tick(now_ns())
            try:
                var woke = self.watch.drain()
                if woke:
                    _ = self.omarchy_theme_recheck()
                    self.git_checked_ns = 0
                    self.git_tick(now_ns())
                self.watch_tick(now_ns(), woke)
                _ = self.ipc_tick()
            except err:
                self.log_error(String(err))
            try:
                self.poll_job()
                self.poll_aux_job()
                self.cell_kernel_tick()
            except err:
                self.log_error(String(err))
                self.info("Error", String(err))
        if self.fsearch.active:
            self.fsearch.cancel()
        if self.job.active:
            self.stop_job_now()
        if self.aux_job.active:
            self.stop_aux_job_now()
        self.cell_kernels_stop()
        self.gpu_probe_stop()
        self.gpu_mon_stop()
        self.fim_stop()
        self.dbg.finish()           # a program being debugged does not outlive the IDE
        _ = self.git_proc.stop()
        self.agent.stop()           # nor the coding agent
        self.plugins_stop()         # nor the plugins
        self.extra_stop_all()       # nor the other language servers
        self.agent_services_end()   # and its commands
        _ = self.tshell.pty.stop()  # nor the terminals' programs (they get SIGHUP)
        for k in range(len(self.tshells)):
            _ = self.tshells[k].pty.stop()
        self.tshells.clear()
        _ = self.trun.pty.stop()
        _ = self.trepl.pty.stop()
        self.bp_sync()
        self.bp_save()
        self.lsp_stop()
        self.sig.close()
        self.watch.close()
        self.docs_images_forget()
        if self.gfx_out.byte_length() > 0:
            append_str(self.term.out, self.gfx_out)
            self.gfx_out = ""
        self.term.leave()
        if self.recovered > 0:
            print("TurboMojo: kept", self.recovered, "unsaved buffer(s); they will be offered when you start it again.")
        else:
            self.clean_swaps_on_exit()
