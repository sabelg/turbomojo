"""List pickers: command palette, symbols, keyboard reference, word completion."""
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
from highlight import Highlighter, lang_for_path, HL_MOJO
from snippets import (
    SnippetTemplate, mojo_snippets, expand_snippet_full, pos_after_offset,
    load_toml_snippets, load_vscode_snippets, expand_variables,
)
from plugins import load_plugin_snippets
from config import config_home
from buffer import TextBuffer, Pos, ENC_UTF8, ENC_LATIN1
from window import Window, WK_EDITOR, WK_MESSAGE, WK_OUTLINE, WK_EXPLORER, ACT_OTHER, ACT_TYPE, Cur
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
from app_lsp import *
from lsp import *
from markdown import *
from outline import *
from symindex import *
from app_outline import SYMIDX_FRESH_MS, SYMIDX_FIRST_MS, SYMIDX_SLICE_MS
from app_watch import *
from watch import *
from app_swap import *
from swap import *
from app_files import *
from app_dialogs import *
from app_menus import *
from app_exec import *
from app_jobs import *
from app_nav import *
from app_outline import *
from app_layout import *
from app_explorer import *
from app_docs import *
from app_debug import *
from app_terminal import *
from app_tests import *
from app_input import *
from app_mouse import *
from app_draw import *
from app_docpane import *
from app_lspextra import *


comptime QM_FILES = 0
comptime QM_COMMANDS = 1
comptime QM_SYMBOLS = 2
comptime QM_WSYMBOLS = 3
comptime QM_LINE = 4
comptime CMD_RECENT_MAX = 20     # commands remembered as used last
comptime QM_DOCS = 5          # "?": hand the text to the documentation finder


__extension App:
    # ====================================================== the palette
    def frec_note(mut self, path: String):
        """A file is being opened: remember it for the palette's ranking."""
        self.frec.note(path, unix_time())
        if self.frec_path.byte_length() > 0:
            if not path_exists(dirname(self.frec_path)):
                _ = run_system("mkdir -p " + shell_quote(dirname(self.frec_path)))
            _ = write_file(self.frec_path, str_bytes(self.frec.encode()))

    def cmd_key(self, cmd: Int) -> String:
        var i = self.reg.index_of(cmd)
        return self.reg.cmds[i].name if i >= 0 else String(cmd)

    def cmd_used(mut self, cmd: Int):
        """A command chosen by name - in the palette or a menu: it comes first in the
        palette from now on, and still after a restart (the state directory's
        commands-used)."""
        if cmd == CM_NONE:
            return
        self.cmd_rec.note(self.cmd_key(cmd), unix_time())
        while len(self.cmd_rec.paths) > CMD_RECENT_MAX:
            _ = self.cmd_rec.paths.pop()
            _ = self.cmd_rec.counts.pop()
            _ = self.cmd_rec.last.pop()
        if self.cmd_rec_path.byte_length() > 0:
            if not path_exists(dirname(self.cmd_rec_path)):
                _ = run_system("mkdir -p " + shell_quote(dirname(self.cmd_rec_path)))
            _ = write_file(self.cmd_rec_path, str_bytes(self.cmd_rec.encode()))

    def cmd_recency(self, cmd: Int) -> Int:
        """What a command's place among those used last adds to its palette score: the
        one used last the most, nothing for those not used lately."""
        var k = self.cmd_rec.find(self.cmd_key(cmd))
        if k < 0:
            return 0
        return (CMD_RECENT_MAX - k) * 20

    def quick_dialog(mut self, start: String):
        """The palette: one field for going anywhere. What is typed decides what is
        listed: a file name (files of the project, the ones opened often and lately
        first), ">" commands, "@" symbols of this file, "#" symbols of the project,
        ":" a line number. `start` is put into the field (">" for the command palette)."""
        var now = now_ns()
        var root = self.symidx_root()
        if not self.fidx.building and (not self.fidx.built or self.fidx.root != root or now - self.fidx.built_ns > SYMIDX_FRESH_MS * 1000000):
            self.fidx.start(root)
            self.fidx.step(SYMIDX_FIRST_MS)
        var d = Dialog(D_PALETTE, "Go to", min(76, self.scr.w - 4), min(22, self.desk_h()))
        d.lines.append("file name  >command  @symbol  #project symbol  :line  ?documentation")
        d.fields.append(Field("~G~o to", start))
        d.list_filter = True
        d.use_pat = True
        d.buttons.append("~G~o")
        d.buttons.append("~C~ancel")
        self.show(d^)
        self.quick_mode = -1
        self.quick_text = "\x01"                # anything the field cannot hold: forces the first fill
        self.quick_refresh()

    def quick_parse(self, text: String) -> Tuple[Int, String]:
        """The mode a text asks for, and the part of it that is matched against the list."""
        if text.startswith(">"):
            return (QM_COMMANDS, String(String(text[byte=1:]).strip()))
        if text.startswith("@"):
            return (QM_SYMBOLS, String(String(text[byte=1:]).strip()))
        if text.startswith("#"):
            return (QM_WSYMBOLS, String(String(text[byte=1:]).strip()))
        if text.startswith(":"):
            return (QM_LINE, String(""))
        if text.startswith("?"):
            return (QM_DOCS, String(""))
        # a file name may be followed by :line or :line:column
        var name = text
        var cut = text.find(":")
        if cut > 0:
            name = String(text[byte=0:cut])
        return (QM_FILES, String(name.strip()))

    def quick_position(self, text: String) -> Tuple[Int, Int]:
        """The 1-based line and column a text ends with (":12", ":12:5"); 0 = not given."""
        var cut = text.find(":")
        if cut < 0:
            return (0, 0)
        var row = 0
        var col = 0
        var part = 0
        for c in decode(String(text[byte=cut + 1:])):
            if c >= 48 and c <= 57:
                if part == 0:
                    row = min(row * 10 + c - 48, 100000000)
                else:
                    col = min(col * 10 + c - 48, 100000000)
            elif (c == 58 or c == 44) and part == 0:
                part = 1
            elif c != 32:
                return (0, 0)
        return (row, col)

    def quick_fill(mut self, mode: Int):
        """Put the list of a mode into the open palette."""
        self.quick_mode = mode
        var items = List[String]()
        var data = List[Int]()
        var keys = List[String]()
        var boost = List[Int]()
        var off = List[Bool]()
        var mcol = -1
        if mode == QM_COMMANDS:
            mcol = 40                               # the keys
            var seen = List[Int]()
            for m in self.menus:
                var title = plain(m.title)
                if title == "≡":
                    title = "System"
                for it in m.items:
                    if it.cmd == CM_NONE or it.cmd in seen:
                        continue
                    seen.append(it.cmd)
                    items.append(pad_right(title + ": " + plain(it.label), 40) + self.reg.all_keys_label(it.cmd))
                    data.append(it.cmd)
                    boost.append(self.cmd_recency(it.cmd))
                    off.append(self.cmd_unavailable(it.cmd))
        elif mode == QM_FILES:
            self.quick_files = self.fidx.files.copy() if self.fidx.built else self.fidx.fresh.copy()
            self.quick_building = self.fidx.building
            # open files that the walk does not list (outside the project, ignored)
            for i in range(len(self.wins)):
                if self.wins[i].kind == WK_EDITOR and self.wins[i].path.byte_length() > 0 and not (self.wins[i].path in self.quick_files):
                    self.quick_files.append(self.wins[i].path)
            var prefix = self.symidx_root() + "/"
            var now_s = unix_time()
            for k in range(len(self.quick_files)):
                var path = self.quick_files[k]
                var rel = path
                if rel.startswith(prefix):
                    rel = slice_str(decode(rel), cp_len(prefix), cp_len(rel))
                var name = basename(path)
                var where = dirname(rel) if rel != name else String("")
                items.append(pad_right(name, 30) + " " + where)
                mcol = 31                           # the folder
                keys.append(name + "  " + rel)
                boost.append(self.frec.score(path, now_s))
                data.append(k)
        elif mode == QM_SYMBOLS:
            var te = self.top_editor()
            self.quick_syms = scan_outline(self.wins[te].buf) if te >= 0 else List[OutlineItem]()
            for k in range(len(self.quick_syms)):
                items.append(pad_right(outline_line(self.quick_syms[k]), 50) + ":" + String(self.quick_syms[k].row + 1))
                mcol = 50                           # the line
                keys.append(self.quick_syms[k].name)
                data.append(k)
        elif mode == QM_WSYMBOLS:
            if not self.symidx.building and not self.symidx.built:
                self.symidx.start(self.symidx_root())
                self.symidx.step(SYMIDX_FIRST_MS)
            self.dlg.keys = keys.copy()
            self.dlg.boost = boost.copy()
            self.wsymbol_fill()                 # sets items, data and keys itself
            return
        else:
            items.append("Type a line number")
            data.append(0)
        self.dlg.keys = keys^
        self.dlg.boost = boost^
        self.dlg.set_items(items^, data^)
        self.dlg.muted_col = mcol
        self.dlg.off = off^
        self.dlg.show_count = mode != QM_LINE

    def quick_refresh(mut self):
        """After every key in the palette: see what the field asks for now."""
        var text = self.dlg.field_text(0)
        if text == self.quick_text:
            return
        self.quick_text = text
        var parsed = self.quick_parse(text)
        var mode = parsed[0]
        if mode != self.quick_mode:
            self.quick_fill(mode)
        self.dlg.pat = parsed[1]
        if mode == QM_DOCS:
            var what = String(String(text[byte=1:]).strip())
            var one = List[String]()
            one.append(("Search the documentation for \"" + what + "\"" if what.byte_length() > 0 else String("Type what to look for in the documentation: a name, a.dotted.path, words, an error line")) + "   (" + self.reg.key_label(CM_DOCFIND) + ")")
            var zero = List[Int]()
            zero.append(0)
            self.dlg.set_items(one^, zero^)
            return
        if mode == QM_LINE:
            var pos = self.quick_position(text)
            var te = self.top_editor()
            var line = String("Type a line number")
            if te < 0:
                line = "There is no file to go to a line of"
            elif pos[0] > 0:
                line = "Go to line " + String(pos[0]) + ((", column " + String(pos[1])) if pos[1] > 0 else String("")) + " of " + self.wins[te].title + " (" + String(self.wins[te].buf.count()) + " lines)"
            var one = List[String]()
            one.append(line)
            var zero = List[Int]()
            zero.append(0)
            self.dlg.set_items(one^, zero^)
            return
        self.dlg.refilter()

    def quick_tick(mut self):
        """One slice of listing the project's files; a palette opened meanwhile gets
        the full list when it is ready."""
        if not self.fidx.building:
            return
        self.fidx.step(SYMIDX_SLICE_MS)
        if not self.fidx.building and self.mode == M_DIALOG and self.dlg.kind == D_PALETTE and self.quick_mode == QM_FILES and self.quick_building:
            self.quick_fill(QM_FILES)

    def quick_accept(mut self) raises:
        """Enter in the palette."""
        var text = self.dlg.field_text(0)
        var mode = self.quick_mode
        var s = self.dlg.selected_item()
        if mode == QM_DOCS:
            self.docs_find_dialog(String(String(text[byte=1:]).strip()))
            return
        if mode == QM_LINE:
            var pos = self.quick_position(text)
            var ai = self.top_editor()
            if ai < 0 or pos[0] <= 0:
                self.say("No line number was given")
                return
            self.focus(ai)
            self.jump_mark()
            var t = self.top()
            self.wins[t].goto(pos[0] - 1, max(0, pos[1] - 1))
            return
        if s < 0:
            self.say("Nothing in the list matches")
            return
        if mode == QM_COMMANDS:
            var pc = self.dlg.item_data[s]
            self.exec(pc)
            self.key_echo(pc)
            self.cmd_used(pc)
        elif mode == QM_FILES:
            var k = self.dlg.item_data[s]
            if k < 0 or k >= len(self.quick_files):
                return
            var path = self.quick_files[k]
            if not (self.find_editor(path) >= 0 or path_exists(path)):
                self.say(basename(path) + " is no longer there")
                return
            self.jump_mark()
            self.open_path(path)
            var pos = self.quick_position(text)
            var t = self.top()
            if pos[0] > 0 and self.wins[t].kind == WK_EDITOR:
                self.wins[t].goto(pos[0] - 1, max(0, pos[1] - 1))
        elif mode == QM_SYMBOLS:
            var k = self.dlg.item_data[s]
            var ai = self.top_editor()
            if ai < 0 or k < 0 or k >= len(self.quick_syms):
                return
            var it = self.quick_syms[k].copy()
            self.focus(ai)
            self.jump_mark()
            var t = self.top()
            self.wins[t].goto(it.row, it.col)
        elif mode == QM_WSYMBOLS:
            self.wsymbol_go(s)

    def symbol_dialog(mut self):
        var ai = self.active_editor()
        if ai < 0:
            return
        var d = Dialog(D_SYMBOL, "Go to Symbol", min(64, self.scr.w - 4), min(20, self.desk_h()))
        d.fields.append(Field("~S~ymbol", ""))
        d.list_filter = True
        var items = List[String]()
        var data = List[Int]()
        for it in scan_outline(self.wins[ai].buf):
            items.append(pad_right(outline_line(it), 44) + ":" + String(it.row + 1))
            data.append(it.row)
        if len(items) == 0:
            self.say("No symbols found")
            return
        d.set_items(items^, data^)
        d.buttons.append("~G~o")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def help_dialog(mut self):
        """Keyboard reference generated from the command registry."""
        var d = Dialog(D_HELP, "Keyboard Reference", min(72, self.scr.w - 4), min(24, self.desk_h()))
        var items = self.keyboard_lines()
        var data = List[Int]()
        for _ in range(len(items)):
            data.append(0)
        d.set_items(items^, data^)
        d.focus = 0
        d.buttons.append("~O~K")
        self.show(d^)

    def keyboard_lines(self) -> List[String]:
        """Every key of the menus' commands (as the keymap has them) and the fixed ones."""
        var items = List[String]()
        for mi in range(1, len(self.reg.menu_titles)):
            var lines = List[String]()
            for p in self.reg.layout:
                if p.menu != mi or p.cmd == CM_NONE:
                    continue
                var keys = self.reg.all_keys_label(p.cmd)
                if keys.byte_length() == 0:
                    continue
                var ci = self.reg.index_of(p.cmd)
                var title = plain(self.reg.cmds[ci].title)
                if title.endswith("..."):
                    var tc = decode(title)
                    title = slice_str(tc, 0, len(tc) - 3)
                lines.append("  " + pad_right(keys, 24) + title)
            if len(lines) == 0:
                continue
            if len(items) > 0:
                items.append("")
            items.append(lower_to_upper(plain(self.reg.menu_titles[mi])))
            for l in lines:
                items.append(l)
        for l in [
            "",
            "MENUS",
            "  F10                     Open the menu bar",
            "  Alt-<letter>            Open the menu with that highlighted letter",
            "  Alt-1..9                Go to window number",
            "  Esc                     Close a menu or dialog",
            "",
            "EDITING",
            "  Arrows, Home, End       Move (Home toggles indent / column 1)",
            "  Ctrl-Left/Right         Move by word",
            "  Ctrl-Home/End           Start / end of file",
            "  PgUp/PgDn               Page; Ctrl-Up/Down scrolls the view",
            "  Shift + movement        Select",
            "  Tab / Shift-Tab         Indent / outdent (selection or line)",
            "  Ins                     Insert / overwrite mode",
            "",
            "MOUSE",
            "  Click, drag, wheel      Place cursor, select, scroll",
            "  Title bar / corner      Move / resize a window",
            "  [■] / [↑]               Close / zoom a window",
        ]:
            items.append(String(l))
        return items^

    # ============================================================ completion
    def collect_completions(self, ai: Int, prefix: String) -> List[String]:
        var seen = Dict[String, Int]()
        var out = List[String]()
        var pc = decode(prefix)
        var np = len(pc)
        for r in range(self.wins[ai].buf.count()):
            var line = self.wins[ai].buf.line(r)
            var i = 0
            var n = len(line)
            while i < n:
                if is_alpha(line[i]) and (i == 0 or not is_ident(line[i - 1])):
                    var j = i
                    while j < n and is_ident(line[j]):
                        j += 1
                    if j - i > np and j - i >= 2 and not (r == self.wins[ai].cr and j == self.wins[ai].cc):
                        var w = slice_str(line, i, j)
                        if w.startswith(prefix) and w not in seen:
                            seen[w] = 1
                            out.append(w)
                    i = j
                else:
                    i += 1
            if len(out) > 200:
                break
        for lst in [self.hl.kws.copy(), self.hl.types.copy(), self.hl.builtins.copy()]:
            for w in lst:
                if w.startswith(prefix) and w != prefix and w not in seen:
                    seen[w] = 1
                    out.append(w)
        return out^

    def ensure_user_snippets(mut self):
        """Lazily load `<config_home>/snippets.toml` and `<project_or_cwd>/.vscode/*.code-snippets`."""
        if self.user_snippets_loaded:
            return
        self.user_snippets_loaded = True
        self.user_snippets.clear()
        var ch = config_home()
        if ch.byte_length() > 0:
            var toml_p = join_path(ch, "snippets.toml")
            if path_exists(toml_p):
                try:
                    for sn in load_toml_snippets(toml_p):
                        self.user_snippets.append(sn.copy())
                except:
                    pass
        var roots = List[String]()
        var sr = self.symidx_root()
        if sr.byte_length() > 0:
            roots.append(sr)
        if self.cwd.byte_length() > 0 and not (self.cwd in roots):
            roots.append(self.cwd)
        for rt in roots:
            var vs_dir = join_path(rt, ".vscode")
            if path_exists(vs_dir):
                for ent in list_dir(vs_dir):
                    if not ent.endswith("/") and ent.endswith(".code-snippets"):
                        try:
                            for sn in load_vscode_snippets(join_path(vs_dir, ent)):
                                self.user_snippets.append(sn.copy())
                        except:
                            pass
        var pdir = self.plugins_dir if self.plugins_dir.byte_length() > 0 else (config_home() + "/plugins")
        if pdir.byte_length() > 0 and path_exists(pdir):
            for ps in load_plugin_snippets(pdir):
                self.user_snippets.append(SnippetTemplate(ps.prefix, ps.prefix, ps.description, ps.body, ps.description))
            for ent in list_dir(pdir):
                if ent.endswith("/") and ent != "../":
                    var sp_toml = join_path(pdir, String(ent[byte=0:ent.byte_length() - 1]) + "/snippets.toml")
                    if path_exists(sp_toml):
                        try:
                            for sn in load_toml_snippets(sp_toml):
                                self.user_snippets.append(sn.copy())
                        except:
                            pass

    def snip_clear(mut self):
        self.snip_wid = -1
        self.snip_rows.clear()
        self.snip_c1.clear()
        self.snip_c2.clear()
        self.snip_nums.clear()
        self.snip_idx = 0

    def snip_adjust_after_edit(mut self, ai_in: Int = -1):
        """Update active tabstop span(s) and shift later tabstops on the same row by the edit delta."""
        var ai = ai_in if ai_in >= 0 else self.active_editor()
        if ai < 0 or self.snip_wid != self.wins[ai].wid or len(self.snip_rows) == 0:
            return
        var distinct = List[Int]()
        for num in self.snip_nums:
            var seen = False
            for d in distinct:
                if d == num:
                    seen = True
                    break
            if not seen:
                distinct.append(num)
        if self.snip_idx < 0 or self.snip_idx >= len(distinct):
            return
        var active_num = distinct[self.snip_idx]

        # Collect all current cursor end-columns per row (main + multi-cursors)
        var cur_rows = List[Int]()
        var cur_ends = List[Int]()
        cur_rows.append(self.wins[ai].cr)
        cur_ends.append(max(self.wins[ai].cc, self.wins[ai].ac) if (self.wins[ai].sel and self.wins[ai].ar == self.wins[ai].cr) else self.wins[ai].cc)
        for ex in self.wins[ai].extra:
            cur_rows.append(ex.r)
            cur_ends.append(max(ex.c, ex.ac) if (ex.sel and ex.ar == ex.r) else ex.c)

        # Sort cursors by (row, end_col) so mirrored stops on the same row match left-to-right
        for a in range(1, len(cur_rows)):
            var b = a
            while b > 0 and (cur_rows[b] < cur_rows[b - 1] or (cur_rows[b] == cur_rows[b - 1] and cur_ends[b] < cur_ends[b - 1])):
                var tr = cur_rows[b]
                var te = cur_ends[b]
                cur_rows[b] = cur_rows[b - 1]
                cur_ends[b] = cur_ends[b - 1]
                cur_rows[b - 1] = tr
                cur_ends[b - 1] = te
                b -= 1

        # Gather active stop indices sorted by (row, c1)
        var act_q = List[Int]()
        for q in range(len(self.snip_rows)):
            if self.snip_nums[q] == active_num:
                act_q.append(q)
        for a in range(1, len(act_q)):
            var b = a
            while b > 0 and (
                self.snip_rows[act_q[b]] < self.snip_rows[act_q[b - 1]]
                or (
                    self.snip_rows[act_q[b]] == self.snip_rows[act_q[b - 1]]
                    and self.snip_c1[act_q[b]] < self.snip_c1[act_q[b - 1]]
                )
            ):
                var tq = act_q[b]
                act_q[b] = act_q[b - 1]
                act_q[b - 1] = tq
                b -= 1

        var cur_used = List[Bool]()
        for _ in range(len(cur_rows)):
            cur_used.append(False)

        for qi in range(len(act_q)):
            var q = act_q[qi]
            var r = self.snip_rows[q]
            var old_c1 = self.snip_c1[q]
            var old_c2 = self.snip_c2[q]
            var matched = -1
            for ci in range(len(cur_rows)):
                if not cur_used[ci] and cur_rows[ci] == r and cur_ends[ci] >= old_c1:
                    matched = ci
                    break
            if matched < 0:
                continue
            cur_used[matched] = True
            var new_c2 = cur_ends[matched]
            var delta = new_c2 - old_c2
            if delta == 0:
                continue
            self.snip_c2[q] = new_c2
            for p in range(len(self.snip_rows)):
                if p != q and self.snip_rows[p] == r and self.snip_c1[p] >= old_c2:
                    self.snip_c1[p] = max(new_c2, self.snip_c1[p] + delta)
                    self.snip_c2[p] = max(self.snip_c1[p], self.snip_c2[p] + delta)

    def snip_jump(mut self, ai: Int, back: Bool) -> Bool:
        """Advance (or step back) between active snippet tabstops on Tab / Shift-Tab."""
        if ai < 0 or self.snip_wid != self.wins[ai].wid or len(self.snip_rows) == 0:
            return False

        # Build unique ordered tabstop numbers
        var distinct = List[Int]()
        for num in self.snip_nums:
            var seen = False
            for d in distinct:
                if d == num:
                    seen = True
                    break
            if not seen:
                distinct.append(num)

        if len(distinct) == 0:
            self.snip_clear()
            return False

        # Adjust same-line tabstop columns for any edit made at the current stop before collapsing cursors
        self.snip_adjust_after_edit(ai)

        # Collapse multi-cursors back to main before jumping
        self.wins[ai].collapse()

        var nxt = self.snip_idx - 1 if back else self.snip_idx + 1
        if nxt < 0:
            return True
        if nxt >= len(distinct):
            self.snip_clear()
            return False

        self.snip_idx = nxt
        var target_num = distinct[nxt]

        # Collect all matching stops for target_num
        var cs = List[Cur]()
        for q in range(len(self.snip_rows)):
            if self.snip_nums[q] == target_num:
                var r = max(0, min(self.snip_rows[q], self.wins[ai].buf.count() - 1))
                var llen = self.wins[ai].buf.llen(r)
                var c1 = max(0, min(self.snip_c1[q], llen))
                var c2 = max(c1, min(self.snip_c2[q], llen))
                if c2 > c1:
                    cs.append(Cur(r, c2, True, r, c1, self.wins[ai].vcol(r, c2)))
                else:
                    cs.append(Cur(r, c1, False, r, c1, self.wins[ai].vcol(r, c1)))

        if len(cs) > 0:
            self.wins[ai].set_cursors(cs^, 0)
            self.wins[ai].sync_want()
            self.wins[ai].follow = True

        return True

    def comp_rebuild(
        mut self,
        prefix: String,
        words: List[String],
        mojo_snips: Bool = False,
        user_snips: Bool = True,
    ):
        """Fill the popup's lists: the server's items that fit what is typed (exact prefix
        first, falling back to case-insensitive prefix or fuzzy subsequence when no exact
        prefix fits), followed by words from the text that the server did not offer."""
        self.comp_items.clear()
        self.comp_insert.clear()
        self.comp_kind.clear()
        self.comp_detail.clear()
        self.comp_doc.clear()
        self.comp_raw.clear()
        self.comp_srv_idx.clear()
        var seen = Dict[String, Int]()
        if self.comp_srv_have:
            var plow = lower_str(prefix)
            var np = cp_len(prefix)
            for tier in range(3):
                if tier > 0 and (prefix.byte_length() == 0 or len(self.comp_items) > 0):
                    break
                if np < 2 and tier == 2:
                    break
                for k in range(len(self.comp_srv)):
                    if self.comp_srv[k].label in seen:
                        continue
                    var flt = self.comp_srv[k].filter
                    var match_ok: Bool
                    if prefix.byte_length() == 0:
                        match_ok = True
                    elif tier == 0:
                        match_ok = flt.startswith(prefix)
                    elif tier == 1:
                        match_ok = not flt.startswith(prefix) and lower_str(flt).startswith(plow)
                    else:
                        match_ok = fuzzy_score(flt, prefix) >= 0
                    if not match_ok:
                        continue
                    seen[self.comp_srv[k].label] = 1
                    self.comp_items.append(self.comp_srv[k].label)
                    self.comp_insert.append(self.comp_srv[k].insert)
                    self.comp_kind.append(self.comp_srv[k].kind)
                    self.comp_detail.append(self.comp_srv[k].detail)
                    self.comp_doc.append(self.comp_srv[k].doc)
                    self.comp_raw.append(self.comp_srv[k].raw)
                    self.comp_srv_idx.append(k)
        for w in words:
            if w in seen:
                continue
            seen[w] = 1
            self.comp_items.append(w)
            self.comp_insert.append(w)
            self.comp_kind.append(-1)
            self.comp_detail.append("")
            self.comp_doc.append("")
            self.comp_raw.append("")
            self.comp_srv_idx.append(-1)
        if user_snips and prefix.byte_length() > 0:
            self.ensure_user_snippets()
            for sn in self.user_snippets:
                if sn.trigger.startswith(prefix) and sn.label not in seen:
                    seen[sn.label] = 1
                    self.comp_items.append(sn.label)
                    self.comp_insert.append(sn.body)
                    self.comp_kind.append(15)
                    self.comp_detail.append(sn.detail)
                    self.comp_doc.append(sn.doc)
                    self.comp_raw.append("")
                    self.comp_srv_idx.append(-1)
        if mojo_snips and prefix.byte_length() > 0:
            for sn in mojo_snippets():
                if sn.trigger.startswith(prefix) and sn.label not in seen:
                    seen[sn.label] = 1
                    self.comp_items.append(sn.label)
                    self.comp_insert.append(sn.body)
                    self.comp_kind.append(15)
                    self.comp_detail.append(sn.detail)
                    self.comp_doc.append(sn.doc)
                    self.comp_raw.append("")
                    self.comp_srv_idx.append(-1)

    def lsp_request_completion(mut self, ai: Int, start: Int, trigger: String) -> Bool:
        """Ask the language server what could come at the cursor. The answer arrives
        later (completion_arrived). False if there is no server to ask."""
        var path = self.wins[ai].path
        if path.byte_length() == 0:
            return False
        var xk = self.extra_for(path)
        if xk >= 0:
            if self.lsp_extra[xk].client.state != LSP_READY or not self.lsp_extra[xk].client.table.completion:
                return False
            self.extra_send_now(xk, ai)
            var xuri = path_to_uri(path)
            if self.lsp_extra[xk].client.find_doc(xuri) < 0:
                return False
            self.lsp_extra[xk].client.cancel_request(self.comp_req_id)
            var xid = self.lsp_extra[xk].client.request_completion(xuri, self.wins[ai].cr, self.wins[ai].buf.utf16_col(self.wins[ai].cr, self.wins[ai].cc), trigger, now_ns())
            if xid < 0:
                return False
            self.comp_srv_extra = xk
            self.comp_req_id = xid
            self.comp_req_path = path
            self.comp_req_row = self.wins[ai].cr
            self.comp_req_start = start
            self.comp_req_trigger = trigger
            self.comp_retry_due = 0
            return True
        if self.lsp.state != LSP_READY or not self.lsp.table.completion:
            return False
        var uri = path_to_uri(path)
        if self.lsp.find_doc(uri) < 0:
            return False
        self.lsp.cancel_request(self.comp_req_id)
        var now = now_ns()
        self.lsp_send_changes(ai, now, False)          # the server must see what was just typed
        var vp = self.wins[ai].lsp_to_virtual_pos(self.wins[ai].cr, self.wins[ai].buf.utf16_col(self.wins[ai].cr, self.wins[ai].cc))
        var id = self.lsp.request_completion(uri, vp[0], vp[1], trigger, now)
        if id < 0:
            return False
        self.comp_srv_extra = -1
        self.comp_req_id = id
        self.comp_req_path = path
        self.comp_req_row = self.wins[ai].cr
        self.comp_req_start = start
        self.comp_req_trigger = trigger
        self.comp_retry_due = 0
        return True

    def completion_retry(mut self, now: Int):
        """The server was still analysing the last edit when it was asked: ask again,
        if the cursor is still in the same word."""
        self.comp_retry_due = 0
        var ai = self.active_editor()
        if ai < 0 or self.wins[ai].path != self.comp_req_path or self.wins[ai].cr != self.comp_req_row or self.wins[ai].word_start() != self.comp_req_start:
            self.comp_waiting = False
            return
        var keep = self.comp_waiting
        var trig = String(self.comp_req_trigger)
        if not self.lsp_request_completion(ai, self.comp_req_start, trig):
            self.comp_waiting = False
            return
        self.comp_waiting = keep

    def start_complete(mut self):
        var ai = self.active_editor()
        if ai < 0:
            return
        self.wins[ai].collapse()
        var start = self.wins[ai].word_start()
        var prefix = slice_str(self.wins[ai].buf.line(self.wins[ai].cr), start, self.wins[ai].cc)
        # the server's list is good for as long as the same word is being typed
        var same = self.comp_srv_have and not self.comp_srv_incomplete and self.comp_srv_path == self.wins[ai].path and self.comp_srv_row == self.wins[ai].cr and self.comp_srv_start == start
        var asked = False
        if not same:
            self.comp_srv_have = False
            self.comp_retries = 0
            asked = self.lsp_request_completion(ai, start, "")
        var words = List[String]()
        var line = self.wins[ai].buf.line(self.wins[ai].cr)
        var member = start > 0 and start <= len(line) and line[start - 1] == 46
        if prefix.byte_length() > 0 and not (member and same and len(self.comp_srv) > 0):
            words = self.collect_completions(ai, prefix)
        var want_snips = not member and self.wins[ai].effective_lang() == HL_MOJO
        self.comp_rebuild(prefix, words, want_snips, not member)
        self.comp_waiting = False
        if len(self.comp_items) == 0:
            self.mode = M_NORMAL
            if asked:
                self.comp_waiting = True
                self.say("Asking the language server...")
            elif prefix.byte_length() == 0:
                self.say("Type the start of an identifier, then Ctrl-Space")
            else:
                self.say("No completions for '" + prefix + "'")
            return
        if len(self.comp_items) == 1 and self.mode != M_COMPLETE and not asked and self.comp_kind[0] < 0:
            var cps = decode(self.comp_items[0])
            var rest = List[Int]()
            for k in range(len(decode(prefix)), len(cps)):
                rest.append(cps[k])
            self.wins[ai].insert_text(rest, ACT_TYPE)
            return
        self.comp_sel = 0
        self.comp_start = start
        self.mode = M_COMPLETE
        self.comp_want_details()

    def completion_arrived(mut self, m: RpcMessage):
        """The server's answer to a completion request."""
        self.comp_req_id = -1
        var waiting = self.comp_waiting
        self.comp_waiting = False
        var ai = self.active_editor()
        if m.kind == RPC_ERROR:
            # "not now" answers are followed by another try a moment later
            var again = retry_later(m)
            if again and self.comp_retries < COMP_MAX_RETRIES and (waiting or self.mode == M_COMPLETE):
                self.comp_retries += 1
                self.comp_retry_due = now_ns() + COMP_RETRY_MS * 1000000
                self.comp_waiting = waiting
                return
            self.log_error("language server: completion failed: " + m.error_message())
            if waiting:
                self.say("Language server: " + m.error_message())
            return
        self.comp_retries = 0
        if m.kind != RPC_RESPONSE or ai < 0 or (self.mode != M_COMPLETE and not waiting):
            return
        # only if the cursor is still in the word the question was about
        if self.wins[ai].path != self.comp_req_path or self.wins[ai].cr != self.comp_req_row or self.wins[ai].word_start() != self.comp_req_start:
            return
        var lst = parse_completion(m.doc, m.result())
        self.comp_srv = lst.items.copy()
        self.comp_srv_have = True
        self.comp_srv_incomplete = lst.incomplete
        self.comp_srv_path = self.comp_req_path
        self.comp_srv_row = self.comp_req_row
        self.comp_srv_start = self.comp_req_start
        var start = self.comp_req_start
        var prefix = slice_str(self.wins[ai].buf.line(self.wins[ai].cr), start, self.wins[ai].cc)
        # if the user has already moved the bar, it stays on that item
        var keep = String("")
        if self.mode == M_COMPLETE and self.comp_sel > 0 and self.comp_sel < len(self.comp_items):
            keep = self.comp_items[self.comp_sel]
        var words = List[String]()
        var line = self.wins[ai].buf.line(self.wins[ai].cr)
        var member = start > 0 and start <= len(line) and line[start - 1] == 46
        if prefix.byte_length() > 0 and not (member and len(self.comp_srv) > 0):
            # after "x." the server's members are the answer; keywords would be noise
            words = self.collect_completions(ai, prefix)
        var want_snips = not member and self.wins[ai].effective_lang() == HL_MOJO
        self.comp_rebuild(prefix, words, want_snips, not member)
        if len(self.comp_items) == 0:
            if waiting:
                self.say("No completions here")
            self.mode = M_NORMAL
            return
        self.comp_sel = 0
        # the user's choice stays under the cursor bar if it is still in the list
        if keep.byte_length() > 0:
            for k in range(len(self.comp_items)):
                if self.comp_items[k] == keep:
                    self.comp_sel = k
                    break
        self.comp_start = start
        self.mode = M_COMPLETE
        self.comp_want_details()

    def comp_want_details(mut self):
        """Ask the server for the documentation of the selected item if it came
        without (servers often send it only on request)."""
        if self.mode != M_COMPLETE or self.comp_sel >= len(self.comp_items):
            return
        var k = self.comp_sel
        if self.comp_kind[k] < 0 or self.comp_doc[k].byte_length() > 0 or self.comp_raw[k].byte_length() == 0:
            return
        if self.comp_resolve_label == self.comp_items[k]:
            return                          # already asked for this one
        var id: Int
        if self.comp_srv_extra >= 0 and self.comp_srv_extra < len(self.lsp_extra):
            self.lsp_extra[self.comp_srv_extra].client.cancel_request(self.comp_resolve_id)
            id = self.lsp_extra[self.comp_srv_extra].client.request_resolve(self.comp_raw[k], now_ns())
        else:
            self.lsp.cancel_request(self.comp_resolve_id)
            id = self.lsp.request_resolve(self.comp_raw[k], now_ns())
        if id >= 0:
            self.comp_resolve_id = id
            self.comp_resolve_label = self.comp_items[k]

    def resolve_arrived(mut self, m: RpcMessage):
        self.comp_resolve_id = -1
        if m.kind != RPC_RESPONSE or m.result() < 0:
            return
        var it = parse_completion_item(m.doc, m.result())
        for k in range(len(self.comp_items)):
            if self.comp_items[k] == self.comp_resolve_label and self.comp_kind[k] >= 0:
                if it.detail.byte_length() > 0:
                    self.comp_detail[k] = it.detail
                self.comp_doc[k] = it.doc
        for k in range(len(self.comp_srv)):
            if self.comp_srv[k].label == self.comp_resolve_label:
                if it.detail.byte_length() > 0:
                    self.comp_srv[k].detail = it.detail
                self.comp_srv[k].doc = it.doc
                if len(it.extra_edits) > 0 and len(self.comp_srv[k].extra_edits) == 0:
                    self.comp_srv[k].extra_edits = it.extra_edits.copy()

    def comp_accept(mut self, ai: Int):
        """Put the selected item into the text in place of what was typed of it, applying
        any LSP textEdit, additionalTextEdits (auto-imports), and snippet tabstop cursor."""
        var k = self.comp_sel
        var sidx = self.comp_srv_idx[k] if k < len(self.comp_srv_idx) else -1
        var raw_ins = String(self.comp_insert[k])
        var is_snip = (k < len(self.comp_kind) and self.comp_kind[k] == 15) or (sidx >= 0 and (self.comp_srv[sidx].insert_format == 2 or self.comp_srv[sidx].kind == 15))
        self.snip_clear()
        if is_snip:
            var wpath = self.wins[ai].path
            var fname = basename(wpath) if wpath.byte_length() > 0 else self.wins[ai].title
            var fstem = stem(fname)
            var sel_txt = to_str(self.wins[ai].selected_text()) if self.wins[ai].has_sel() else String("")
            var clip_txt = to_str(self.clipboard)
            raw_ins = expand_variables(
                raw_ins,
                fname,
                fstem,
                self.wins[ai].cr + 1,
                self.wins[ai].cr,
                sel_txt,
                clip_txt,
            )
        var line_indent = String("")
        if is_snip and sidx < 0 and raw_ins.find("\n") >= 0:
            var cur_ln = self.wins[ai].buf.line(self.wins[ai].cr)
            var ind_n = 0
            while ind_n < min(self.comp_start, len(cur_ln)) and (cur_ln[ind_n] == 32 or cur_ln[ind_n] == 9):
                ind_n += 1
            line_indent = slice_str(cur_ln, 0, ind_n)
        var sn_exp = expand_snippet_full(raw_ins, line_indent) if is_snip else expand_snippet_full("", "")
        if is_snip:
            raw_ins = sn_exp.text
        var text = decode(raw_ins)
        var g = self.wins[ai].new_group()
        self.wins[ai].forced_group = g
        var base_row = self.wins[ai].cr
        var base_col = self.comp_start
        var used_lsp_edit = False
        if sidx >= 0 and self.comp_srv[sidx].has_edit:
            var ed = self.comp_srv[sidx].edit.copy()
            if self.comp_srv_extra < 0 and self.wins[ai].lsp_nb_active:
                var mp1 = self.wins[ai].lsp_from_virtual_pos(ed.r1, ed.c1)
                var mp2 = self.wins[ai].lsp_from_virtual_pos(ed.r2, ed.c2)
                if mp1[0] >= 0 and mp2[0] >= 0:
                    ed.r1 = mp1[0]
                    ed.c1 = mp1[1]
                    ed.r2 = mp2[0]
                    ed.c2 = mp2[1]
                else:
                    ed.r1 = -1
            if ed.r1 == ed.r2 and ed.r1 >= 0 and ed.r1 < self.wins[ai].buf.count():
                var ln = self.wins[ai].buf.line(ed.r1)
                var c1 = utf16_to_col(ln, ed.c1)
                var c2 = max(c1, max(self.wins[ai].cc if ed.r1 == self.wins[ai].cr else c1, utf16_to_col(ln, ed.c2)))
                self.wins[ai].sel = True
                self.wins[ai].ar = ed.r1
                self.wins[ai].ac = c1
                self.wins[ai].cr = ed.r1
                self.wins[ai].cc = min(len(ln), c2)
                base_row = ed.r1
                base_col = c1
                self.wins[ai].insert_text(text, ACT_OTHER)
                used_lsp_edit = True
        if not used_lsp_edit:
            var typed = self.wins[ai].buf.get_text(self.wins[ai].cr, self.comp_start, self.wins[ai].cr, self.wins[ai].cc)
            var extends = len(text) >= len(typed)
            if extends:
                for q in range(len(typed)):
                    if text[q] != typed[q]:
                        extends = False
                        break
            if extends:
                var rest = List[Int]()
                for q in range(len(typed), len(text)):
                    rest.append(text[q])
                if self.keymap == 3 and self.vim.mode == 1 and not self.vim.replaying:
                    for ch in rest:
                        self.vim.cur.append(ch)
                self.wins[ai].insert_text(rest, ACT_TYPE)
            else:
                if self.keymap == 3 and self.vim.mode == 1 and not self.vim.replaying:
                    for _ in range(len(typed)):
                        self.vim.cur.append(KEY_BACKSPACE)
                    for ch in text:
                        self.vim.cur.append(ch)
                self.wins[ai].sel = True
                self.wins[ai].ar = self.wins[ai].cr
                self.wins[ai].ac = self.comp_start
                self.wins[ai].insert_text(text, ACT_OTHER)
        if is_snip and len(sn_exp.stops) > 0:
            for si in range(len(sn_exp.stops)):
                var p1 = pos_after_offset(base_row, base_col, text, sn_exp.stops[si].start)
                var p2 = pos_after_offset(base_row, base_col, text, sn_exp.stops[si].end)
                self.snip_rows.append(p1.r)
                self.snip_c1.append(p1.c)
                self.snip_c2.append(p2.c if p2.r == p1.r else p1.c)
                self.snip_nums.append(sn_exp.stops[si].num)
            self.snip_wid = self.wins[ai].wid
            self.snip_idx = -1
            _ = self.snip_jump(ai, False)
        # Apply additionalTextEdits (e.g. auto-imports at top of file) in reverse line order
        if sidx >= 0 and len(self.comp_srv[sidx].extra_edits) > 0:
            var extras = self.comp_srv[sidx].extra_edits.copy()
            for a in range(1, len(extras)):
                var b = a
                while b > 0 and (extras[b].r1 > extras[b - 1].r1 or (extras[b].r1 == extras[b - 1].r1 and extras[b].c1 > extras[b - 1].c1)):
                    var tmp = extras[b].copy()
                    extras[b] = extras[b - 1].copy()
                    extras[b - 1] = tmp^
                    b -= 1
            for ae in extras:
                var nlines = self.wins[ai].buf.count()
                if ae.r1 >= 0 and ae.r2 >= ae.r1 and ae.r2 <= nlines:
                    var r1 = min(ae.r1, nlines - 1)
                    var r2 = min(ae.r2, nlines - 1)
                    var c1 = utf16_to_col(self.wins[ai].buf.line(r1), ae.c1) if ae.r1 < nlines else self.wins[ai].buf.llen(r1)
                    var c2 = utf16_to_col(self.wins[ai].buf.line(r2), ae.c2) if ae.r2 < nlines else self.wins[ai].buf.llen(r2)
                    var ins_cps = List[Int]()
                    var added_rows = 0
                    for cp in decode(ae.text):
                        if cp != 13:
                            ins_cps.append(cp)
                            if cp == 10:
                                added_rows += 1
                    if r1 != r2 or c1 != c2:
                        _ = self.wins[ai].buf.delete(r1, c1, r2, c2, self.wins[ai].cr, self.wins[ai].cc, g)
                    if len(ins_cps) > 0:
                        _ = self.wins[ai].buf.insert(r1, c1, ins_cps, self.wins[ai].cr, self.wins[ai].cc, g)
                    if ae.r2 <= self.wins[ai].cr:
                        self.wins[ai].cr = max(0, self.wins[ai].cr + added_rows - (r2 - r1))
            self.wins[ai].clamp()
            self.wins[ai].sync_want()
        self.wins[ai].forced_group = 0
        self.wins[ai].break_group()
        self.comp_srv_have = False
        self.mode = M_NORMAL

    def maybe_trigger_completion(mut self, ch: Int):
        """After a character was typed in the editor: if it is one of the server's
        trigger characters (such as "."), ask for completions at once."""
        var ai = self.active_editor()
        if ai < 0 or self.wins[ai].has_multi():
            return
        var one = List[Int]()
        one.append(ch)
        var s = to_str(one)
        var xk = self.extra_for(self.wins[ai].path)
        if xk >= 0:
            if self.lsp_extra[xk].client.state != LSP_READY or not (s in self.lsp_extra[xk].client.table.completion_triggers):
                return
        elif self.lsp.state != LSP_READY or not (s in self.lsp.table.completion_triggers):
            return
        self.comp_srv_have = False
        self.comp_retries = 0
        if self.lsp_request_completion(ai, self.wins[ai].cc, s):
            self.comp_waiting = True

    # ================================================================== hover
    def hover_command(mut self):
        """Search > Describe symbol: ask the language server about the symbol at the
        cursor; the answer opens in a small window (hover_arrived)."""
        var ai = self.active_editor()
        if ai < 0:
            return
        self.wins[ai].collapse()
        self.hover_retries = 0
        var xk = self.extra_for(self.wins[ai].path)
        if xk >= 0:
            # a file of another language: its own server answers
            if self.extra_hover(xk, ai):
                self.say("Asking " + self.lsp_extra[xk].name + "...")
            else:
                self.say("Start its language server first (" + self.reg.key_label(CM_LSP) + ")")
            return
        if not self.hover_request(ai):
            if self.lsp.state == LSP_READY and not self.lsp.table.hover:
                self.say("This language server does not describe symbols")
            else:
                self.say("Start the language server first (" + self.reg.key_label(CM_LSP) + ")")
            return
        if self.docpane_index() >= 0:
            self.hover_pane = True              # the answer goes to the docs pane
            self.docpane_name = self.word_under(ai)
            self.docpane_show("Docs: " + self.docpane_name, "Asking the language server...")
        self.say("Asking the language server...")

    def hover_request(mut self, ai: Int) -> Bool:
        var path = self.wins[ai].path
        if path.byte_length() == 0 or self.lsp.state != LSP_READY or not self.lsp.table.hover:
            return False
        var uri = path_to_uri(path)
        if self.lsp.find_doc(uri) < 0:
            return False
        self.lsp.cancel_request(self.hover_req_id)
        var now = now_ns()
        self.lsp_send_changes(ai, now, False)
        var vp = self.wins[ai].lsp_to_virtual_pos(self.wins[ai].cr, self.wins[ai].buf.utf16_col(self.wins[ai].cr, self.wins[ai].cc))
        var id = self.lsp.request_hover(uri, vp[0], vp[1], now)
        if id < 0:
            return False
        self.hover_req_id = id
        self.hover_srv = -1
        self.hover_req_path = path
        self.hover_req_row = self.wins[ai].cr
        self.hover_req_col = self.wins[ai].cc
        self.hover_retry_due = 0
        return True

    def hover_still_wanted(self) -> Bool:
        """The cursor has not moved since the question was asked."""
        var ai = self.active_editor()
        return ai >= 0 and self.mode == M_NORMAL and self.wins[ai].path == self.hover_req_path and self.wins[ai].cr == self.hover_req_row and self.wins[ai].cc == self.hover_req_col

    def hover_arrived(mut self, m: RpcMessage):
        self.hover_req_id = -1
        if not self.hover_still_wanted():
            self.hover_pane = False
            return
        if m.kind == RPC_ERROR and self.hover_pane and not (retry_later(m) and self.hover_retries < COMP_MAX_RETRIES):
            self.docpane_hover("")
            return
        if m.kind == RPC_ERROR:
            if retry_later(m) and self.hover_retries < COMP_MAX_RETRIES:
                self.hover_retries += 1
                self.hover_retry_due = now_ns() + COMP_RETRY_MS * 1000000
                return
            self.say("Language server: " + m.error_message())
            return
        var text = hover_markdown(m.doc, m.result())
        if self.hover_pane:
            self.docpane_hover(text)
            return
        if text.byte_length() == 0:
            self.say("Nothing is known about this place")
            return
        self.hover_lines = md_render(text, max(20, min(72, self.scr.w - 6)), self.hl)
        if len(self.hover_lines) == 0:
            self.say("Nothing is known about this place")
            return
        self.hover_scroll = 0
        self.mode = M_HOVER
        self.say("")

    # ========================================================== parameter tip
    def sig_command(mut self):
        """Search > Parameter info: show the signature of the call the cursor is in."""
        var ai = self.active_editor()
        if ai < 0:
            return
        self.sig_retries = 0
        if not self.sig_request(ai, "", self.sig_on):
            var xk = self.extra_for(self.wins[ai].path)
            if xk >= 0 and self.lsp_extra[xk].client.state == LSP_READY and not self.lsp_extra[xk].client.table.signature_help:
                self.say("This language server does not describe parameters")
            elif xk < 0 and self.lsp.state == LSP_READY and not self.lsp.table.signature_help:
                self.say("This language server does not describe parameters")
            else:
                self.say("Start the language server first (" + self.reg.key_label(CM_LSP) + ")")
            return
        self.sig_asked = True

    def sig_request(mut self, ai: Int, trigger: String, again: Bool) -> Bool:
        var path = self.wins[ai].path
        if path.byte_length() == 0:
            return False
        var xk = self.extra_for(path)
        if xk >= 0:
            if self.lsp_extra[xk].client.state != LSP_READY or not self.lsp_extra[xk].client.table.signature_help:
                return False
            self.extra_send_now(xk, ai)
            var xuri = path_to_uri(path)
            if self.lsp_extra[xk].client.find_doc(xuri) < 0:
                return False
            self.lsp_extra[xk].client.cancel_request(self.sig_req_id)
            var xid = self.lsp_extra[xk].client.request_signature(xuri, self.wins[ai].cr, self.wins[ai].buf.utf16_col(self.wins[ai].cr, self.wins[ai].cc), trigger, again, now_ns())
            if xid < 0:
                return False
            self.sig_srv = xk
            self.sig_req_id = xid
            self.sig_path = path
            self.sig_row = self.wins[ai].cr
            self.sig_col = self.wins[ai].cc
            self.sig_version = self.wins[ai].buf.version
            self.sig_retry_due = 0
            return True
        if self.lsp.state != LSP_READY or not self.lsp.table.signature_help:
            return False
        var uri = path_to_uri(path)
        if self.lsp.find_doc(uri) < 0:
            return False
        self.lsp.cancel_request(self.sig_req_id)
        var now = now_ns()
        self.lsp_send_changes(ai, now, False)
        var vp = self.wins[ai].lsp_to_virtual_pos(self.wins[ai].cr, self.wins[ai].buf.utf16_col(self.wins[ai].cr, self.wins[ai].cc))
        var id = self.lsp.request_signature(uri, vp[0], vp[1], trigger, again, now)
        if id < 0:
            return False
        self.sig_srv = -1
        self.sig_req_id = id
        self.sig_path = path
        self.sig_row = self.wins[ai].cr
        self.sig_col = self.wins[ai].cc
        self.sig_version = self.wins[ai].buf.version
        self.sig_retry_due = 0
        return True

    def sig_close(mut self):
        if self.sig_srv >= 0 and self.sig_srv < len(self.lsp_extra):
            self.lsp_extra[self.sig_srv].client.cancel_request(self.sig_req_id)
        else:
            self.lsp.cancel_request(self.sig_req_id)
        self.sig_on = False
        self.sig_asked = False
        self.sig_req_id = -1
        self.sig_retry_due = 0
        self.sig_raw = ""

    def sig_active(self) -> Bool:
        """A tip is showing or on its way."""
        return self.sig_on or self.sig_req_id >= 0 or self.sig_retry_due > 0

    def sig_cycle(mut self, delta: Int) -> Bool:
        """Cycle between active signature overloads (Alt-Up / Alt-Down)."""
        if not self.sig_on or self.sigtip.count <= 1 or self.sig_raw.byte_length() == 0:
            return False
        var next_idx = (self.sigtip.index + delta + self.sigtip.count) % self.sigtip.count
        var doc = json_parse(self.sig_raw)
        if not doc.ok:
            return False
        var info = parse_signature(doc, 0, next_idx)
        if not info.ok:
            return False
        self.sigtip = info^
        return True

    def maybe_trigger_signature(mut self, ch: Int):
        """After a character was typed in the editor: "(", ",", and "[" (for Mojo
        compile-time parameters) bring up the parameter tip."""
        var ai = self.active_editor()
        if ai < 0 or self.wins[ai].has_multi():
            return
        var one = List[Int]()
        one.append(ch)
        var s = to_str(one)
        var xk = self.extra_for(self.wins[ai].path)
        if xk >= 0:
            if self.lsp_extra[xk].client.state != LSP_READY or not self.lsp_extra[xk].client.table.signature_help:
                return
            if not (s in self.lsp_extra[xk].client.table.signature_triggers):
                return
            self.sig_retries = 0
            self.sig_asked = False
            _ = self.sig_request(ai, s, self.sig_on)
            return
        if self.lsp.state != LSP_READY or not self.lsp.table.signature_help:
            return
        var mojo_param = s == "[" and is_mojo_file(self.wins[ai].path)
        if not (s in self.lsp.table.signature_triggers) and not mojo_param:
            return
        self.sig_retries = 0
        self.sig_asked = False
        _ = self.sig_request(ai, s if s in self.lsp.table.signature_triggers else String(""), self.sig_on)

    def sig_follow(mut self):
        """After every key and click: while a tip is showing (or on its way) and the
        cursor or the text moved, ask again - the server says which parameter is now
        being typed, or that the cursor has left the call."""
        if not self.sig_active():
            return
        var ai = self.active_editor()
        if ai < 0 or (self.mode != M_NORMAL and self.mode != M_COMPLETE) or self.wins[ai].path != self.sig_path or self.wins[ai].has_multi():
            self.sig_close()
            return
        if self.wins[ai].cr == self.sig_row and self.wins[ai].cc == self.sig_col and self.wins[ai].buf.version == self.sig_version:
            return
        self.sig_retries = 0
        if not self.sig_request(ai, "", self.sig_on):
            self.sig_close()

    def sig_arrived(mut self, m: RpcMessage):
        self.sig_req_id = -1
        var asked = self.sig_asked
        if m.kind == RPC_ERROR:
            if retry_later(m) and self.sig_retries < COMP_MAX_RETRIES:
                self.sig_retries += 1
                self.sig_retry_due = now_ns() + COMP_RETRY_MS * 1000000
                return
            self.sig_close()
            if asked:
                self.say("Language server: " + m.error_message())
            return
        var info = parse_signature(m.doc, m.result())
        if not info.ok:
            self.sig_close()
            if asked:
                self.say("The cursor is not inside a call")
            return
        self.sig_raw = m.doc.dump(m.result())
        self.sigtip = info^
        self.sig_on = True
        self.sig_asked = False

    def hover_page(self) -> Int:
        """Lines of the hover window that fit on the screen."""
        return max(3, min(14, self.scr.h - 6))

    def hover_key(mut self, k: Int) -> Bool:
        """Keys while a hover window is open. True if the key was used up; any other key
        closes the window and then does what it normally does."""
        var page = self.hover_page()
        var most = max(0, len(self.hover_lines) - page)
        if k == KEY_UP:
            self.hover_scroll = max(0, self.hover_scroll - 1)
            return True
        if k == KEY_DOWN:
            self.hover_scroll = min(most, self.hover_scroll + 1)
            return True
        if k == KEY_PGUP:
            self.hover_scroll = max(0, self.hover_scroll - page)
            return True
        if k == KEY_PGDN:
            self.hover_scroll = min(most, self.hover_scroll + page)
            return True
        self.mode = M_NORMAL
        return k == KEY_ESC or k == KEY_ENTER

    def complete_key(mut self, k: Int) -> Bool:
        var ai = self.active_editor()
        if ai < 0:
            self.mode = M_NORMAL
            return False
        var n = len(self.comp_items)
        if k == KEY_UP or k == (112 | MOD_CTRL):
            self.comp_sel = (self.comp_sel - 1 + n) % n
            self.comp_want_details()
            return True
        if k == KEY_DOWN or k == (110 | MOD_CTRL):
            self.comp_sel = (self.comp_sel + 1) % n
            self.comp_want_details()
            return True
        if k == KEY_PGUP:
            self.comp_sel = max(0, self.comp_sel - 8)
            self.comp_want_details()
            return True
        if k == KEY_PGDN:
            self.comp_sel = min(n - 1, self.comp_sel + 8)
            self.comp_want_details()
            return True
        if k == KEY_ESC or k == (91 | MOD_CTRL) or k == (99 | MOD_CTRL):
            self.mode = M_NORMAL
            self.comp_srv_have = False
            if self.keymap == 3 and self.vim.mode == 1 and (k == (91 | MOD_CTRL) or k == (99 | MOD_CTRL)):
                return False                    # let vim_key exit Insert mode too
            return True
        if k == KEY_ENTER or k == KEY_TAB:
            self.comp_accept(ai)
            return True
        if k < K_BASE and is_ident(k):
            self.wins[ai].type_char(k, True)
            self.start_complete()
            return True
        if k == KEY_BACKSPACE:
            self.wins[ai].backspace()
            if self.wins[ai].cc <= self.comp_start:
                self.mode = M_NORMAL
            else:
                self.start_complete()
            return True
        self.mode = M_NORMAL
        return False
