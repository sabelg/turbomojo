"""Options > Presets (P11-06): two ways to start, each in one choice - Turbo (Turbo
Classic's blue desktop, overlapping windows) and Modern (your terminal's own colours,
panes with tabs, the file explorer open, the keys of current editors). The first run's
theme question has Modern at its top. A preset changes the same settings the Options
menu does, and saves them; anything can be changed one by one afterwards."""
from std.collections import List
from appstate import *
from util import *
from dialog import *
from toml import toml_bool, toml_quote
from commands import CM_TILED, CM_EXPLORER, CM_KEYMAP0
from app_exec import *
from app_explorer import *

comptime PRESET_TURBO = 0
comptime PRESET_MODERN = 1
comptime PRESET_TURBO_THEME = "classic"
comptime PRESET_MODERN_THEME = "ansi"        # Terminal ANSI: the terminal's own colours
comptime THEME_ITEM_MODERN = -2              # the theme question's Modern line


def preset_name(p: Int) -> String:
    return "Modern" if p == PRESET_MODERN else "Turbo"


__extension App:
    def presets_dialog(mut self):
        var items = List[String]()
        var data = List[Int]()
        items.append("Turbo    Turbo Classic's blue desktop, overlapping windows")
        data.append(PRESET_TURBO)
        items.append("Modern   your terminal's colours, panes with tabs, the explorer open")
        data.append(PRESET_MODERN)
        var d = Dialog(D_PRESETS, "Presets", min(78, self.scr.w - 4), 11)
        d.has_list = True
        d.set_items(items^, data^)
        d.list_sel = 1 if self.preset_now() == PRESET_MODERN else 0
        d.lines.append("A look and a way of working in one choice; it is saved. Each part")
        d.lines.append("can still be changed alone (Options, Window > Tiled layout).")
        d.buttons.append("~O~K")
        d.buttons.append("Cancel")
        self.show(d^)

    def preset_now(self) -> Int:
        """Which preset the settings are closest to (the dialog starts there)."""
        return PRESET_MODERN if self.tiled and self.theme_id == PRESET_MODERN_THEME else PRESET_TURBO

    def preset_apply(mut self, p: Int) raises:
        var modern = p == PRESET_MODERN
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
        # the keys of current editors (Turbo leaves the keymap as you have it)
        if modern and self.keymap != 0:
            self.exec(CM_KEYMAP0)
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
        self.say("Preset: " + preset_name(p) + (" - your terminal's colours, panes with tabs, the explorer" if modern else " - Turbo Classic, overlapping windows"))

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
