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
from app_jobs import *
from app_input import *
from app_mouse import *
from app_draw import *


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

    def run(mut self) raises:
        self.frec_path = state_dir() + "/opened"
        self.frec.decode_text(read_text(self.frec_path))
        self.log_path = state_dir() + "/crash.log"
        self.term.crash_log = self.log_path
        for w in self.config_warnings:
            self.log_error("config: " + w)
        self.term.crash_header = "TurboMojo " + VERSION + "  pid " + String(own_pid()) + "  started " + timestamp()
        self.swap_enabled = True
        self.enable_history()
        self.watch_enabled = True
        _ = self.watch.open()
        self.term.enter()
        var caps = self.term.probe(CAPS_TIMEOUT_MS)
        self.scr.color_mode = caps.color
        self.scr.sync = caps.sync_output
        self.scr.styled_ul = caps.styled_underline
        if caps.kitty_keyboard:
            self.term.set_kitty(True)
        if caps.grapheme:
            self.term.set_grapheme(True)
            self.scr.clustered = True
        _ = self.sig.open()
        var early = self.term.take_early()
        while self.running:
            var sz = self.term.size()
            if sz[0] != self.scr.w or sz[1] != self.scr.h:
                self.scr.resize(sz[0], sz[1])
                self.fit_windows()
            self.draw()
            self.scr.render(self.term.out)
            self.term.flush()
            if self.fault.byte_length() > 0:
                self.inject_fault()
            # sleep until input, compiler output or the next timer
            var fds = List[Int]()
            fds.append(0)
            if self.job.active:
                fds.append(self.job.fd)
            if self.sig.active():
                fds.append(self.sig.fd)
            if self.watch.active():
                fds.append(self.watch.fd)
            if self.lsp.fd() >= 0:
                fds.append(self.lsp.fd())
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
            self.outline_tick(now_ns())
            self.symidx_tick()
            self.quick_tick()
            self.explorer_tick(now_ns())
            self.session_tick(now_ns())
            self.swap_tick(now_ns())
            self.fsearch_tick(now_ns())
            try:
                self.watch_tick(now_ns(), self.watch.drain())
            except err:
                self.log_error(String(err))
            try:
                self.poll_job()
            except err:
                self.log_error(String(err))
                self.info("Error", String(err))
        if self.job.active:
            self.cancel_job()
            _ = external_call["pclose", Int32](self.job.fp)
        self.lsp_stop()
        self.sig.close()
        self.watch.close()
        self.term.leave()
        if self.recovered > 0:
            print("TurboMojo: kept", self.recovered, "unsaved buffer(s); they will be offered when you start it again.")
        else:
            self.clean_swaps_on_exit()
