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
from buffer import TextBuffer, Pos
from window import Window, WK_EDITOR, WK_MESSAGE, ACT_OTHER, ACT_TYPE
from window_search import *
from window_draw import *
from menu import *
from commands import *
from dialog import *
from util import *
from appstate import *
from app_files import *
from app_dialogs import *
from app_menus import *
from app_exec import *
from app_pickers import *
from app_jobs import *
from app_input import *
from app_mouse import *
from app_draw import *


__extension App:
    # ================================================================= loop
    def run(mut self) raises:
        self.term.enter()
        while self.running:
            var sz = self.term.size()
            if sz[0] != self.scr.w or sz[1] != self.scr.h:
                self.scr.resize(sz[0], sz[1])
                self.fit_windows()
            self.draw()
            self.scr.render(self.term.out)
            self.term.flush()
            # sleep until input, compiler output or the next timer
            var fds = List[Int]()
            fds.append(0)
            if self.job.active:
                fds.append(self.job.fd)
            _ = wait_readable(fds, self.next_timeout_ms(now_ns(), self.term.pending(), secs_to_next_minute()))
            var evs = self.term.poll()
            for k in range(len(evs)):
                try:
                    self.handle(evs[k])
                except err:
                    self.mode = M_NORMAL
                    self.info("Error", String(err))
            try:
                self.poll_job()
            except err:
                self.info("Error", String(err))
        if self.job.active:
            self.cancel_job()
            _ = external_call["pclose", Int32](self.job.fp)
        self.term.leave()
