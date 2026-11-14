"""Options > Presets (P11-06, P12-05): three ways to start, each in one choice - Turbo
(Turbo Classic's blue desktop, overlapping windows), Modern (your terminal's own
colours, panes with tabs, the file explorer open, the keys of current editors) and Vim
(Modern with vim's keys and relative line numbers). The first run's theme question has
Modern and Vim at its top. A preset changes the same settings the Options menu does,
and saves them; anything can be changed one by one afterwards."""
from std.collections import List
from appstate import *
from util import *
from dialog import *
from toml import toml_bool, toml_quote
from commands import CM_TILED, CM_EXPLORER, CM_KEYMAP0, CM_KEYMAP3, CM_RELNUM
from vim import KEYMAP_VIM
from app_exec import *
from app_explorer import *

comptime PRESET_TURBO = 0
comptime PRESET_MODERN = 1
comptime PRESET_VIM = 2
comptime PRESET_TURBO_THEME = "classic"
comptime PRESET_MODERN_THEME = "ansi"        # Terminal ANSI: the terminal's own colours
comptime THEME_ITEM_MODERN = -2              # the theme question's Modern line
comptime THEME_ITEM_VIM = -3                 # ...and its Vim line


def preset_name(p: Int) -> String:
    if p == PRESET_VIM:
        return "Vim"
    return "Modern" if p == PRESET_MODERN else "Turbo"


__extension App:
    def presets_dialog(mut self):
        var items = List[String]()
        var data = List[Int]()
        items.append("Turbo    Turbo Classic's blue desktop, overlapping windows")
        data.append(PRESET_TURBO)
        items.append("Modern   your terminal's colours, panes with tabs, the explorer open")
        data.append(PRESET_MODERN)
        items.append("Vim      Modern, with vim's keys and relative line numbers")
        data.append(PRESET_VIM)
        var d = Dialog(D_PRESETS, "Presets", min(78, self.scr.w - 4), 12)
        d.has_list = True
        d.set_items(items^, data^)
        d.list_sel = self.preset_now()
        d.lines.append("A look and a way of working in one choice; it is saved. Each part")
        d.lines.append("can still be changed alone (Options, Window > Tiled layout).")
        d.buttons.append("~O~K")
        d.buttons.append("Cancel")
        self.show(d^)

    def preset_now(self) -> Int:
        """Which preset the settings are closest to (the dialog starts there)."""
        if self.tiled and self.theme_id == PRESET_MODERN_THEME:
            return PRESET_VIM if self.keymap == KEYMAP_VIM else PRESET_MODERN
        return PRESET_TURBO

    def preset_apply(mut self, p: Int) raises:
        var modern = p == PRESET_MODERN or p == PRESET_VIM
        # the colours
        var k = self.themes.find(PRESET_MODERN_THEME if modern else PRESET_TURBO_THEME)
        if k >= 0:
            self.theme_id = self.themes.ids[k]
            self.theme_before = ""
            self.theme_apply()
            self.persist_option("ui", "theme", toml_quote(self.theme_id))
        # panes with tabs, or overlapping windows
        if self.tiled != modern:
            self.exec(CM_TILED)
        # the keys of current editors, or vim's, and the numbering that goes with them
        # (Turbo leaves the keymap and the numbering as you have them)
        if p == PRESET_MODERN and self.keymap != 0:
            self.exec(CM_KEYMAP0)
        elif p == PRESET_VIM and self.keymap != KEYMAP_VIM:
            self.exec(CM_KEYMAP3)
        if modern and self.rel_numbers != (p == PRESET_VIM):
            self.exec(CM_RELNUM)
        # the explorer: open now and at each start, or closed
        self.persist_option("ui", "explorer", toml_bool(modern))
        var xi = self.explorer_index()
        if modern and xi < 0:
            self.exec(CM_EXPLORER)
        elif not modern and xi >= 0:
            if self.top() != xi:
                self.focus(xi)
            self.exec(CM_EXPLORER)
        self.scr.force = True
        var what = String(" - Turbo Classic, overlapping windows")
        if p == PRESET_MODERN:
            what = " - your terminal's colours, panes with tabs, the explorer"
        elif p == PRESET_VIM:
            what = " - Modern, with vim's keys (Esc, i, :w) and relative line numbers; F10 and Alt still open the menus"
        self.say("Preset: " + preset_name(p) + what)

    def explorer_start(mut self):
        """ui.explorer: open the explorer once the screen has its size."""
        if self.explorer_index() < 0:
            var te = self.top_editor()
            try:
                self.exec(CM_EXPLORER)
            except:
                pass
            if te >= 0 and te < len(self.wins):
                self.focus(te)              # the file keeps the keyboard
