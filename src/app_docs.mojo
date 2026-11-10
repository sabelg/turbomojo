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


comptime DOC_FIND_MAX = 150         # results the finder lists
comptime DOC_TEXT_MAX = 96          # the widest a page's text is laid out


def doc_welcome(home: String, have: Bool) -> String:
    """What the page pane shows before a page is chosen."""
    if have:
        return "# Mojo documentation\n\nChoose a book and a page in the contents on the left.\n\n- **Enter** opens what is marked; on a book it shows or hides its chapters\n- **Tab** moves between the contents and the page; on a page it steps through the links, **Enter** follows one\n- **/** opens the finder: words, phrases in quotes, @names of the standard library, #headings\n- **N** and **P** go to the next and the previous page, **Backspace** goes back\n- **O** on a lesson or an example opens your own copy of it in the editor: change it, **Ctrl-F9** runs it\n- **Esc** returns to the editor\n\nThe documentation is Modular's, downloaded from their public repositories into\n\n`" + home + "`\n\nHelp > Download documentation updates it."
    return "# Mojo documentation\n\nThe documentation has not been downloaded yet.\n\nPress **D** to download it now, or choose Help > Download documentation. This fetches, from Modular's public repositories on github.com/modular:\n\n- the Mojo manual, the language reference and the cheat sheets\n- the standard library reference (made from the library's sources)\n- the Mojo examples\n- the MAX documentation\n- the courses: Mojo GPU Puzzles, Build an LLM from Scratch, and the workshops\n\nIt needs `git` and about 100 MB, and goes into\n\n`" + home + "`\n\nNothing about you or your project is sent."


__extension App:
    # ----------------------------------------------------------- loading
    def docs_load(mut self):
        """Read the library (making the standard library pages first if the download is
        newer than they are)."""
        if stdref_stale(self.doc_home):
            var why = stdref_build(self.doc_home)
            if why.byte_length() > 0:
                self.say("Standard library reference: " + why)
        self.doc_lib = DocLibrary()
        self.doc_lib.load(self.doc_home)
        self.doc_loaded = True
        self.doc_index = DocIndex()
        if len(self.doc_open_books) == 0 and len(self.doc_lib.pages) > 0:
            self.doc_open_books.append(self.doc_lib.pages[0].title)
        self.docs_rows()

    def docs_rows(mut self):
        """The lines of the contents: search results first (if any), then every book,
        with the chapters of the open ones."""
        self.doc_rows.clear()
        var open = False
        for k in range(len(self.doc_lib.pages)):
            if self.doc_lib.pages[k].kind == DK_BOOK:
                open = self.doc_lib.pages[k].title in self.doc_open_books
                self.doc_rows.append(k)
            elif open:
                self.doc_rows.append(k)
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
            md = doc_welcome(self.doc_home, len(self.doc_lib.pages) > 0)
            if self.doc_path.byte_length() > 0:
                md = "# Not found\n\nThe file `" + self.doc_path + "` is no longer there. Help > Download documentation fetches it again."
        self.doc_links.clear()
        self.doc_lines = md_render_rich(md, w, self.hl, self.doc_links, True)
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
            if not (book in self.doc_open_books):
                self.doc_open_books.append(book)
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
        var scroll = 0
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
            if self.doc_row + 1 < len(self.doc_rows):
                self.doc_row += 1
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

    def docs_follow(mut self, id: Int):
        if id < 0 or id >= len(self.doc_links):
            return
        var target = self.doc_links[id]
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
        d.lines.append("words   \"a phrase\"   -without   @api name   #heading   `code   in:book")
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
        var q = parse_query(text)
        self.doc_found = find_help(self.doc_index, self.doc_lib, q, DOC_FIND_MAX)
        var items = List[String]()
        var data = List[Int]()
        var room = max(30, self.dlg.w - 44)
        var signs = ["ƒ", "▤", "§", "·", "›"]
        for k in range(len(self.doc_found)):
            var e = self.doc_index.entries[self.doc_found[k].entry].copy()
            var what = e.text
            if e.kind == IK_API and e.owner.byte_length() > 0:
                what = e.owner + "." + e.text
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

    def docs_find_go(mut self, sel: Int):
        """Enter in the finder: the reader opens at the place."""
        var k = self.dlg.item_data[sel] if sel >= 0 and sel < len(self.dlg.item_data) else -1
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

    def docs_api_lookup(mut self, name: String, load: Bool) -> Bool:
        """Topic search for a name of the standard library: straight to its page if
        the name is declared once, the finder with the candidates if several times.
        False if the downloaded documentation does not know it. Without `load` only an
        index that is already there is used."""
        if load:
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
        if fresh:
            self.say("Your own copy of " + basename(mine) + " - change it, Ctrl-F9 runs it")
        else:
            self.say("Your copy of " + basename(mine) + ", as you left it - Ctrl-F9 runs it")
        return True

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
                if True:
                    var page = self.doc_lib.pages[v].copy()
                    for _ in range(min(page.depth, 6)):
                        text += "  "
                    if page.kind == DK_BOOK:
                        text = (" ▾ " if page.title in self.doc_open_books else " ▸ ") + page.title
                        fg = p.doc_bold
                    elif page.kind == DK_HEADING:
                        text += " " + page.title
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
                elif st == MD_ITALIC or st == MD_DIM:
                    fg = p.doc_dim
                if st < 0 and -st - 1 == self.doc_link:
                    fg = p.doc_bg
                    bg = p.doc_bold                 # the link under Enter
                elif marked[q]:
                    fg = p.match_fg
                    bg = p.match_bg
                var at = xx
                xx = self.scr.draw_cp(xx, 2 + r, line.cps[q], fg, bg)
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
