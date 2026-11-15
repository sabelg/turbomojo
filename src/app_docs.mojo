"""The documentation reader: the downloaded Mojo documentation as books with a table of
contents, a rendered page, links, history and search - a full-screen mode."""
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
from palette import Palette, theme, THEME_COUNT, ANSI_BASE
from kittygfx import *
from png import png_decode
from sixel import sixel_encode, scale_to, fit_pixels
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
from helpbook import write_help, HELP_TUTORIAL
from app_notify import *
from app_lsp import *
from lsp import *
from markdown import *
from app_watch import *
from watch import *
from app_swap import *
from swap import *
from app_files import *
from app_dialogs import *
from app_menus import *
from app_exec import *
from app_jobs import *
from app_pickers import *
from app_nav import *
from app_outline import *
from layout import *
from app_layout import *
from explorer import *
from app_explorer import *
from doclib import *
from stdref import *
from docfetch import FETCH_SCRIPT
from outline import *
from symindex import *
from docs import *
from watch import file_sig
from app_input import *
from app_mouse import *
from app_draw import *
from app_debug import *
from app_terminal import *
from app_tests import *
from codequery import *
from errhelp import explain_for, err_title
from docpane import md_section, md_mojo_blocks
from app_explain import *
from app_keyecho import *
from puzzlecheck import PUZZLES_DIR


comptime DOC_FIND_MAX = 150         # results the finder lists
comptime FIND_ANSWERS = 24          # API rows of the finder that get a one-line answer
comptime FIND_EXPLAIN = -10         # finder rows: -10 - page is an error explanation,
comptime FIND_COMMAND = -100000     # -100000 - id a command
comptime DOC_TEXT_MAX = 96          # the widest a page's text is laid out


def doc_welcome(home: String, have: Bool) -> String:
    """What the page pane shows before a page is chosen."""
    if have:
        return "# Mojo documentation\n\nChoose a book and a page in the contents on the left.\n\n- **Enter** opens what is marked; on a book or chapter heading it shows or hides what is under it\n- **Tab** moves between the contents and the page; on a page it steps through the links, **Enter** follows one\n- **/** opens the finder: words, phrases in quotes, @names of the standard library, #headings, dotted.paths\n- **Ctrl-F** finds text on the current page (**F3** / **Shift-F3** step through matches); **G** jumps to a heading on the page\n- **C** copies the code block in view; **T** opens it in a scratch buffer to run\n- **N** and **P** go to the next and the previous page, **Backspace** goes back\n- **O** on a lesson or an example opens your own copy of it in the editor: change it, **Ctrl-F9** runs it\n- **Esc** returns to the editor\n\nThe documentation is Modular's, downloaded from their public repositories into\n\n`" + home + "`\n\nHelp > Download documentation updates it."
    return "# Mojo documentation\n\nThe documentation has not been downloaded yet.\n\nPress **D** to download it now, or choose Help > Download documentation. This fetches, from Modular's public repositories on github.com/modular:\n\n- the Mojo manual, the language reference and the cheat sheets\n- the standard library reference (made from the library's sources)\n- the Mojo examples\n- the MAX documentation\n- the courses: Mojo GPU Puzzles, Build an LLM from Scratch, and the workshops\n\nIt needs `git` and about 100 MB, and goes into\n\n`" + home + "`\n\nNothing about you or your project is sent."


__extension App:
    # ----------------------------------------------------------- loading
    def docs_cache_path(self) -> String:
        return self.doc_home + "/.doc_index.cache"

    def docs_cache_stamp(self) -> String:
        var s1 = file_sig(self.doc_home + "/SOURCES.txt")
        var s2 = file_sig(self.doc_home + "/stdref/index.txt")
        return "v1:" + String(s1.size) + ":" + String(s1.mtime_s) + ":" + String(s1.mtime_ns) + ":" + String(s2.size) + ":" + String(s2.mtime_s) + ":" + String(s2.mtime_ns)

    def docs_load(mut self):
        """Read the library (making the standard library pages first if the download is
        newer than they are)."""
        if stdref_stale(self.doc_home):
            var why = stdref_build(self.doc_home)
            if why.byte_length() > 0:
                self.say("Standard library reference: " + why)
        self.doc_lib = DocLibrary()
        # TurboMojo's own book first (written anew: this version's pages, your keys)
        if self.help_dir.byte_length() > 0 and write_help(self.help_dir, self.keys_markdown()):
            self.doc_lib.help_dir = self.help_dir
        self.doc_index = DocIndex()
        var cached = False
        if path_exists(self.doc_home + "/SOURCES.txt"):
            self.doc_lib.load_help_only(self.doc_home)
            cached = self.doc_index.load_cache(self.docs_cache_path(), self.docs_cache_stamp(), self.doc_lib)
        if not cached:
            self.doc_lib.load(self.doc_home)
        self.doc_loaded = True
        if len(self.doc_open_books) == 0 and len(self.doc_lib.pages) > 0:
            self.doc_open_books.append(self.doc_lib.pages[0].title)
        self.docs_rows()

    def keys_markdown(self) -> String:
        var md = String("# Keyboard reference\n\nThe keys as your keymap has them (Options > Keys). Help > Keyboard reference (F1) shows the same in a box; Ctrl-P finds any command by name.\n\n```text\n")
        for l in self.keyboard_lines():
            md += l + "\n"
        return md + "```\n"

    def help_page(mut self, file: String):
        """Help > a page of the TurboMojo book, in the documentation viewer."""
        self.doc_loaded = False                 # (written anew: the keys may have changed)
        self.docs_open()
        var path = self.doc_lib.help_dir + "/" + file
        if self.doc_lib.help_dir.byte_length() == 0 or not path_exists(path):
            self.say("The help pages could not be written" + ((" to " + self.help_dir) if self.help_dir.byte_length() > 0 else String("")))
            return
        if "TurboMojo" not in self.doc_open_books:
            self.doc_open_books.append("TurboMojo")
            self.docs_rows()
        self.docs_show(path, "", True)
        self.doc_focus = 1

    def tutorial_open(mut self) raises:
        """Help > Tutorial: a copy of the tutorial to practise in (a fresh one unless
        the copy is open already)."""
        if self.help_dir.byte_length() == 0:
            self.say("No folder for the tutorial")
            return
        var path = dirname(self.help_dir) + "/tutorial/tutorial.mojo"
        if self.find_editor(path) < 0:
            _ = run_system("mkdir -p " + shell_quote(dirname(path)))
            if not write_file(path, str_bytes(HELP_TUTORIAL)):
                self.say("Could not write " + path)
                return
        self.open_path(path)
        self.say("Your copy of the tutorial: change anything (Help > Tutorial again after closing it makes a fresh one)")

    def doc_head_key(self, k: Int) -> String:
        return self.doc_lib.book_of(k) + "\t" + String(self.doc_lib.pages[k].depth) + "\t" + self.doc_lib.pages[k].title

    def docs_rows(mut self):
        """The lines of the contents: every book, with the chapters of the open ones
        (collapsed sub-headings hide the entries deeper than themselves)."""
        self.doc_rows.clear()
        var open = False
        var closed_depth = 9999
        for k in range(len(self.doc_lib.pages)):
            ref pg = self.doc_lib.pages[k]
            if pg.kind == DK_BOOK:
                open = pg.title in self.doc_open_books
                closed_depth = 9999
                self.doc_rows.append(k)
            elif open:
                if pg.depth > closed_depth:
                    continue
                closed_depth = 9999
                self.doc_rows.append(k)
                if pg.kind == DK_HEADING and self.doc_head_key(k) in self.doc_closed_heads:
                    closed_depth = pg.depth
        self.doc_row = max(0, min(self.doc_row, len(self.doc_rows) - 1))

    def docs_open(mut self):
        """Help > Mojo documentation."""
        if not self.doc_loaded:
            self.docs_load()
        self.mode = M_DOCS
        self.doc_width = 0                  # lay the page out for the screen as it is now
        if self.doc_path.byte_length() == 0 and len(self.doc_lib.pages) > 0:
            self.doc_focus = 0
        self.say("")

    # ----------------------------------------------------------- geometry
    def docs_toc_w(self) -> Int:
        """Width of the contents pane (0 on a screen too narrow for two panes)."""
        if self.scr.w < 64:
            return 0 if self.doc_focus == 1 else self.scr.w
        return max(26, min(40, self.scr.w // 3))

    def docs_text_w(self) -> Int:
        var tw = self.docs_toc_w()
        return max(20, min(DOC_TEXT_MAX, self.scr.w - tw - 6))

    def docs_page_h(self) -> Int:
        return max(1, self.scr.h - 3)

    def docs_layout(mut self):
        """(Re)make the page's lines if the page or the width changed."""
        var w = self.docs_text_w()
        if w == self.doc_width:
            return
        self.doc_width = w
        var md = path_markdown(self.doc_path)
        if self.doc_path.byte_length() == 0 or md.byte_length() == 0:
            md = doc_welcome(self.doc_home, len(self.doc_lib.pages) > self.doc_lib.help_count)
            if self.doc_path.byte_length() > 0:
                md = "# Not found\n\nThe file `" + self.doc_path + "` is no longer there. Help > Download documentation fetches it again."
        self.docs_images_forget()
        self.doc_links.clear()
        self.doc_lines = md_render_rich(md, w, self.hl, self.doc_links, True)
        self.docs_place_images(w)
        self.doc_scroll = max(0, min(self.doc_scroll, max(0, len(self.doc_lines) - 1)))

    # --------------------------------------------------------- navigation
    def docs_show(mut self, path: String, anchor: String, remember: Bool):
        """Put a file into the page pane (at a heading, if `anchor` names one)."""
        if remember and self.doc_path.byte_length() > 0 and (self.doc_path != path):
            self.doc_back.append(String(self.doc_scroll) + "\t" + self.doc_path)
            self.doc_fwd.clear()
        if path != self.doc_path:
            self.doc_scroll = 0
        self.doc_path = path
        self.doc_width = 0
        self.doc_link = -1
        self.docs_layout()
        if anchor.byte_length() > 0:
            for k in range(len(self.doc_lines)):
                if len(self.doc_lines[k].st) > 0 and self.doc_lines[k].st[0] == MD_HEAD and heading_slug(to_str(self.doc_lines[k].cps)) == anchor:
                    self.doc_scroll = k
                    break
        # the contents follow: the page's book opens and its line is marked
        var k = self.doc_lib.find_path(path)
        if k >= 0:
            var book = self.doc_lib.book_of(k)
            var changed_toc = False
            if not (book in self.doc_open_books):
                self.doc_open_books.append(book)
                changed_toc = True
            # reopen any collapsed ancestor heading above page k
            var need_depth = self.doc_lib.pages[k].depth
            var j = k - 1
            while j >= 0 and self.doc_lib.pages[j].kind != DK_BOOK:
                if self.doc_lib.pages[j].kind == DK_HEADING and self.doc_lib.pages[j].depth < need_depth:
                    need_depth = self.doc_lib.pages[j].depth
                    var hk = self.doc_head_key(j)
                    if hk in self.doc_closed_heads:
                        var kept = List[String]()
                        for h0 in self.doc_closed_heads:
                            if h0 != hk:
                                kept.append(h0)
                        self.doc_closed_heads = kept^
                        changed_toc = True
                j -= 1
            if changed_toc:
                self.docs_rows()
            for r in range(len(self.doc_rows)):
                if self.doc_rows[r] == k:
                    self.doc_row = r
        self.docs_toc_follow()

    def docs_toc_follow(mut self):
        var h = self.docs_page_h()
        if self.doc_row < self.doc_toc_top:
            self.doc_toc_top = self.doc_row
        if self.doc_row >= self.doc_toc_top + h:
            self.doc_toc_top = self.doc_row - h + 1
        self.doc_toc_top = max(0, min(self.doc_toc_top, max(0, len(self.doc_rows) - h)))

    def docs_go_back(mut self, forward: Bool):
        var src = self.doc_fwd.copy() if forward else self.doc_back.copy()
        if len(src) == 0:
            self.say("No later page" if forward else "No earlier page")
            return
        var entry = src.pop()
        var here = String(self.doc_scroll) + "\t" + self.doc_path
        if forward:
            self.doc_fwd = src^
            self.doc_back.append(here)
        else:
            self.doc_back = src^
            self.doc_fwd.append(here)
        var tab = entry.find("\t")
        var scroll: Int
        try:
            scroll = atol(String(entry[byte=0:tab]))
        except:
            scroll = 0
        self.docs_show(String(entry[byte=tab + 1:]), "", False)
        self.doc_scroll = max(0, min(scroll, max(0, len(self.doc_lines) - 1)))

    def docs_step(mut self, step: Int):
        """The next or previous page in the order of the books."""
        var k = self.doc_lib.find_path(self.doc_path)
        var to = self.doc_lib.next_page(k, step) if k >= 0 else (self.doc_lib.next_page(-1, 1) if step > 0 else -1)
        if to < 0:
            self.say("This is the last page" if step > 0 else "This is the first page")
            return
        self.doc_mark = ""
        var next_path = self.doc_lib.pages[to].path
        self.docs_show(next_path, "", True)

    def docs_activate_row(mut self):
        """Enter on the marked line of the contents."""
        if self.doc_row < 0 or self.doc_row >= len(self.doc_rows):
            return
        var v = self.doc_rows[self.doc_row]
        var page = self.doc_lib.pages[v].copy()
        if page.kind == DK_BOOK:
            if page.title in self.doc_open_books:
                var kept = List[String]()
                for b in self.doc_open_books:
                    if b != page.title:
                        kept.append(b)
                self.doc_open_books = kept^
            else:
                self.doc_open_books.append(page.title)
            self.docs_rows()
            for r in range(len(self.doc_rows)):
                if self.doc_rows[r] == v:
                    self.doc_row = r
            self.docs_toc_follow()
        elif page.kind == DK_HEADING:
            var hk = self.doc_head_key(v)
            if hk in self.doc_closed_heads:
                var kept = List[String]()
                for h0 in self.doc_closed_heads:
                    if h0 != hk:
                        kept.append(h0)
                self.doc_closed_heads = kept^
            else:
                self.doc_closed_heads.append(hk)
            self.docs_rows()
            for r in range(len(self.doc_rows)):
                if self.doc_rows[r] == v:
                    self.doc_row = r
            self.docs_toc_follow()
        else:
            self.doc_mark = ""
            self.docs_show(page.path, "", True)
            self.doc_focus = 1

    # -------------------------------------------------------------- links
    def docs_link_line(self, id: Int) -> Int:
        """The first line a link stands on (-1 if it is not on the page)."""
        for k in range(len(self.doc_lines)):
            for s in self.doc_lines[k].st:
                if s == -id - 1:
                    return k
        return -1

    def docs_next_link(mut self, step: Int):
        var n = len(self.doc_links)
        if n == 0:
            self.say("This page has no links")
            return
        var id = self.doc_link
        if id < 0:
            # the first one on screen (or after it)
            id = -1 if step > 0 else n
            for cand in range(n):
                var ln = self.docs_link_line(cand)
                if ln >= self.doc_scroll:
                    id = cand - 1 if step > 0 else cand
                    break
        for _ in range(n):
            id = (id + step + n) % n
            var ln = self.docs_link_line(id)
            if ln >= 0:
                self.doc_link = id
                var h = self.docs_page_h()
                if ln < self.doc_scroll or ln >= self.doc_scroll + h:
                    self.doc_scroll = max(0, ln - h // 3)
                var shown = self.doc_links[id]
                self.say(shown)
                return

    # ------------------------------------------------------------- pictures
    def docs_image_file(self, target: String) -> String:
        """The picture of the download a link names, as a path ("" if it is on the web
        or not there)."""
        if not is_image_name(target) or target.find("://") >= 0:
            return ""
        var p = normal_path(join_path(dirname(self.doc_path), target.replace("%20", " ").replace("%29", ")")))
        return p if path_exists(p) else String("")

    def docs_place_images(mut self, w: Int):
        """With pictures on (kitty graphics): after each line that is just a PNG of the
        download, rows for the picture itself (the "[image: ...]" line stays, as its
        caption and link). Larger files, other formats and web pictures stay links."""
        if not self.gfx_on:
            return
        var out = List[MdLine]()
        var max_rows = min(24, max(3, self.docs_page_h() - 2))
        for line in self.doc_lines:
            out.append(line.copy())
            var k = image_only(line)
            if k < 0 or not image_name(self.doc_links[k]).lower().endswith(".png"):
                continue
            var path = self.docs_image_file(self.doc_links[k])
            if path.byte_length() == 0:
                continue
            var data = read_file(path)
            if len(data) > GFX_MAX_BYTES:
                continue
            var size = png_size(data)
            if size[0] < 0:
                continue
            var cells = image_cells(size[0], size[1], min(w, 297), min(max_rows, 297), self.gfx_cell_w, self.gfx_cell_h)
            var six = String("")
            if self.gfx_sixel:
                # decoded now: a picture that cannot be (interlaced, damaged) stays a link
                var pic = png_decode(data)
                if not pic.ok:
                    continue
                var px = fit_pixels(pic.w, pic.h, cells[0] * self.gfx_cell_w, cells[1] * self.gfx_cell_h)
                var bg = self.pal.doc_bg if self.pal.doc_bg >= 0 and self.pal.doc_bg <= 0xFFFFFF else 0
                six = sixel_encode(scale_to(pic, px[0], px[1]), px[0], px[1], bg)
            var idx = len(self.doc_images)
            self.doc_images.append(path)
            self.doc_img_ids.append(0)
            self.doc_img_size.append((cells[0] << 16) | cells[1])
            self.doc_img_sixel.append(six)
            self.doc_img_at.append(-1)
            self.doc_img_vis.append(0)
            self.doc_img_shown.append(-1)
            for r in range(cells[1]):
                var m = MdLine()
                m.img = idx
                m.img_row = r
                for _ in range(cells[0]):
                    m.add(32, MD_TEXT)
                out.append(m^)
        self.doc_lines = out^

    def docs_images_forget(mut self):
        """The page's pictures deleted in the terminal (a new page, another width, the
        end): their memory is freed there too."""
        for id in self.doc_img_ids:
            if id > 0:
                self.gfx_out += kitty_delete(id, self.gfx_tmux)
        for k in range(len(self.doc_img_shown)):
            var at = self.doc_img_shown[k]
            if at >= 0:                 # a sixel picture is wiped by sending its cells again
                self.scr.invalidate(at & 0xFFFF, at >> 16, self.doc_img_size[k] >> 16, self.doc_img_size[k] & 0xFFFF)
        self.doc_images.clear()
        self.doc_img_ids.clear()
        self.doc_img_size.clear()
        self.doc_img_sixel.clear()
        self.doc_img_at.clear()
        self.doc_img_vis.clear()
        self.doc_img_shown.clear()

    def docs_draw_image_row(mut self, line: MdLine, x0: Int, y: Int, bg: Int):
        """One row of a picture: placeholder cells (sent first, when it shows for the
        first time)."""
        var idx = line.img
        var cols = self.doc_img_size[idx] >> 16
        var rows = self.doc_img_size[idx] & 0xFFFF
        if self.gfx_sixel:
            # blank cells; the picture is drawn over them after the frame (sixel_emit)
            self.scr.fill(x0, y, cols, 1, 32, bg, bg)
            self.gfx_page_bg = bg
            if line.img_row == 0:
                self.doc_img_at[idx] = (y << 16) | x0
            self.doc_img_vis[idx] += 1
            return
        if self.doc_img_ids[idx] == 0:
            var id = self.gfx_next
            self.gfx_next = GFX_FIRST_ID if id >= GFX_LAST_ID else id + 1
            self.gfx_out += kitty_transmit(id, read_file(self.doc_images[idx]), cols, rows, self.gfx_tmux)
            self.doc_img_ids[idx] = id
        if len(self.gfx_diac) == 0:
            self.gfx_diac = kitty_diacritics()
        var fg = ANSI_BASE + self.doc_img_ids[idx]
        for c in range(cols):
            self.scr.put(x0 + c, y, PLACEHOLDER, fg, bg)
            self.scr.combine(x0 + c, y, self.gfx_diac[line.img_row])
            self.scr.combine(x0 + c, y, self.gfx_diac[c])

    def sixel_prepare(mut self):
        """Before the frame is sent: a sixel picture that moved or is no longer wholly on
        the page has its old cells sent again (that wipes it); one wholly on the page,
        with nothing drawn over it, is drawn when it moved or its cells were rewritten."""
        self.gfx_emit = ""
        if not self.gfx_sixel:
            return
        for k in range(len(self.doc_images)):
            var cols = self.doc_img_size[k] >> 16
            var rows = self.doc_img_size[k] & 0xFFFF
            var at = self.doc_img_at[k]
            var cur = at if at >= 0 and self.doc_img_vis[k] == rows and (at >> 16) + rows < self.scr.h else -1
            var old = self.doc_img_shown[k]
            if old >= 0 and old != cur:
                self.scr.invalidate(old & 0xFFFF, old >> 16, cols, rows)
            if cur >= 0:
                var x = cur & 0xFFFF
                var y = cur >> 16
                if not self.scr.blank_in(x, y, cols, rows, self.gfx_page_bg):
                    self.doc_img_shown[k] = -1      # something lies over it: drawn when it goes
                elif old != cur or self.scr.changed_in(x, y, cols, rows):
                    self.gfx_emit += "\x1b[" + String(y + 1) + ";" + String(x + 1) + "H" + self.doc_img_sixel[k]
                    self.doc_img_shown[k] = cur
            else:
                self.doc_img_shown[k] = -1
            self.doc_img_at[k] = -1
            self.doc_img_vis[k] = 0

    def sixel_take(mut self) -> String:
        """After the frame: the sixel pictures to send, then the cursor back where the
        frame left it (a sixel moves it)."""
        if self.gfx_emit.byte_length() == 0:
            return ""
        var out = "\x1b[?25l" + self.gfx_emit
        self.gfx_emit = ""
        if self.scr.sent_x >= 0 and self.scr.sent_y >= 0:
            out += "\x1b[" + String(self.scr.sent_y + 1) + ";" + String(self.scr.sent_x + 1) + "H"
        if self.scr.sent_vis == 1:
            out += "\x1b[?25h"
        return out

    def docs_follow(mut self, id: Int):
        if id < 0 or id >= len(self.doc_links):
            return
        var target = self.doc_links[id]
        if is_image_name(target) and target.find("://") < 0:
            # a picture of the download: where it is
            var p = self.docs_image_file(target)
            if p.byte_length() > 0:
                self.osc52(decode(p))
                self.say("An image (copied to the clipboard): " + p)
            else:
                self.say("That image is not part of the download: " + target)
            return
        var to = self.doc_lib.resolve_link(self.doc_path, target)
        if to[0].byte_length() > 0:
            self.doc_mark = ""
            self.docs_show(to[0], to[1], True)
            return
        if target.find("://") > 0:
            self.osc52(decode(target))
            self.say("A web address (copied to the clipboard): " + target)
        else:
            self.say("That page is not part of the download: " + target)

    # ------------------------------------------------------------- finder
    def docs_index_ready(mut self):
        """The library and its index, made when first needed."""
        if not self.doc_loaded:
            self.docs_load()
        if not self.doc_index.built:
            self.doc_index.build(self.doc_lib)
            if path_exists(self.doc_home + "/SOURCES.txt"):
                _ = self.doc_index.save_cache(self.docs_cache_path(), self.docs_cache_stamp(), self.doc_lib)

    def docs_find_dialog(mut self, start: String):
        """Help > Find in documentation: one field, results as you type. Words must all
        be on the line; "a phrase"; -word leaves lines out; @name looks among the
        standard library's declarations, #word among titles and headings, `word in
        code examples; in:book stays in one book."""
        self.docs_index_ready()
        if len(self.doc_lib.pages) == 0:
            self.docs_open()                # nothing downloaded: the reader says how to get it
            return
        self.doc_find_back = self.mode == M_DOCS
        var d = Dialog(D_DOCFIND, "Find in Documentation", min(112, self.scr.w - 4), min(30, self.desk_h()))
        d.lines.append("words  \"a phrase\"  -without  @api  #heading  `code  in:book  - or a name, a.dotted.path, an error line")
        d.fields.append(Field("~F~ind", start))
        d.list_filter = True
        d.use_pat = True
        d.buttons.append("~G~o")
        d.buttons.append("~C~ancel")
        self.show(d^)
        self.doc_find_text = "\x01"
        self.docs_find_refresh()

    def docs_find_refresh(mut self):
        """After every key in the finder: the results for what the field holds now."""
        var text = self.dlg.field_text(0)
        if text == self.doc_find_text:
            return
        self.doc_find_text = text
        var shape = query_shape(text)
        var q = parse_query(finder_query(text))
        self.doc_found = find_help(self.doc_index, self.doc_lib, q, DOC_FIND_MAX)
        if shape == QS_NAME:
            # a plain word may be a name or just a word: the declarations, then the text
            for f in find_help(self.doc_index, self.doc_lib, parse_query(text), DOC_FIND_MAX):
                var dup = False
                for g in self.doc_found:
                    if g.entry == f.entry:
                        dup = True
                        break
                if not dup and len(self.doc_found) < DOC_FIND_MAX:
                    self.doc_found.append(f.copy())
        if shape == QS_PATH:
            self.doc_found = by_owner(self.doc_found, self.doc_index, path_parts(text))
            # dotted module paths (`std.collections.list`, `std.testing`) match module pages directly
            var dotted = lower_str(String(text.strip()))
            var exact_mods = List[Found]()
            var suffix_mods = List[Found]()
            var pkg_mods = List[Found]()
            for idx in range(len(self.doc_index.entries)):
                if self.doc_index.entries[idx].kind != IK_TITLE:
                    continue
                var pg = self.doc_index.entries[idx].page
                var ppath = self.doc_lib.pages[pg].path
                if (ppath.find("/stdref/") >= 0 or ppath.find("/maxref/") >= 0) and ppath.endswith(".md"):
                    var bn = basename(ppath)
                    var mod = lower_str(cut(bn, 0, bn.byte_length() - 3))
                    if mod == dotted:
                        exact_mods.append(Found(idx, 2200))
                    elif mod.endswith("." + dotted):
                        suffix_mods.append(Found(idx, 1800))
                    elif mod.startswith(dotted + "."):
                        pkg_mods.append(Found(idx, 1200))
            if len(exact_mods) > 0 or len(suffix_mods) > 0 or len(pkg_mods) > 0:
                var merged = List[Found]()
                for m0 in exact_mods:
                    merged.append(m0.copy())
                for m1 in suffix_mods:
                    merged.append(m1.copy())
                for f0 in self.doc_found:
                    var dup = False
                    for m2 in merged:
                        if m2.entry == f0.entry:
                            dup = True
                            break
                    if not dup and len(merged) < DOC_FIND_MAX:
                        merged.append(f0.copy())
                for m3 in pkg_mods:
                    var dup = False
                    for m4 in merged:
                        if m4.entry == m3.entry:
                            dup = True
                            break
                    if not dup and len(merged) < DOC_FIND_MAX:
                        merged.append(m3.copy())
                self.doc_found = merged^
        var items = List[String]()
        var data = List[Int]()
        var room = max(30, self.dlg.w - 44)
        # first what is not in the documentation's pages: the explanation of a pasted
        # error, and the commands whose names fit (as the palette would find them)
        if shape == QS_ERROR:
            var page = explain_for(error_text(text))
            if page >= 0:
                items.append("! Explanation: " + err_title(page) + "  (F1 on the problem shows it too)")
                data.append(FIND_EXPLAIN - page)
        if shape == QS_WORDS or shape == QS_NAME:
            var low = lower_str(String(text.strip()))
            var n = 0
            if low.byte_length() >= 3 and not (low.startswith("@") or low.startswith("#") or low.startswith("`")):
                for c in self.reg.cmds:
                    if n >= 3 or self.reg.is_hidden(c.id):
                        continue
                    if lower_str(plain(c.title)).find(low) >= 0 or lower_str(c.name).find(low) >= 0:
                        var keys = self.reg.key_label(c.id)
                        items.append("> Command: " + plain(c.title) + ("   " + keys if keys.byte_length() > 0 else String("")))
                        data.append(FIND_COMMAND - c.id)
                        n += 1
        var signs = ["ƒ", "▤", "§", "·", "›"]
        var texts = Dict[Int, String]()
        var answered = 0
        for k in range(len(self.doc_found)):
            var e = self.doc_index.entries[self.doc_found[k].entry].copy()
            var what = e.text
            if e.kind == IK_TITLE:
                var ppath = self.doc_lib.pages[e.page].path
                if (ppath.find("/stdref/") >= 0 or ppath.find("/maxref/") >= 0) and ppath.endswith(".md"):
                    var bn = basename(ppath)
                    what = cut(bn, 0, bn.byte_length() - 3)
            if e.kind == IK_API and e.owner.byte_length() > 0:
                what = e.owner + "." + e.text
            if e.kind == IK_API and answered < FIND_ANSWERS:
                # a one-line answer: the first sentence the declaration's section says
                answered += 1
                if e.page not in texts:
                    texts[e.page] = path_markdown(self.doc_lib.pages[e.page].path)
                var said = first_prose(md_section(texts.get(e.page, ""), e.text, e.nth))
                if said.byte_length() > 0:
                    what += " - " + said
            if cp_len(what) > room:
                what = slice_str(decode(what), 0, room - 1) + "…"
            var where = self.doc_lib.pages[e.page].title
            var book = self.doc_lib.book_of(e.page)
            if book.startswith("Course: "):
                book = slice_str(decode(book), 8, cp_len(book))
            items.append(String(signs[e.kind]) + " " + pad_right(what, room) + " " + where + " · " + book)
            data.append(k)
        if len(items) == 0:
            items.append("  (type what you are looking for)" if q.empty() else "  nothing found - fewer or other words?")
            data.append(-1)
        self.dlg.pat = ""
        self.dlg.set_items(items^, data^)

    def docs_find_go(mut self, sel: Int) raises:
        """Enter in the finder: the reader opens at the place (or the explanation, or
        the command, that the row names)."""
        var k = self.dlg.item_data[sel] if sel >= 0 and sel < len(self.dlg.item_data) else -1
        if k <= FIND_EXPLAIN and k > FIND_COMMAND:
            self.mode = M_NORMAL
            self.explain_open(FIND_EXPLAIN - k, "")
            return
        if k <= FIND_COMMAND:
            self.mode = M_NORMAL
            self.exec(FIND_COMMAND - k)
            self.key_echo(FIND_COMMAND - k)
            return
        if k < 0 or k >= len(self.doc_found):
            if self.doc_find_back:
                self.mode = M_DOCS
            return
        var q = parse_query(self.doc_find_text)
        self.doc_mark = q.need[0] if len(q.need) > 0 else String("")
        self.docs_goto_entry(self.doc_found[k].entry)

    def docs_goto_entry(mut self, n: Int):
        """Open the reader on an entry of the index, scrolled to it."""
        var e = self.doc_index.entries[n].copy()
        var path = self.doc_lib.pages[e.page].path
        if self.mode != M_DOCS:
            self.docs_open()
        self.docs_show(path, "", True)
        self.doc_focus = 1
        var line = 0
        if e.kind == IK_API or e.kind == IK_HEADING:
            # the n-th heading with that text
            var seen = 0
            for r in range(len(self.doc_lines)):
                if len(self.doc_lines[r].st) > 0 and self.doc_lines[r].st[0] == MD_HEAD and to_str(self.doc_lines[r].cps) == e.text:
                    if seen == e.nth:
                        line = r
                        break
                    seen += 1
        elif e.kind >= IK_TEXT:
            # the line as it was laid out: by its beginning, else by the word looked for
            var head = slice_str(decode(e.low), 0, min(24, cp_len(e.low)))
            var word = self.doc_mark.lower()
            var by_word = -1
            for r in range(len(self.doc_lines)):
                var low = to_str(self.doc_lines[r].cps).lower()
                if low.find(head) >= 0:
                    line = r
                    by_word = -2
                    break
                if by_word == -1 and word.byte_length() > 0 and low.find(word) >= 0:
                    by_word = r
            if by_word >= 0:
                line = by_word
        self.doc_scroll = max(0, line - (0 if e.kind <= IK_HEADING else 3))

    def docs_api_lookup(mut self, name: String, load: Bool, owner_hint: String = "") -> Bool:
        """Topic search for a name of the standard library: straight to its page if
        the name is declared once, the finder with the candidates if several times.
        False if the downloaded documentation does not know it. Without `load` only an
        index that is already there (or a warm disk cache in interactive runs) is used."""
        if load or (not self.doc_index.built and self.help_dir.byte_length() > 0 and path_exists(self.docs_cache_path())):
            self.docs_index_ready()
        if not self.doc_index.built or name.byte_length() == 0:
            return False
        var found = find_help(self.doc_index, self.doc_lib, parse_query("@" + name), 40)
        var exact = List[Int]()
        var low = name.lower()
        for f in found:
            var e = self.doc_index.entries[f.entry].copy()
            var last = e.low
            var sp = last.rfind(" ")
            if sp >= 0:
                last = cut(last, sp + 1, -1)
            if last == low:
                exact.append(f.entry)
        if len(exact) == 0:
            return False
        if len(exact) > 1 and owner_hint.byte_length() > 0:
            var olow = owner_hint.lower()
            var owned = List[Int]()
            for idx in exact:
                if self.doc_index.entries[idx].owner.lower() == olow:
                    owned.append(idx)
            if len(owned) == 1:
                self.doc_mark = ""
                self.docs_goto_entry(owned[0])
                return True
            if len(owned) > 1:
                self.docs_find_dialog(owner_hint + "." + name)
                return True
        if len(exact) == 1:
            self.doc_mark = ""
            self.docs_goto_entry(exact[0])
            return True
        self.docs_find_dialog("@" + name)
        return True

    def docs_try(mut self, file: String) raises -> Bool:
        """Open a program of the documentation - a lesson, an example - as the reader's
        own copy, to change and run: it is copied (with the files beside it) into the
        practice folder next to the download the first time; later the copy that is
        there opens, with whatever was changed in it. False if no copy could be made."""
        var home = self.doc_home
        var mine = practice_path(home, file)
        if mine.byte_length() == 0:
            return False
        var fresh = not path_exists(mine)
        if fresh:
            _ = run_system("mkdir -p " + shell_quote(dirname(mine)))
            for n in list_dir(dirname(file)):
                if n.endswith("/"):
                    continue
                var to = join_path(dirname(mine), n)
                if not path_exists(to):
                    _ = write_file(to, read_file(join_path(dirname(file), n)))
            if not path_exists(mine):
                return False
        self.mode = M_NORMAL
        self.open_path(mine)
        if mine.find("/" + PUZZLES_DIR + "/problems/") > 0:
            self.say("Your copy of " + basename(mine) + " - fill it in, Ctrl-F9 runs it, Help > Exercise done? checks your answer")
        elif fresh:
            self.say("Your own copy of " + basename(mine) + " - change it, Ctrl-F9 runs it")
        else:
            self.say("Your copy of " + basename(mine) + ", as you left it - Ctrl-F9 runs it")
        return True

    def open_scratch_snippet(mut self, code: String, label: String) raises:
        """Open `code` in a new scratch Mojo buffer so the user can edit or run it."""
        var trimmed_code = code
        while trimmed_code.endswith("\n\n"):
            trimmed_code = cut(trimmed_code, 0, trimmed_code.byte_length() - 1)
        if not trimmed_code.endswith("\n"):
            trimmed_code += "\n"
        self.mode = M_NORMAL
        self.untitled_n += 1
        var title = "snippet-" + String(self.untitled_n) + ".mojo"
        var ei = self.new_editor(title, "")
        self.wins[ei].buf.load(decode(trimmed_code))
        self.wins[ei].buf.modified = False
        self.focus(ei)
        var can_run = trimmed_code.find("def main") >= 0
        self.say("Opened " + label + " in " + title + (" - save & Ctrl-F9 to run" if can_run else " - add def main() to run"))

    def docs_visible_snippet(self) -> String:
        """Code block currently in view on the reader's page ('' if there is none)."""
        var best_below = String("")
        var last_above = String("")
        var r = 0
        var n = len(self.doc_lines)
        while r < n:
            if len(self.doc_lines[r].st) > 0 and self.doc_lines[r].st[0] >= MD_BLOCK:
                var start = r
                var block = String("")
                while r < n and len(self.doc_lines[r].st) > 0 and self.doc_lines[r].st[0] >= MD_BLOCK:
                    block += to_str(self.doc_lines[r].cps) + "\n"
                    r += 1
                if r > self.doc_scroll and best_below.byte_length() == 0:
                    best_below = block
                if start <= self.doc_scroll:
                    last_above = block
            else:
                r += 1
        if best_below.byte_length() > 0:
            return best_below^
        if last_above.byte_length() > 0:
            return last_above^
        var blocks = md_mojo_blocks(path_markdown(self.doc_path))
        if len(blocks) > 0:
            return blocks[0]
        return ""

    def docs_page_find_dialog(mut self):
        """Ctrl-F in the reader: search text on the current page."""
        self.docs_layout()
        var seed = self.doc_page_query if self.doc_page_query.byte_length() > 0 else self.doc_mark
        var d = Dialog(D_DOC_PAGEFIND, "Find on This Page", min(60, self.scr.w - 4), 8)
        d.fields.append(Field("~F~ind", seed))
        d.fields[0].fresh = True
        d.buttons.append("~F~ind")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def docs_page_jump(mut self, step: Int, advance: Bool):
        """Jump to the next (`step = 1`) or previous (`step = -1`) match of `doc_mark`
        on the current page."""
        var pat = self.doc_mark if self.doc_mark.byte_length() > 0 else self.doc_page_query
        if pat.byte_length() == 0:
            self.docs_page_find_dialog()
            return
        self.doc_mark = pat
        self.doc_page_query = pat
        self.docs_layout()
        var low_pat = pat.lower()
        var hits = List[Int]()
        for r in range(len(self.doc_lines)):
            if to_str(self.doc_lines[r].cps).lower().find(low_pat) >= 0:
                hits.append(r)
        if len(hits) == 0:
            self.say("Not found on this page: " + pat)
            return
        var pick: Int
        if step > 0:
            var threshold = self.doc_scroll + (1 if advance else 0)
            pick = 0
            for i in range(len(hits)):
                if hits[i] >= threshold:
                    pick = i
                    break
        else:
            var threshold = self.doc_scroll - (1 if advance else 0)
            pick = len(hits) - 1
            var i = len(hits) - 1
            while i >= 0:
                if hits[i] <= threshold:
                    pick = i
                    break
                i -= 1
        self.doc_focus = 1
        self.doc_scroll = hits[pick]
        self.say("Match " + String(pick + 1) + " of " + String(len(hits)) + " (F3 / Shift-F3 for next/previous)")

    def docs_headings_dialog(mut self):
        """G / @ in the reader: jump to any heading on the current page."""
        self.docs_layout()
        var items = List[String]()
        var data = List[Int]()
        var cur_sel = 0
        for r in range(len(self.doc_lines)):
            if len(self.doc_lines[r].st) == 0 or self.doc_lines[r].st[0] != MD_HEAD:
                continue
            if r > 0 and len(self.doc_lines[r - 1].st) > 0 and self.doc_lines[r - 1].st[0] == MD_HEAD:
                continue
            var indent = String("    ")
            if r + 1 < len(self.doc_lines) and len(self.doc_lines[r + 1].cps) > 0:
                if self.doc_lines[r + 1].cps[0] == 0x2550:
                    indent = ""
                elif self.doc_lines[r + 1].cps[0] == 0x2500:
                    indent = "  "
            items.append(indent + to_str(self.doc_lines[r].cps))
            data.append(r)
            if r <= self.doc_scroll + 2:
                cur_sel = len(items) - 1
        if len(items) == 0:
            self.say("This page has no headings")
            return
        var d = Dialog(D_DOC_HEADINGS, "On This Page", min(72, self.scr.w - 4), min(24, max(10, len(items) + 8)))
        d.fields.append(Field("~H~eading", ""))
        d.list_filter = True
        d.set_items(items^, data^)
        d.list_sel = cur_sel
        d.buttons.append("~G~o")
        d.buttons.append("~C~ancel")
        self.show(d^)

    # --------------------------------------------------------------- keys
    def docs_hints(self) -> List[String]:
        var out = List[String]()
        if self.doc_focus == 0:
            out.append("~Enter~ Open")
            out.append("~Tab~ Page")
        else:
            out.append("~Tab~ Links")
            out.append("~Enter~ Follow")
            out.append("~←~ Contents")
            out.append("~N~/~P~ Next/Prev")
            out.append("~Bksp~ Back")
            if is_source_path(self.doc_path):
                out.append("~O~ Try it")
            else:
                out.append("~O~ Open file")
            out.append("~G~ Headings")
            out.append("~C~/~T~ Code")
        out.append("~/~ Find")
        out.append("~Esc~ Close")
        return out^

    def docs_key(mut self, k: Int) raises:
        var h = self.docs_page_h()
        if k == KEY_ESC or k == 113 or k == 81:
            self.mode = M_NORMAL
            return
        if k == 47:
            self.docs_find_dialog("")
            return
        if k == ctrl(102):
            self.docs_page_find_dialog()
            return
        if k == fkey(3) or k == ctrl(108):
            self.docs_page_jump(1, True)
            return
        if k == (fkey(3) | MOD_SHIFT):
            self.docs_page_jump(-1, True)
            return
        if k == 103 or k == 71 or k == 64:
            self.docs_headings_dialog()
            return
        if (k == 100 or k == 68) and len(self.doc_lib.pages) == 0:
            self.mode = M_NORMAL
            self.docs_fetch_ask()
            return
        if k == KEY_BACKSPACE or k == 98 or k == 66:
            self.docs_go_back(False)
            return
        if k == 102 or k == 70:
            self.docs_go_back(True)
            return
        if k == 110 or k == 78:
            self.docs_step(1)
            return
        if k == 112 or k == 80:
            self.docs_step(-1)
            return
        if (k == 111 or k == 79) and self.doc_path.byte_length() > 0 and path_exists(self.doc_path):
            var file = self.doc_path
            if is_source_path(file) and self.docs_try(file):
                return
            self.mode = M_NORMAL
            self.open_path(file)
            self.say("Opened " + basename(file) + " from the documentation - save changes under another name")
            return
        if self.doc_focus == 1 and (k == 99 or k == 67):
            var code = self.docs_visible_snippet()
            if code.byte_length() == 0:
                self.say("No code block on this page")
            else:
                var cps = decode(code)
                self.clipboard = cps.copy()
                self.osc52(cps)
                self.say("Copied code block to the clipboard")
            return
        if self.doc_focus == 1 and (k == 116 or k == 84):
            var dpath = self.doc_path
            if is_source_path(dpath) and path_exists(dpath) and self.docs_try(dpath):
                return
            var code = self.docs_visible_snippet()
            if code.byte_length() == 0:
                self.say("No code block on this page")
            else:
                self.open_scratch_snippet(code, "code snippet")
            return
        if self.doc_focus == 0:
            var n = len(self.doc_rows)
            if k == KEY_UP:
                self.doc_row = max(0, self.doc_row - 1)
            elif k == KEY_DOWN:
                self.doc_row = min(n - 1, self.doc_row + 1)
            elif k == KEY_PGUP:
                self.doc_row = max(0, self.doc_row - h)
            elif k == KEY_PGDN:
                self.doc_row = min(n - 1, self.doc_row + h)
            elif k == KEY_HOME:
                self.doc_row = 0
            elif k == KEY_END:
                self.doc_row = n - 1
            elif k == KEY_ENTER or k == KEY_RIGHT or k == 32:
                self.docs_activate_row()
            elif k == KEY_LEFT:
                # to the book this line belongs to
                var r = self.doc_row
                while r > 0 and self.doc_lib.pages[self.doc_rows[r]].kind != DK_BOOK:
                    r -= 1
                self.doc_row = r
            elif k == KEY_TAB:
                self.doc_focus = 1
            self.doc_row = max(0, self.doc_row)
            self.docs_toc_follow()
            return
        var most = max(0, len(self.doc_lines) - h)
        if k == KEY_UP:
            self.doc_scroll = max(0, self.doc_scroll - 1)
        elif k == KEY_DOWN:
            self.doc_scroll = min(most, self.doc_scroll + 1)
        elif k == KEY_PGUP:
            self.doc_scroll = max(0, self.doc_scroll - (h - 1))
        elif k == KEY_PGDN or k == 32:
            self.doc_scroll = min(most, self.doc_scroll + (h - 1))
        elif k == KEY_HOME:
            self.doc_scroll = 0
        elif k == KEY_END:
            self.doc_scroll = most
        elif k == KEY_TAB:
            self.docs_next_link(1)
        elif k == (KEY_TAB | MOD_SHIFT):
            self.docs_next_link(-1)
        elif k == KEY_ENTER:
            if self.doc_link >= 0:
                self.docs_follow(self.doc_link)
            else:
                self.docs_next_link(1)
        elif k == KEY_LEFT:
            self.doc_focus = 0

    def docs_mouse(mut self, e: Event) raises:
        var tw = self.docs_toc_w()
        var h = self.docs_page_h()
        var in_toc = e.mx < tw
        if e.button == MB_WHEEL_UP or e.button == MB_WHEEL_DOWN:
            var d = -3 if e.button == MB_WHEEL_UP else 3
            if in_toc:
                self.doc_toc_top = max(0, min(max(0, len(self.doc_rows) - h), self.doc_toc_top + d))
            else:
                self.doc_scroll = max(0, min(max(0, len(self.doc_lines) - h), self.doc_scroll + d))
            return
        if e.button != MB_LEFT or not e.pressed or e.drag:
            return
        var row = e.my - 2
        if row < 0 or row >= h:
            return
        if in_toc:
            var r = self.doc_toc_top + row
            if r < len(self.doc_rows):
                self.doc_row = r
                self.doc_focus = 0
                self.docs_activate_row()
            return
        self.doc_focus = 1
        var ln = self.doc_scroll + row
        if ln >= len(self.doc_lines):
            return
        # the character under the mouse: is it part of a link?
        var x = tw + (3 if tw > 0 else 2)
        for q in range(len(self.doc_lines[ln].cps)):
            var cw = max(1, char_width(self.doc_lines[ln].cps[q]))
            if e.mx >= x and e.mx < x + cw:
                if self.doc_lines[ln].st[q] < 0:
                    self.docs_follow(-self.doc_lines[ln].st[q] - 1)
                return
            x += cw

    # ------------------------------------------------------------ drawing
    def draw_docs(mut self):
        """The reader over the desktop: a title line, the contents, the page."""
        self.docs_layout()
        var p = self.pal.copy()
        var W = self.scr.w
        var h = self.docs_page_h()
        var tw = self.docs_toc_w()
        self.scr.no_clip()
        self.scr.fill(0, 1, W, self.scr.h - 2, 32, p.doc_fg, p.doc_bg)
        # ---- title line: where we are
        self.scr.fill(0, 1, W, 1, 32, p.doc_bg, p.doc_dim)
        var k = self.doc_lib.find_path(self.doc_path)
        var where = String(" Mojo Documentation")
        if k >= 0:
            where += "  ›  " + self.doc_lib.book_of(k) + "  ›  " + self.doc_lib.pages[k].title
        elif self.doc_path.byte_length() > 0:
            where += "  ›  " + basename(self.doc_path)
        self.scr.clip(0, 1, W, 1)
        _ = self.scr.text(0, 1, where, p.doc_bold, p.doc_dim)
        self.scr.no_clip()
        # ---- the contents
        if tw > 0:
            self.scr.clip(0, 2, tw, h)
            for r in range(h):
                var i = self.doc_toc_top + r
                if i >= len(self.doc_rows):
                    break
                var v = self.doc_rows[i]
                var text = String("")
                var fg = p.doc_fg
                var page = self.doc_lib.pages[v].copy()
                for _ in range(min(page.depth, 6)):
                    text += "  "
                if page.kind == DK_BOOK:
                    text = (" ▾ " if page.title in self.doc_open_books else " ▸ ") + page.title
                    fg = p.doc_bold
                elif page.kind == DK_HEADING:
                    text += ("▸ " if self.doc_head_key(v) in self.doc_closed_heads else "▾ ") + page.title
                    fg = p.doc_dim
                else:
                    text += (" › " if page.path == self.doc_path else "   ") + page.title
                var bg = p.doc_bg
                if i == self.doc_row:
                    # the marked line: strong while the contents have the keyboard
                    bg = p.doc_bold if self.doc_focus == 0 else p.doc_dim
                    fg = p.doc_bg
                    self.scr.fill(0, 2 + r, tw, 1, 32, fg, bg)
                _ = self.scr.text(0, 2 + r, text, fg, bg)
            self.scr.no_clip()
            for r in range(h):
                self.scr.put(tw, 2 + r, 0x2502, p.doc_dim, p.doc_bg)
        if tw >= W:
            return                          # a narrow screen: one pane at a time
        # ---- the page
        var x0 = tw + (3 if tw > 0 else 2)
        var textw = self.doc_width
        self.doc_scroll = max(0, min(self.doc_scroll, max(0, len(self.doc_lines) - h)))
        var mark = decode(self.doc_mark.lower())
        self.scr.clip(x0 - 1, 2, W - x0, h)
        for r in range(h):
            var ln = self.doc_scroll + r
            if ln >= len(self.doc_lines):
                break
            var line = self.doc_lines[ln].copy()
            if line.img >= 0:
                self.docs_draw_image_row(line, x0, 2 + r, p.doc_bg)
                continue
            var block = len(line.st) > 0 and line.st[0] >= MD_BLOCK
            if block:
                self.scr.fill(x0 - 1, 2 + r, min(textw + 2, W - x0), 1, 32, p.ed_fg, p.ed_bg)
            # where the search words stand on this line
            var marked = List[Bool]()
            for _ in range(len(line.cps)):
                marked.append(False)
            if len(mark) > 0 and len(line.cps) >= len(mark):
                var low = decode(to_str(line.cps).lower())
                if len(low) == len(line.cps):
                    var a = 0
                    while a + len(mark) <= len(low):
                        var same = True
                        for z in range(len(mark)):
                            if low[a + z] != mark[z]:
                                same = False
                                break
                        if same:
                            for z in range(len(mark)):
                                marked[a + z] = True
                            a += len(mark)
                        else:
                            a += 1
            var xx = x0
            for q in range(len(line.cps)):
                var st = line.st[q]
                var fg = p.doc_fg
                var bg = p.doc_bg
                if st >= MD_BLOCK:
                    fg = p.syn[st - MD_BLOCK]
                    bg = p.ed_bg
                elif st == MD_BOLD or st == MD_HEAD:
                    fg = p.doc_bold
                elif st == MD_CODE:
                    fg = p.doc_code
                elif st == MD_ITALIC or st == MD_DIM or st == MD_STRIKE:
                    fg = p.doc_dim
                if st < 0 and -st - 1 == self.doc_link:
                    fg = p.doc_bg
                    bg = p.doc_bold                 # the link under Enter
                elif marked[q]:
                    fg = p.match_fg
                    bg = p.match_bg
                var at = xx
                xx = self.scr.draw_cp(xx, 2 + r, line.cps[q], fg, bg)
                if xx > at and not self.scr.plain:
                    if st == MD_ITALIC:
                        self.scr.italic(at, 2 + r, xx - at)
                    elif st == MD_DIM:
                        self.scr.dim(at, 2 + r, xx - at)
                    elif st == MD_STRIKE:
                        self.scr.strikethrough(at, 2 + r, xx - at)
                if (st < 0 or st == MD_LINK) and xx > at:
                    self.scr.underline(at, 2 + r, False, fg)
        self.scr.no_clip()
        # ---- how far down the page we are
        var n = len(self.doc_lines)
        if n > h:
            var thumb = max(1, h * h // n)
            var top = (h - thumb) * self.doc_scroll // max(1, n - h)
            for r in range(h):
                self.scr.put(W - 1, 2 + r, 0x2588 if (r >= top and r < top + thumb) else 0x2591, p.doc_dim, p.doc_bg)
    # ----------------------------------------------------------- download
    def docs_fetch_ask(mut self):
        """Help > Download documentation."""
        var d = Dialog(D_DOCFETCH, "Download Documentation", min(72, self.scr.w - 4), 13)
        d.lines.append("Download the Mojo documentation from Modular's public")
        d.lines.append("repositories (github.com/modular)?")
        d.lines.append("")
        d.lines.append("Manual, reference, standard library, examples, MAX docs and")
        d.lines.append("courses - about 100 MB, with git, into")
        d.lines.append("  " + self.doc_home)
        d.lines.append("Nothing about you or your project is sent.")
        d.buttons.append("~D~ownload")
        d.buttons.append("~C~ancel")
        self.show(d^)

    def docs_fetch(mut self):
        if self.job_busy():
            return
        if self.doc_home.byte_length() == 0:
            self.say("No folder for the documentation is known (set tools.docs_home)")
            return
        if run_system("mkdir -p " + shell_quote(self.doc_home)) != 0:
            self.say("Cannot create " + self.doc_home)
            return
        var script = self.doc_home + "/.fetch-docs.sh"
        if not write_file(script, str_bytes(String(FETCH_SCRIPT))):
            self.say("Cannot write to " + self.doc_home)
            return
        # `mojo` (for the standard library reference) is found next to the compiler in use
        var tools = dirname(which(self.compiler))
        var cmd = String("")
        if tools.byte_length() > 0:
            cmd = "export PATH=" + shell_quote(tools) + ":\"$PATH\"; "
        cmd += self.tool("sh " + shell_quote(script) + " " + shell_quote(self.doc_home)) + " 2>&1 </dev/null"
        var home = self.doc_home
        if self.start_job(JOB_DOCS, cmd, home, "documentation"):
            self.task_output("Downloading...")
            self.say("Downloading the documentation - keep working, Ctrl-F2 cancels")

    def docs_fetched(mut self, status: Int):
        var ok = status == 0 and not self.job.cancelled
        var result = String("The documentation is downloaded - Help > Mojo documentation (" + self.reg.key_label(CM_MOJODOCS) + ")")
        if self.job.cancelled:
            result = "Download cancelled"
        elif not ok:
            result = "The download did not finish completely (see above); what arrived can be read"
        self.task_output(result)
        var mi = self.msg_index()
        if mi >= 0:
            self.wins[mi].cr = self.wins[mi].buf.count() - 1
            self.wins[mi].follow = True
        self.doc_loaded = False             # read the folder again at the next opening
        self.doc_path = ""
        self.say(result)
