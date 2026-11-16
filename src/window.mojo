"""Editor / message windows: state, cursor, selection and editing commands.

Search and bracket matching are in window_search.mojo, drawing in window_draw.mojo
(both extend Window; import them with `from ... import *`)."""
from std.collections import List
from std.memory import ArcPointer
from buffer import TextBuffer, Pos, TAB_WIDTH, replace_all_text_diff
from watch import FileSig
from git import GB_KNOWN
from outline import OutlineItem
from screen import Screen
from palette import Palette
from highlight import Highlighter, C_TEXT, line_state, scan_states, lang_for_path
from util import is_ident, lower, lower_str, decode, cp_len, to_str, str_contains, char_width, basename
from search import Search
from grapheme import cluster_end, cluster_start, cluster_width, ends_with_plain_mark
from cellimg import (
    InlineImageCache,
    CELL_NB_HDR_MARK,
    CELL_NB_SUB_MARK,
    CELL_NB_BOT_MARK,
    NB_IMG_QUADRANT,
    is_anim_spec,
    parse_anim_spec,
    read_png_header_size,
    cell_image_grid_size,
    encode_cell_img_line,
)

comptime WK_EDITOR = 0
comptime LEX_BUDGET = 4000     # lines re-scanned after an edit before giving up on rejoining
comptime LEX_BLOCK = 20000     # lines scanned per block when extending the cache
comptime WK_MESSAGE = 1
comptime WK_EXPLORER = 3     # the project's files as a tree: a list window at the left edge
comptime WK_OUTLINE = 2      # the outline of the file being edited: a list, like the Message window
comptime WK_DEBUG = 4        # the call stack and variables of the program being debugged
comptime WK_CPU = 5          # machine code, registers and memory of the program being debugged
comptime WK_TERM = 6         # a terminal: a program on a pty (the shell, or the program Run started)
comptime WK_TESTS = 7        # the test explorer
comptime MINIMAP_W = 10       # cells of the minimap (2 x 4 braille dots each)
comptime WK_AGENT = 10       # the conversation with a coding agent (ACP)
comptime WK_BLAME = 9        # who last changed each line of a file
comptime WK_PANEL = 13       # a plugin's panel: a list or a table it fills
comptime RM_NONE = 0          # row marks of list windows (a plugin panel's row styles)
comptime RM_ERROR = 1
comptime RM_WARN = 2
comptime RM_OK = 3
comptime RM_DIM = 4
comptime WK_DOCPANE = 12     # the docs pane: documentation of the name at the cursor, at the right edge
comptime WK_EXPLAIN = 11     # the explanation of a Mojo error message, beside the code
comptime WK_DIFF = 8         # a file's changes against git's index (or the index's against HEAD)
comptime WK_GIT = 14         # repository status panel: staged, modified, untracked, conflicted
comptime WK_GPU = 15         # live GPU telemetry monitor
comptime WK_CODEGEN = 16     # Mojo generated assembly / LLVM IR inspector
comptime WK_HEX = 17         # virtualized hex editor
comptime WK_MDPREVIEW = 18   # markdown preview pane
comptime WK_GITLOG = 19      # git commit graph & history browser
comptime WK_IMGVIEW = 20     # dedicated floating image zoom window
comptime WK_DATAGRID = 21    # virtualized DataGrid & 2D Tensor heatmap window
comptime WK_PROFILE = 22     # interactive Flamegraph & GPU timeline window

comptime ACT_NONE = 0
comptime ACT_TYPE = 1
comptime ACT_BACK = 2
comptime ACT_DEL = 3
comptime ACT_OTHER = 4


@fieldwise_init
struct Range(Copyable, Movable):
    var r1: Int
    var c1: Int
    var r2: Int
    var c2: Int


@fieldwise_init
struct Cur(Copyable, Movable):
    """An additional cursor (the first one lives in Window.cr/cc/sel/ar/ac/want)."""
    var r: Int
    var c: Int
    var sel: Bool
    var ar: Int
    var ac: Int
    var want: Int


struct Window(Copyable, Movable):
    var kind: Int
    var title: String
    var path: String
    var buf: TextBuffer
    var cr: Int
    var cc: Int
    var want: Int
    var top: Int
    var top_seg: Int      # soft wrap: which screen row of line `top` is the first one shown
    var wrap: Bool        # soft wrap: long lines continue on the next screen row
    var left: Int
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var sx: Int
    var sy: Int
    var sw: Int
    var sh: Int
    var zoomed: Bool
    var stacked: Bool       # a side pane put above / below the editors (narrow terminal, tiled)
    var half: Bool          # zoom's middle step: half the desk (classic) or half the room (tiled)
    var half_right: Bool    #   (classic: the right half)
    var sel: Bool
    var ar: Int
    var ac: Int
    var vsel: Int           # vim's Visual modes: 0 none, 1 the cursor's character included, 2 whole lines
    var number: Int
    var git_rows: List[Int]     # explorer: GS_* of each row's file or folder
    var row_marks: List[Int]    # list windows: RM_* of each row (its colour)
    var crumbs: String          # " › Counter › add": where the cursor is, after the title
    var sticky: List[Int]       # lines pinned at the top: headers of the scopes scrolled away
    var minimap: Bool           # a minimap column at the right edge
    var minimap_blocks: Bool    # drawn in half blocks (fonts without braille)
    var scopes_ver: Int         # buffer version `scope_items` were made for
    var scopes_ns: Int          # when they were made (long files: at most every half second)
    var scope_items: List[OutlineItem]  # the file's defs and structs (for crumbs, sticky)
    var wid: Int             # a lasting identity (the tiled layout keeps windows by it); 0 = none yet
    var hidden: Bool         # a tab that is not the one its pane shows: not drawn, not clickable
    var pinned: Bool         # pinned tab: preserved from batch closing and shown first
    var preview_peer_wid: Int # peer window id for linked WK_MDPREVIEW markdown preview
    var gseq: Int
    var cur_group: Int
    var last_act: Int
    var follow: Bool
    var gut: Int
    var extra: List[Cur]  # additional cursors (multi-cursor editing)
    var box_on: Bool      # the cursors form a column (box) selection
    var box_ar: Int       # its fixed corner: row and screen column
    var box_av: Int
    var box_r: Int        # its moving corner
    var box_v: Int
    var forced_group: Int # while set, every edit joins this undo group
    var rel_nums: Bool      # the gutter counts from the cursor's line (the app sets it)
    var hs: Search        # the search whose matches are highlighted
    var hs_on: Bool
    var word_hl: Bool           # show the other uses of the word at the cursor
    var scope_on: Bool    # searching is limited to `scope` (Find in selection)
    var scope: Range
    var auto_pairs: Bool  # typing an opening bracket or quote also inserts its partner
    var rulers: List[Int] # columns after which a vertical guide is drawn
    var clustered: Bool   # the terminal draws a grapheme cluster as one glyph (mode 2027)
    var swap_file: String    # path of this buffer's swap file ('' if none written)
    var overwrite_ok: Bool   # the user chose to keep their version over a changed file
    var lsp_sent_version: Int   # buffer version the language server has
    var sem_version: Int        # buffer version semantic colours were last asked for
    var hint_version: Int       # ... and inlay hints
    var hint_top: Int           # viewport range covered by last inlay hint request
    var hint_end: Int
    var lsp_seen_version: Int   # buffer version when an edit was last noticed
    var lsp_due: Int            # when the pending edits go to the server (0 = nothing pending)
    var disk_hash: Int       # hash and size of the file's bytes when last loaded or saved
    var disk_size: Int       # (-1: unknown); the undo history on disk is tied to them
    var disk_sig: FileSig    # size/mtime of the file when it was last loaded or saved
    var swap_version: Int    # buffer version the swap file holds (-1 if none)
    var inline_blame: String # dimmed current-line git blame summary
    var inline_blame_row: Int
    var dbg_inline_rows: List[Int]
    var dbg_inline_vals: List[String]
    var test_lens_rows: List[Int]
    var test_lens_states: List[Int]
    var clone_group: Int
    var sync_ver: Int
    var indent_guides: Bool
    var rainbow_brackets: Bool
    var read_only: Bool
    var hex_bytes: List[UInt8]
    var cell_badge_rows: List[Int]
    var cell_badges: List[String]
    var lsp_nb_active: Bool
    var lsp_nb_v2b_row: List[Int]
    var lsp_nb_v2b_col: List[Int]
    var lsp_nb_b2v_row: List[Int]
    var lsp_nb_b2v_col: List[Int]
    var bench_badge_rows: List[Int]
    var bench_badges: List[String]
    var cov_rows: List[Int]
    var cov_states: List[Int]
    var sel_hist: List[Range]
    var buf_id: Int
    var lang_override: Int
    var inline_cell_outputs: Bool
    var ghost_text: String
    var ghost_row: Int
    var ghost_col: Int
    var chromeless: Bool
    var split_sep: Bool
    var nb_cmd_mode: Bool
    var nb_pend: Int
    var nb_clip: String
    var gfx_kitty: Bool
    var gfx_mode: Int
    var gfx_tmux: Bool
    var gfx_cell_w: Int
    var gfx_cell_h: Int
    var img_cache: ArcPointer[InlineImageCache]
    var img_paths: List[String]
    var img_label: String
    var img_idx: Int
    var img_zoom_pct: Int
    var img_pan_x: Int
    var img_pan_y: Int
    var img_anim_fps: Int
    var img_anim_playing: Bool
    var anim_playing: Bool
    var anim_tick_count: Int
    var anim_last_ns: Int

    def __init__(out self, kind: Int, title: String, path: String, x: Int, y: Int, w: Int, h: Int, number: Int):
        self.kind = kind
        self.vsel = 0
        self.title = title
        self.path = path
        self.buf = TextBuffer()
        self.cr = 0
        self.cc = 0
        self.want = 0
        self.top = 0
        self.left = 0
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.sx = x
        self.sy = y
        self.sw = w
        self.sh = h
        self.zoomed = False
        self.half = False
        self.stacked = False
        self.half_right = False
        self.sel = False
        self.ar = 0
        self.ac = 0
        self.number = number
        self.git_rows = List[Int]()
        self.row_marks = List[Int]()
        self.crumbs = ""
        self.sticky = List[Int]()
        self.minimap = False
        self.minimap_blocks = False
        self.scopes_ver = -1
        self.scopes_ns = 0
        self.scope_items = List[OutlineItem]()
        self.gseq = 0
        self.cur_group = 0
        self.last_act = ACT_NONE
        self.follow = True
        self.gut = 0
        self.lsp_sent_version = -1
        self.wid = 0
        self.hidden = False
        self.pinned = False
        self.preview_peer_wid = -1
        self.sem_version = -1
        self.hint_version = -1
        self.lsp_seen_version = -1
        self.lsp_due = 0
        self.disk_hash = 0
        self.disk_size = -1
        self.top_seg = 0
        self.wrap = False
        self.clustered = False
        self.auto_pairs = False
        self.rulers = List[Int]()
        self.extra = List[Cur]()
        self.box_on = False
        self.box_ar = 0
        self.box_av = 0
        self.box_r = 0
        self.box_v = 0
        self.forced_group = 0
        self.rel_nums = False
        self.hs = Search()
        self.hs_on = False
        self.word_hl = True
        self.scope_on = False
        self.scope = Range(0, 0, 0, 0)
        self.swap_file = ""
        self.swap_version = -1
        self.disk_sig = FileSig()
        self.overwrite_ok = False
        self.inline_blame = ""
        self.inline_blame_row = -1
        self.dbg_inline_rows = List[Int]()
        self.dbg_inline_vals = List[String]()
        self.test_lens_rows = List[Int]()
        self.test_lens_states = List[Int]()
        self.hint_top = -1
        self.hint_end = -1
        self.clone_group = 0
        self.sync_ver = 0
        self.indent_guides = False
        self.rainbow_brackets = False
        self.read_only = False
        self.hex_bytes = List[UInt8]()
        self.cell_badge_rows = List[Int]()
        self.cell_badges = List[String]()
        self.lsp_nb_active = False
        self.lsp_nb_v2b_row = List[Int]()
        self.lsp_nb_v2b_col = List[Int]()
        self.lsp_nb_b2v_row = List[Int]()
        self.lsp_nb_b2v_col = List[Int]()
        self.bench_badge_rows = List[Int]()
        self.bench_badges = List[String]()
        self.cov_rows = List[Int]()
        self.cov_states = List[Int]()
        self.sel_hist = List[Range]()
        self.buf_id = -1
        self.lang_override = -1
        self.inline_cell_outputs = True
        self.ghost_text = ""
        self.ghost_row = -1
        self.ghost_col = -1
        self.chromeless = False
        self.split_sep = False
        self.nb_cmd_mode = False
        self.nb_pend = 0
        self.nb_clip = ""
        self.gfx_kitty = False
        self.gfx_mode = NB_IMG_QUADRANT
        self.gfx_tmux = False
        self.gfx_cell_w = 10
        self.gfx_cell_h = 20
        self.img_cache = ArcPointer(InlineImageCache())
        self.img_paths = List[String]()
        self.img_label = ""
        self.img_idx = 0
        self.img_zoom_pct = 100
        self.img_pan_x = 500
        self.img_pan_y = 500
        self.img_anim_fps = 0
        self.img_anim_playing = True
        self.anim_playing = True
        self.anim_tick_count = 0
        self.anim_last_ns = 0

    def imgview_current_path(self) -> String:
        if len(self.img_paths) == 0:
            return self.path
        var idx = max(0, min(self.img_idx, len(self.img_paths) - 1))
        return self.img_paths[idx]

    def imgview_sync_title(mut self):
        var p = self.imgview_current_path()
        var sz = read_png_header_size(p)
        var raw_base = basename(p)
        if (
            raw_base.startswith("turbomojo-ipynb-")
            or raw_base.startswith("turbomojo-plot-")
            or raw_base.startswith("turbomojo-anim-")
            or raw_base.startswith("turbomojo-live-")
            or raw_base.startswith("turbomojo-gif-")
        ):
            raw_base = "Notebook Animation" if self.img_anim_fps > 0 else "Notebook Plot"
        var base = self.img_label if self.img_label.byte_length() > 0 else raw_base
        var dims = (" · " + String(sz[0]) + "×" + String(sz[1]) + " px") if (sz[0] > 0 and sz[1] > 0) else String("")
        var ftag = (" · " + String(self.img_anim_fps) + " fps") if self.img_anim_fps > 0 else String("")
        var ztag = " · " + String(self.img_zoom_pct) + "%"
        var cur_1 = max(0, min(self.img_idx, len(self.img_paths) - 1)) + 1
        var ptag = (
            (
                " [Frame " + String(cur_1) + "/" + String(len(self.img_paths)) + ("" if self.img_anim_playing else " ⏸") + "]"
                if self.img_anim_fps > 0
                else (" [" + String(cur_1) + "/" + String(len(self.img_paths)) + "]")
            )
            if len(self.img_paths) > 1
            else String("")
        )
        self.title = base + dims + ftag + ztag + ptag

    def imgview_reset_fit(mut self):
        self.img_zoom_pct = 100
        self.img_pan_x = 500
        self.img_pan_y = 500
        self.imgview_sync_title()

    def imgview_step_zoom(mut self, dir: Int):
        var steps: List[Int] = [100, 150, 225, 350, 500]
        var cur = 0
        for k in range(len(steps)):
            if steps[k] <= self.img_zoom_pct:
                cur = k
        var nxt = max(0, min(len(steps) - 1, cur + (1 if dir > 0 else -1)))
        self.img_zoom_pct = steps[nxt]
        if self.img_zoom_pct <= 100:
            self.img_pan_x = 500
            self.img_pan_y = 500
        self.imgview_sync_title()

    def imgview_pan(mut self, dx_pm: Int, dy_pm: Int):
        if self.img_zoom_pct <= 100:
            return
        self.img_pan_x = max(0, min(1000, self.img_pan_x + dx_pm))
        self.img_pan_y = max(0, min(1000, self.img_pan_y + dy_pm))

    def imgview_step_plot(mut self, delta: Int):
        var n = len(self.img_paths)
        if n <= 1:
            return
        self.img_idx = (self.img_idx + delta + n) % n
        self.path = self.img_paths[self.img_idx]
        if self.img_anim_fps > 0:
            self.img_anim_playing = False
            self.imgview_sync_title()
        else:
            self.imgview_reset_fit()

    def visible_anim_fps(self) -> Int:
        """Return max FPS of any playing animation currently visible in this window (`0` if none/paused)."""
        if self.hidden:
            return 0
        if self.kind == WK_IMGVIEW:
            if self.img_anim_fps > 0 and self.img_anim_playing and len(self.img_paths) > 1:
                return self.img_anim_fps
            return 0
        if self.kind != WK_EDITOR or not self.inline_cell_outputs or not self.anim_playing:
            return 0
        var max_fps = 0
        var rws = self.rows()
        for oi in range(len(self.buf.cell_out_rows)):
            if oi >= len(self.buf.cell_out_plots):
                break
            var pstr = self.buf.cell_out_plots[oi]
            if pstr.find("ANIM|") < 0:
                continue
            var hr = self.buf.cell_out_rows[oi]
            var er = self.buf.cell_end_for_header(hr)
            if er < 0 or er < self.top - 4:
                continue
            if self.screen_row_of(er, 0, rws + 8) >= rws + 4:
                continue
            for ps in pstr.split("\n"):
                var sp = String(ps.strip())
                if is_anim_spec(sp):
                    var pa = parse_anim_spec(sp)
                    if pa[0] and len(pa[2]) > 1 and pa[1] > max_fps:
                        max_fps = pa[1]
        return max_fps

    def step_anim(mut self, now_ns_val: Int) -> Bool:
        """Advance playing animation frame when due; returns True if the visible frame changed."""
        var fps = self.visible_anim_fps()
        if fps <= 0:
            return False
        var period_ns = max(16_000_000, 1_000_000_000 // fps)
        if self.anim_last_ns != 0 and now_ns_val - self.anim_last_ns < period_ns:
            return False
        self.anim_last_ns = now_ns_val
        if self.kind == WK_IMGVIEW:
            var n = len(self.img_paths)
            if n > 1:
                self.img_idx = (self.img_idx + 1) % n
                self.path = self.img_paths[self.img_idx]
                self.imgview_sync_title()
                return True
            return False
        self.anim_tick_count += 1
        return True

    def is_notebook(self) -> Bool:
        if self.kind != WK_EDITOR:
            return False
        var lp = lower_str(self.path)
        var lt = lower_str(self.title)
        return lp.endswith(".ipynb") or lt.endswith(".ipynb")

    def has_cells(self) -> Bool:
        if self.kind != WK_EDITOR:
            return False
        if self.is_notebook():
            return True
        var lim = min(self.buf.count(), 400)
        for r in range(lim):
            if self.buf.is_cell_header(r):
                return True
        return False

    def cell_header_for_row(self, r: Int) -> Int:
        var k = min(r, max(0, self.buf.count() - 1))
        while k >= 0:
            if self.buf.is_cell_header(k):
                return k
            k -= 1
        return -1

    def is_markdown_header(self, hdr_row: Int) -> Bool:
        if hdr_row < 0 or hdr_row >= self.buf.count():
            return False
        var s = lower_str(to_str(self.buf.line(hdr_row)))
        return s.find("[markdown]") >= 0 or s.find("[md]") >= 0 or s.find("[raw]") >= 0

    def cell_exec_count_at_header(self, hdr_row: Int) -> Int:
        for oi in range(len(self.buf.cell_out_rows)):
            if self.buf.cell_out_rows[oi] == hdr_row:
                return self.buf.cell_out_counts[oi] if oi < len(self.buf.cell_out_counts) else 0
        return 0

    def cell_exec_count_for_end(self, end_row: Int) -> Int:
        for oi in range(len(self.buf.cell_out_rows)):
            var hr = self.buf.cell_out_rows[oi]
            if self.buf.cell_end_for_header(hr) == end_row:
                return self.buf.cell_out_counts[oi] if oi < len(self.buf.cell_out_counts) else 0
        return 0

    def clean_cell_title(self, hdr_row: Int) -> String:
        """Extract clean cell title from `# %% [Title]` or `# %% Title` without raw `# %%` prefix."""
        if hdr_row < 0 or hdr_row >= self.buf.count():
            return ""
        var raw_ln = String(to_str(self.buf.line(hdr_row)).strip())
        if not raw_ln.startswith("#"):
            return ""
        var after_h = String(raw_ln[byte=1:].lstrip())
        if not after_h.startswith("%%"):
            return ""
        var rest = String(after_h[byte=2:].strip())
        var low = lower_str(rest)
        if low.startswith("[markdown]") or low.startswith("[md]") or low.startswith("[raw]"):
            var cb = rest.find("]")
            return String(rest[byte=cb + 1:].strip()) if cb >= 0 else String("")
        if rest.startswith("[") and rest.endswith("]") and rest.byte_length() >= 2:
            return String(rest[byte=1 : rest.byte_length() - 1].strip())
        return rest

    def toggle_cell_code_fold(mut self, row: Int) -> Bool:
        """Collapse or expand the `# %%` cell containing `row`, keeping `Out [k]` & images visible."""
        self.buf.sync_folds()
        var hdr = self.cell_header_for_row(row)
        if hdr < 0:
            return False
        if self.buf.fold_index(hdr) >= 0:
            var ok = self.buf.set_fold(hdr, False)
            self.follow = True
            return ok
        if not self.buf.set_fold(hdr, True):
            return False
        self.extra.clear()
        if self.buf.hidden_by(self.cr) >= 0:
            self.sel = False
            self.cr = hdr
            self.cc = 0
            self.sync_want()
        if self.buf.hidden_by(self.top) >= 0:
            self.top = self.buf.hidden_by(self.top)
            self.top_seg = 0
        self.follow = True
        return True

    def toggle_all_cell_code_folds(mut self) -> Int:
        """Collapse all `# %%` code cells (leaving Markdown prose readable and inline `Out [k]`
        + images visible!), or expand all if every foldable code cell is already collapsed."""
        self.buf.sync_folds()
        var count = self.buf.count()
        var code_hdrs = List[Int]()
        var any_unfolded = False
        for r in range(count):
            if self.buf.is_cell_header(r) and not self.is_markdown_header(r) and self.buf.foldable(r):
                code_hdrs.append(r)
                if self.buf.fold_index(r) < 0:
                    any_unfolded = True
        if len(code_hdrs) == 0:
            return 0
        var folded_n = 0
        for hr in code_hdrs:
            if any_unfolded:
                if self.buf.set_fold(hr, True):
                    folded_n += 1
            else:
                _ = self.buf.set_fold(hr, False)
        self.extra.clear()
        if self.buf.hidden_by(self.cr) >= 0:
            self.sel = False
            self.cr = self.buf.hidden_by(self.cr)
            self.cc = 0
            self.sync_want()
        if self.buf.hidden_by(self.top) >= 0:
            self.top = self.buf.hidden_by(self.top)
            self.top_seg = 0
        self.follow = True
        return folded_n

    def replace_lines_undoable(mut self, r1: Int, r2: Int, new_text: String):
        """Atomically replace inclusive line range `[r1, r2]` with `new_text` (1-step Undo)."""
        var n = self.buf.count()
        if n <= 0:
            return
        var a = max(0, min(r1, n - 1))
        var b = max(a, min(r2, n - 1))
        var g = self.new_group()
        var end_c = self.buf.llen(b)
        _ = self.buf.delete(a, 0, b, end_c, self.cr, self.cc, g)
        if new_text.byte_length() > 0:
            _ = self.buf.insert(a, 0, decode(new_text), a, 0, g)
        self.break_group()
        self.sel = False
        self.clamp()
        self.follow = True

    def effective_lang(self) -> Int:
        return self.lang_override if self.lang_override >= 0 else lang_for_path(self.path, self.title)

    # ------------------------------------------------------------ geometry
    def pad(self) -> Int:
        return 0 if self.chromeless else 1

    def contains(self, px: Int, py: Int) -> Bool:
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h

    def rows(self) -> Int:
        return max(1, self.h if self.chromeless else self.h - 2)

    def cols(self) -> Int:
        var border_w = 0 if self.chromeless else 2
        var sep_w = 1 if (self.chromeless and self.split_sep) else 0
        return max(1, self.w - border_w - sep_w - self.gut - (MINIMAP_W if self.minimap else 0))

    def gutter_for(self, line_numbers: Bool) -> Int:
        if not line_numbers or self.kind != WK_EDITOR:
            return 0
        var n = self.buf.count()
        var d = 1
        while n >= 10:
            n //= 10
            d += 1
        # a column for the git markers when the file is in a repository
        var base_w = max(d, 5 if self.is_notebook() else 3) + 1 + (1 if self.buf.git_state == GB_KNOWN else 0)
        return base_w

    # ------------------------------------------------------ visual columns
    def tab_title(self, duplicate: Bool = False) -> String:
        """Returns the formatted tab label, with parent-dir disambiguation if duplicate is true,
        and pinned indicator if pinned is true."""
        var t = self.title
        if duplicate and self.path.byte_length() > 0:
            var p = decode(self.path)
            var last_slash = -1
            var prev_slash = -1
            for i in range(len(p)):
                if p[i] == 47:
                    prev_slash = last_slash
                    last_slash = i
            if prev_slash >= 0 and last_slash > prev_slash + 1:
                var parent = List[Int]()
                for j in range(prev_slash + 1, last_slash):
                    parent.append(p[j])
                t = t + " — " + to_str(parent)
            elif last_slash > 0:
                var parent = List[Int]()
                for j in range(0, last_slash):
                    parent.append(p[j])
                t = t + " — " + to_str(parent)
        if self.pinned:
            t = "📌 " + t
        return t

    def adv(self, ch: Int, v: Int) -> Int:
        """Display columns taken by `ch` when it starts at visual column v."""
        if ch == 9:
            return self.buf.tab_width - v % self.buf.tab_width
        return char_width(ch)

    def span(self, ln: List[Int], i: Int, e: Int, v: Int) -> Int:
        """Display columns taken by the grapheme cluster ln[i:e] starting at column v."""
        if e - i == 1:
            return self.adv(ln[i], v)
        return cluster_width(ln, i, e, self.clustered)

    def vcol(self, r: Int, c: Int) -> Int:
        """Visual (screen) column of character index c on row r."""
        var v = 0
        var ln = self.buf.line(r)
        var n = min(c, len(ln))
        var i = 0
        while i < n:
            var e = cluster_end(ln, i)
            if e > n:
                break          # c is inside a cluster: it shares the cluster's column
            v += self.span(ln, i, e, v)
            i = e
        return v

    def col_at_vcol(self, r: Int, target: Int) -> Int:
        """Character index of the grapheme cluster that covers visual column `target`."""
        var v = 0
        var ln = self.buf.line(r)
        var n = len(ln)
        var i = 0
        while i < n:
            var e = cluster_end(ln, i)
            var a = self.span(ln, i, e, v)
            if a > 0 and v + a > target:
                # closer to the right edge of a tab/wide char -> place after it
                if target - v >= (a + 1) // 2 and a > 1:
                    return e
                return i
            v += a
            i = e
        return n

    def sync_want(mut self):
        self.want = self.vcol(self.cr, self.cc)
        if self.wrap:
            # with soft wrap Up/Down keep the column inside the screen row
            var starts = List[Int]()
            var vs = List[Int]()
            self.wrap_layout(self.buf.line(self.cr), starts, vs)
            self.want -= vs[self.seg_of(starts, self.cc)]

    # ------------------------------------------------------------ soft wrap
    def wrap_layout(self, ln: List[Int], mut starts: List[Int], mut vs: List[Int]):
        """Where the screen rows of a line begin: character index (`starts`) and visual
        column (`vs`) of each. Without soft wrap a line is one row. Rows are broken after
        the last blank that fits, or in the middle of a word that is longer than a row.
        One column is kept free so the cursor can stand after the last character."""
        starts.clear()
        vs.clear()
        starts.append(0)
        vs.append(0)
        if not self.wrap:
            return
        var width = max(4, self.cols() - 1)
        var n = len(ln)
        var i = 0
        var v = 0
        var seg_start = 0
        var seg_v = 0
        var after_space = -1         # index just after the last blank of this row
        var after_space_v = 0
        while i < n:
            var e = cluster_end(ln, i)
            var a = self.span(ln, i, e, v)
            if v + a - seg_v > width and i > seg_start:
                var b = i
                var bv = v
                if after_space > seg_start and ln[i] != 32 and ln[i] != 9:
                    b = after_space
                    bv = after_space_v
                starts.append(b)
                vs.append(bv)
                seg_start = b
                seg_v = bv
                after_space = -1
                continue
            if ln[i] == 32 or ln[i] == 9:
                after_space = e
                after_space_v = v + a
            v += a
            i = e

    def rowwise(self) -> Bool:
        """Screen rows and lines are not one to one (soft wrap, folded blocks, or inline cell outputs)."""
        return self.wrap or len(self.buf.folds) > 0 or (
            self.inline_cell_outputs and self.kind == WK_EDITOR and len(self.buf.cell_out_rows) > 0
        )

    def reveal_cursor(mut self):
        """Open any folded block that hides the cursor."""
        self.buf.sync_folds()
        var guard = 0
        while guard < 1000:
            var h = self.buf.hidden_by(self.cr)
            if h < 0:
                break
            _ = self.buf.set_fold(h, False)
            guard += 1

    def toggle_fold(mut self, r: Int) -> Bool:
        """Fold or unfold at line r: a block header toggles its block; any other line
        folds the block it is in. The cursor moves to the header if it would be hidden."""
        self.buf.sync_folds()
        var row = r
        if self.buf.fold_index(row) >= 0:
            return self.buf.set_fold(row, False)
        if not self.buf.foldable(row):
            # the enclosing block: the nearest line above that is indented less,
            # or an enclosing `# %%` code cell header
            var found_hdr = -1
            var ind = self.buf.indent_cols(row)
            if ind < 0:
                var j = row + 1
                while j < self.buf.count() and self.buf.indent_cols(j) < 0 and not self.buf.is_cell_header(j):
                    j += 1
                if j < self.buf.count() and not self.buf.is_cell_header(j):
                    ind = self.buf.indent_cols(j)
            if ind > 0:
                var k = row - 1
                while k >= 0:
                    if self.buf.is_cell_header(k):
                        break
                    var ki = self.buf.indent_cols(k)
                    if ki >= 0 and ki < ind and self.buf.foldable(k):
                        if self.buf.block_end(k) >= row:
                            found_hdr = k
                        break
                    k -= 1
            if found_hdr < 0:
                var ck = row - 1
                while ck >= 0:
                    if self.buf.is_cell_header(ck):
                        if self.buf.block_end(ck) >= row:
                            found_hdr = ck
                        break
                    ck -= 1
            if found_hdr < 0:
                return False
            row = found_hdr
            if self.buf.fold_index(row) >= 0:
                return self.buf.set_fold(row, False)
        if not self.buf.set_fold(row, True):
            return False
        self.extra.clear()
        if self.buf.hidden_by(self.cr) >= 0:
            self.sel = False
            self.cr = row
            self.cc = min(self.cc, self.buf.llen(row))
            self.sync_want()
        if self.buf.hidden_by(self.top) >= 0:
            self.top = self.buf.hidden_by(self.top)
            self.top_seg = 0
        self.follow = True
        return True

    def seg_of(self, starts: List[Int], c: Int) -> Int:
        """Which screen row of its line holds character index c."""
        var k = len(starts) - 1
        while k > 0 and starts[k] > c:
            k -= 1
        return k

    def text_row_segs(self, r: Int) -> Int:
        """How many screen rows the text of line r takes (excluding virtual cell outputs)."""
        if not self.wrap:
            return 1
        var starts = List[Int]()
        var vs = List[Int]()
        self.wrap_layout(self.buf.line(r), starts, vs)
        return len(starts)

    def virtual_out_lines_at(self, r: Int) -> Tuple[List[String], Bool]:
        """Virtual multi-line cell output rows (text + inline PNG plots) attached beneath buffer row r."""
        var empty = List[String]()
        if not self.inline_cell_outputs or self.kind != WK_EDITOR or len(self.buf.cell_out_rows) == 0:
            return (empty^, False)
        for oi in range(len(self.buf.cell_out_rows)):
            var hdr_r = self.buf.cell_out_rows[oi]
            if self.buf.cell_end_for_header(hdr_r) == r:
                var txt = self.buf.cell_out_texts[oi] if oi < len(self.buf.cell_out_texts) else String("")
                var plots_s = self.buf.cell_out_plots[oi] if oi < len(self.buf.cell_out_plots) else String("")
                var is_err = self.buf.cell_out_errs[oi] if oi < len(self.buf.cell_out_errs) else False
                var exec_c = self.buf.cell_out_counts[oi] if oi < len(self.buf.cell_out_counts) else 0

                var valid_plots = List[String]()
                var plot_sizes = List[Tuple[Int, Int]]()
                var plot_caps = List[String]()
                if plots_s.byte_length() > 0:
                    for ps in plots_s.split("\n"):
                        var pp = String(ps.strip())
                        if pp.byte_length() > 0 and len(valid_plots) < 4:
                            if is_anim_spec(pp):
                                var pa = parse_anim_spec(pp)
                                if pa[0] and len(pa[2]) > 0:
                                    var nf = len(pa[2])
                                    var f_i = self.anim_tick_count % nf
                                    var cur_fp = pa[2][f_i]
                                    var sz_a = read_png_header_size(cur_fp)
                                    if sz_a[0] > 0 and sz_a[1] > 0:
                                        valid_plots.append(cur_fp)
                                        plot_sizes.append(sz_a)
                                        var play_pill = "[⏸ Pause]" if self.anim_playing else "[▶ Play]"
                                        plot_caps.append(
                                            "🎬 "
                                            + String(sz_a[0])
                                            + "×"
                                            + String(sz_a[1])
                                            + "px · Frame "
                                            + String(f_i + 1)
                                            + "/"
                                            + String(nf)
                                            + " · "
                                            + String(pa[1])
                                            + " fps · "
                                            + play_pill
                                            + " — click image to zoom"
                                        )
                                continue
                            var sz = read_png_header_size(pp)
                            if sz[0] > 0 and sz[1] > 0:
                                valid_plots.append(pp)
                                plot_sizes.append(sz)
                                plot_caps.append("")

                var np = len(valid_plots)
                var text_lines = List[String]()
                if txt.byte_length() > 0:
                    for ls in txt.split("\n"):
                        var s = String(ls)
                        if np > 0 and (
                            s.startswith("[📊 plot saved: ")
                            or (s.startswith("<") and s.endswith(">") and s.byte_length() <= 96)
                        ):
                            continue
                        text_lines.append(s)
                if plots_s.byte_length() > 0 and np == 0 and not str_contains(txt, "[📊"):
                    text_lines.append("[📊 plot output — Text > Open cell plot preview]")

                var out_rows = List[String]()
                var is_nb = self.is_notebook()
                if is_nb and (len(text_lines) > 0 or np > 0):
                    var out_lbl = ("Out [" + String(exec_c) + "]") if exec_c > 0 else String("Out")
                    if np == 1 and len(text_lines) == 0:
                        var pw0 = plot_sizes[0][0]
                        var ph0 = plot_sizes[0][1]
                        var gsz0 = cell_image_grid_size(
                            pw0, ph0, self.cols(), 1, self.gfx_cell_w, self.gfx_cell_h, self.rows()
                        )
                        var cap0 = (
                            plot_caps[0]
                            if plot_caps[0].byte_length() > 0
                            else ("📊 " + String(pw0) + "×" + String(ph0) + "px — click image to zoom")
                        )
                        out_rows.append(String(CELL_NB_HDR_MARK) + out_lbl + "\t" + cap0)
                        for ri in range(gsz0[1]):
                            out_rows.append(encode_cell_img_line(valid_plots[0], ri, gsz0[1], gsz0[0]))
                        out_rows.append(String(CELL_NB_BOT_MARK))
                        return (out_rows^, is_err)
                    out_rows.append(String(CELL_NB_HDR_MARK) + out_lbl + "\t")

                if len(text_lines) <= 6:
                    for tl in text_lines:
                        out_rows.append(tl)
                else:
                    for k in range(5):
                        out_rows.append(text_lines[k])
                    out_rows.append("… (+" + String(len(text_lines) - 5) + " more lines — see Message window)")

                for pi in range(np):
                    var pp = valid_plots[pi]
                    var pw = plot_sizes[pi][0]
                    var ph = plot_sizes[pi][1]
                    var acap = plot_caps[pi]
                    var gsz = cell_image_grid_size(
                        pw, ph, self.cols(), np, self.gfx_cell_w, self.gfx_cell_h, self.rows()
                    )
                    if is_nb:
                        var sub_lbl = (
                            acap
                            if acap.byte_length() > 0
                            else (
                                "📊 "
                                + (("Plot " + String(pi + 1) + " · ") if np > 1 else String(""))
                                + String(pw)
                                + "×"
                                + String(ph)
                                + "px — click image to zoom"
                            )
                        )
                        out_rows.append(String(CELL_NB_SUB_MARK) + sub_lbl)
                    else:
                        out_rows.append(
                            ("[" + acap + "]")
                            if acap.byte_length() > 0
                            else (
                                "[📊 "
                                + basename(pp)
                                + " · "
                                + String(pw)
                                + "×"
                                + String(ph)
                                + "px — click image to zoom]"
                            )
                        )
                    for ri in range(gsz[1]):
                        out_rows.append(encode_cell_img_line(pp, ri, gsz[1], gsz[0]))
                if is_nb and len(out_rows) > 0:
                    out_rows.append(String(CELL_NB_BOT_MARK))
                return (out_rows^, is_err)
        return (empty^, False)

    def virtual_out_rows(self, r: Int) -> Int:
        if not self.inline_cell_outputs or self.kind != WK_EDITOR or len(self.buf.cell_out_rows) == 0:
            return 0
        return len(self.virtual_out_lines_at(r)[0])

    def row_segs(self, r: Int) -> Int:
        """How many screen rows line r takes (wrapped text segments + virtual cell output rows)."""
        return self.text_row_segs(r) + self.virtual_out_rows(r)

    def col_in_seg(self, r: Int, k: Int, x: Int) -> Int:
        """Character index on screen row k of line r at horizontal offset x."""
        var ln = self.buf.line(r)
        var starts = List[Int]()
        var vs = List[Int]()
        self.wrap_layout(ln, starts, vs)
        var seg = max(0, min(k, len(starts) - 1))
        var last = seg == len(starts) - 1
        var end = len(ln) if last else starts[seg + 1]
        var i = starts[seg]
        var v = vs[seg]
        while i < end:
            var e = cluster_end(ln, i)
            var a = self.span(ln, i, e, v)
            if a > 0 and v + a - vs[seg] > x:
                if x - (v - vs[seg]) >= (a + 1) // 2 and a > 1 and (last or e < end):
                    return e
                return i
            v += a
            i = e
        if last:
            return end
        # the position after the last character of a wrapped row belongs to the next row
        return max(starts[seg], end - 1)

    def advance_top(mut self, d: Int):
        """Scroll by d screen rows (soft wrap)."""
        var count = self.buf.count()
        self.top = max(0, min(count - 1, self.top))
        var segs = self.row_segs(self.top)
        self.top_seg = max(0, min(self.top_seg, segs - 1))
        var left = d
        while left > 0:
            if self.top_seg + 1 < segs:
                self.top_seg += 1
            elif self.buf.next_row(self.top) < count:
                self.top = self.buf.next_row(self.top)
                self.top_seg = 0
                segs = self.row_segs(self.top)
            else:
                break
            left -= 1
        while left < 0:
            if self.top_seg > 0:
                self.top_seg -= 1
            elif self.buf.prev_row(self.top) >= 0:
                self.top = self.buf.prev_row(self.top)
                segs = self.row_segs(self.top)
                self.top_seg = segs - 1
            else:
                break
            left += 1

    def screen_row_of(self, r: Int, c: Int, limit: Int) -> Int:
        """Screen row (0 = first row of the window) where position (r, c) is shown;
        -1 if it is above the window, `limit` if it is `limit` or more rows down."""
        if not self.rowwise():
            if r < self.top:
                return -1
            return min(limit, r - self.top)
        var starts = List[Int]()
        var vs = List[Int]()
        self.wrap_layout(self.buf.line(r), starts, vs)
        var seg = self.seg_of(starts, c)
        if r < self.top or (r == self.top and seg < self.top_seg):
            return -1
        if r == self.top:
            return min(limit, seg - self.top_seg)
        var y = self.row_segs(self.top) - self.top_seg
        var row = self.buf.next_row(self.top)
        while row < r and y < limit:
            y += self.row_segs(row)
            row = self.buf.next_row(row)
        return min(limit, y + seg)

    def pos_at_screen_row(self, y: Int) -> Pos:
        """Line and screen-row index within it shown on window row y: Pos(line, index)."""
        if not self.rowwise():
            return Pos(self.top + y, 0)
        var r = self.top
        var seg = self.top_seg
        var count = self.buf.count()
        var segs = self.row_segs(r) if r < count else 1
        seg = min(seg, segs - 1)
        for _ in range(y):
            if seg + 1 < segs:
                seg += 1
            else:
                r = self.buf.next_row(r)
                seg = 0
                if r >= count:
                    break
                segs = self.row_segs(r)
        return Pos(r, seg)

    def cursor_cell(self) -> Pos:
        """Screen position of the cursor as Pos(y, x); y = -1 when it is not in view."""
        var rws = self.rows()
        var pd = self.pad()
        if not self.rowwise():
            var y = self.cr - self.top
            if y < 0 or y >= rws:
                return Pos(-1, -1)
            return Pos(self.y + pd + y, self.x + pd + self.gut + self.vcol(self.cr, self.cc) - self.left)
        var y = self.screen_row_of(self.cr, self.cc, rws)
        if y < 0 or y >= rws:
            return Pos(-1, -1)
        var starts = List[Int]()
        var vs = List[Int]()
        self.wrap_layout(self.buf.line(self.cr), starts, vs)
        var x = self.vcol(self.cr, self.cc) - vs[self.seg_of(starts, self.cc)]
        if not self.wrap:
            x -= self.left
        return Pos(self.y + pd + y, self.x + pd + self.gut + x)

    def set_wrap(mut self, on: Bool):
        self.wrap = on
        self.top_seg = 0
        self.left = 0
        self.sync_want()
        self.follow = True

    # ------------------------------------------------- highlighter state cache
    def sync_lex(mut self, upto: Int):
        """Bring the per-line lexer state cache up to date: re-scan the lines touched by
        edits until the state rejoins what was cached, then extend the cache so that it
        covers rows 0..upto. Call before drawing."""
        if self.kind != WK_EDITOR or self.buf.large:
            return
        var count = self.buf.count()
        var lang = self.effective_lang()
        if self.buf.ldirty_from >= 0:
            var row = self.buf.ldirty_from
            var last = self.buf.ldirty_to
            self.buf.ldirty_from = -1
            self.buf.ldirty_to = -1
            if row < len(self.buf.lstate):
                var st = Int(self.buf.lstate[row])
                var budget = LEX_BUDGET
                while row < count:
                    var bytes = self.buf.line_bytes(row)
                    st = line_state(bytes, 0, len(bytes), st, lang)
                    self.buf.lex_work += 1
                    if row + 1 >= len(self.buf.lstate):
                        self.buf.lstate.append(UInt8(st))
                    elif row >= last and Int(self.buf.lstate[row + 1]) == st:
                        break                       # rejoined the cached states
                    else:
                        self.buf.lstate[row + 1] = UInt8(st)
                    row += 1
                    budget -= 1
                    if budget <= 0 and row >= last:
                        # the change keeps propagating (e.g. a new open string): stop
                        # here and let the rest be rebuilt lazily when it is shown
                        while len(self.buf.lstate) > row + 1:
                            _ = self.buf.lstate.pop()
                        break
        # extend: scan whole lines in blocks straight from the stored bytes
        var want = min(upto, count - 1)
        while len(self.buf.lstate) - 1 < want:
            var known = len(self.buf.lstate) - 1
            var stop = min(count - 1, max(want, known + 1))
            stop = min(stop, known + LEX_BLOCK)
            var a = self.buf.core[].rope.line_start(known)
            var b = self.buf.core[].rope.line_start(stop)      # rows known..stop-1 end with a newline
            var block = self.buf.core[].rope.slice_bytes(a, b)
            _ = scan_states(block, Int(self.buf.lstate[known]), self.buf.lstate, lang)
            self.buf.lex_work += stop - known
            if len(self.buf.lstate) - 1 != stop:
                break                               # defensive: never loop forever

    def lex_state_at(self, row: Int) -> Int:
        """Lexer state at the start of `row`: from the cache when it covers the row,
        otherwise computed by scanning from the last cached line (slow path)."""
        if self.kind != WK_EDITOR or self.buf.large:
            return 0
        var lang = self.effective_lang()
        var known = len(self.buf.lstate) - 1
        var clean = self.buf.ldirty_from < 0 or self.buf.ldirty_from >= row
        if row <= known and clean:
            return Int(self.buf.lstate[row])
        var from_row = min(known, row) if clean else min(self.buf.ldirty_from, min(known, row))
        var st = Int(self.buf.lstate[from_row])
        for r in range(from_row, min(row, self.buf.count())):
            var bytes = self.buf.line_bytes(r)
            st = line_state(bytes, 0, len(bytes), st, lang)
        return st

    def ensure_visible(mut self):
        var rws = self.rows()
        self.reveal_cursor()
        if self.rowwise():
            if self.wrap:
                self.left = 0
            else:
                self.ensure_h()
            self.top = max(0, min(self.top, self.buf.count() - 1))
            if self.buf.hidden_by(self.top) >= 0:
                self.top = self.buf.hidden_by(self.top)
                self.top_seg = 0
            if self.cr < self.top or self.cr - self.top >= rws:
                # far away: start near the cursor line, then adjust by screen rows
                self.top = self.cr if self.cr < self.top else self.cr - rws + 1
                self.top_seg = 0
                if self.buf.hidden_by(self.top) >= 0:
                    self.top = self.buf.hidden_by(self.top)
            var y = self.screen_row_of(self.cr, self.cc, rws)
            if y < 0:
                var starts = List[Int]()
                var vs = List[Int]()
                self.wrap_layout(self.buf.line(self.cr), starts, vs)
                self.top = self.cr
                self.top_seg = self.seg_of(starts, self.cc)
                return
            var guard = 0
            while y >= rws and guard < 100000:
                self.advance_top(1)
                y = self.screen_row_of(self.cr, self.cc, rws)
                guard += 1
            return
        if self.cr < self.top:
            self.top = self.cr
        if self.cr >= self.top + rws:
            self.top = self.cr - rws + 1
        self.ensure_h()
        if self.top < 0:
            self.top = 0

    def ensure_h(mut self):
        """Scroll sideways until the cursor column is in view."""
        var cls = self.cols()
        var vc = self.vcol(self.cr, self.cc)
        if vc < self.left:
            self.left = max(0, vc - 4)
        if vc >= self.left + cls - 1:
            self.left = vc - cls + 2

    def scroll(mut self, d: Int):
        self.buf.sync_folds()
        if self.rowwise():
            self.advance_top(d)
            self.follow = False
            return
        var maxtop = max(0, self.buf.count() - 1)
        self.top = max(0, min(maxtop, self.top + d))
        self.follow = False

    def screen_to_pos(self, px: Int, py: Int) -> Pos:
        var pd = self.pad()
        var sy = py - self.y - pd
        if sy >= 0 and sy < len(self.sticky):
            # a pinned scope header: its own line
            var hr = self.sticky[sy]
            return Pos(hr, self.col_at_vcol(hr, max(0, px - self.x - pd - self.gut)))
        if self.rowwise():
            var at = self.pos_at_screen_row(max(0, py - self.y - pd))
            var wr = max(0, min(at.r, self.buf.count() - 1))
            if at.r >= self.buf.count():
                return Pos(wr, self.buf.llen(wr))
            var tseg = min(at.c, max(0, self.text_row_segs(wr) - 1))
            return Pos(wr, self.col_in_seg(wr, tseg, max(0, px - self.x - pd - self.gut) + (0 if self.wrap else self.left)))
        var r = self.top + (py - self.y - pd)
        var v = self.left + (px - self.x - pd - self.gut)
        r = max(0, min(r, self.buf.count() - 1))
        var c = self.col_at_vcol(r, max(0, v))
        return Pos(r, c)

    # ------------------------------------------------------------ groups
    def new_group(mut self) -> Int:
        if self.forced_group != 0:
            return self.forced_group
        self.gseq += 1
        self.cur_group = self.gseq
        return self.cur_group

    def group_for(mut self, act: Int) -> Int:
        if self.forced_group != 0:
            self.last_act = act
            return self.forced_group
        if act != self.last_act or act == ACT_OTHER or self.cur_group == 0:
            _ = self.new_group()
        self.last_act = act
        return self.cur_group

    def break_group(mut self):
        self.last_act = ACT_NONE

    # --------------------------------------------------------- selection
    def has_sel(self) -> Bool:
        if self.vsel != 0:
            return self.sel             # (vim: even one character, or one line)
        return self.sel and (self.ar != self.cr or self.ac != self.cc)

    def sel_range(self) -> Range:
        var r: Range
        if self.ar < self.cr or (self.ar == self.cr and self.ac < self.cc):
            r = Range(self.ar, self.ac, self.cr, self.cc)
        else:
            r = Range(self.cr, self.cc, self.ar, self.ac)
        if self.vsel == 1:
            # vim's Visual: the character at the far end is in it too
            r.c2 = min(r.c2 + 1, self.buf.llen(r.r2))
        elif self.vsel == 2:
            # Visual line: whole lines, with the line break after the last one
            r.c1 = 0
            if r.r2 + 1 < self.buf.count():
                r.r2 += 1
                r.c2 = 0
            else:
                r.c2 = self.buf.llen(r.r2)
        return r^

    def in_sel(self, r: Int, c: Int) -> Bool:
        if not self.has_sel():
            return False
        var s = self.sel_range()
        if r < s.r1 or r > s.r2:
            return False
        if r == s.r1 and c < s.c1:
            return False
        if r == s.r2 and c >= s.c2:
            return False
        return True

    def selected_text(self) -> List[Int]:
        if not self.has_sel():
            return List[Int]()
        var s = self.sel_range()
        return self.buf.get_text(s.r1, s.c1, s.r2, s.c2)

    def begin_move(mut self, shift: Bool):
        if shift:
            if not self.sel:
                self.sel = True
                self.ar = self.cr
                self.ac = self.cc
        else:
            self.sel = False
        self.sel_hist.clear()
        self.break_group()
        self.follow = True

    def select_all(mut self):
        self.extra.clear()
        self.sel = True
        self.ar = 0
        self.ac = 0
        self.cr = self.buf.count() - 1
        self.cc = self.buf.llen(self.cr)
        self.follow = True

    def clamp(mut self):
        self.cr = max(0, min(self.cr, self.buf.count() - 1))
        self.cc = max(0, min(self.cc, self.buf.llen(self.cr)))

    def goto(mut self, r: Int, c: Int):
        self.extra.clear()
        self.sel = False
        self.sel_hist.clear()
        self.cr = r
        self.cc = c
        self.clamp()
        self.sync_want()
        self.follow = True
        # center the target line
        self.top = max(0, self.cr - self.rows() // 2)
        self.break_group()

    def goto_cell(mut self, r: Int, c: Int = 0):
        """Move cursor smoothly to cell row `r` without recentering `self.top` away from outputs above."""
        self.extra.clear()
        self.sel = False
        self.sel_hist.clear()
        self.cr = r
        self.cc = c
        self.clamp()
        self.sync_want()
        self.follow = True
        self.break_group()

    def reveal_cell_output(mut self, hdr_row: Int, keep_cursor: Bool):
        """Adjust `(top, top_seg)` when a cell finishes so its `Out [k]` + inline image is visible
        in the viewport (alongside the next cell's cursor when `keep_cursor` is True on `Shift-Enter`)."""
        self.buf.sync_folds()
        var out_r = self.buf.cell_end_for_header(hdr_row)
        if out_r < 0 or out_r >= self.buf.count():
            return
        var v_rows = self.virtual_out_rows(out_r)
        if v_rows <= 0:
            return
        var rws = self.rows()
        if rws <= 3:
            return
        var t_segs = self.text_row_segs(out_r)
        if keep_cursor and self.cr >= out_r:
            self.ensure_visible()
            var starts = List[Int]()
            var vs = List[Int]()
            self.wrap_layout(self.buf.line(self.cr), starts, vs)
            var cur_seg = self.seg_of(starts, self.cc)
            # Screen rows from `(out_r, t_segs - 1)` down to `(self.cr, cur_seg)` inclusive
            var dist = 1 + v_rows
            if self.cr > out_r:
                var rr = self.buf.next_row(out_r)
                while rr < self.cr and dist <= rws + 64:
                    dist += self.row_segs(rr)
                    rr = self.buf.next_row(rr)
                dist += cur_seg + 1
            if dist <= rws - 1:
                var out_hidden_above = out_r < self.top or (out_r == self.top and self.top_seg >= t_segs)
                var cur_y = self.screen_row_of(self.cr, self.cc, rws)
                if out_hidden_above or cur_y < 0 or cur_y >= rws:
                    self.top = out_r
                    self.top_seg = max(0, t_segs - 1)
                    var spare = max(0, (rws - 1) - dist)
                    if spare > 0:
                        self.advance_top(-min(spare, 3))
                    self.follow = False
            else:
                self.top = self.cr
                self.top_seg = cur_seg
                self.advance_top(-max(1, rws - 2))
                self.follow = False
            return

        # `Ctrl-Enter` or `[▶ Run]` click: bring the newly rendered `Out [k]` + image into view!
        var anchor_y = self.screen_row_of(out_r, 0, rws + v_rows + 8)
        var out_bot_y = anchor_y + t_segs + v_rows - 1
        if anchor_y < 0 or out_bot_y >= rws:
            self.top = out_r
            self.top_seg = max(0, t_segs - 1)
            var room_above = max(0, rws - (1 + v_rows) - 1)
            if room_above > 0:
                self.advance_top(-min(room_above, 6))
            if self.cr >= hdr_row and self.cr <= out_r and self.screen_row_of(self.cr, self.cc, rws) < 0:
                self.cr = out_r
                self.cc = 0
                self.sync_want()
            self.follow = False

    # ----------------------------------------------------------- movement
    def move_left(mut self, shift: Bool, word: Bool):
        if not shift and self.has_sel():
            var s = self.sel_range()
            self.begin_move(False)
            self.cr = s.r1
            self.cc = s.c1
            self.sync_want()
            return
        self.begin_move(shift)
        if self.cc > 0:
            if word:
                var c = self.cc
                while c > 0 and not is_ident(self.buf.at(self.cr, c - 1)):
                    c -= 1
                while c > 0 and is_ident(self.buf.at(self.cr, c - 1)):
                    c -= 1
                self.cc = c
            else:
                self.cc = cluster_start(self.buf.line(self.cr), self.cc)
        elif self.cr > 0:
            self.buf.sync_folds()
            self.cr = max(0, self.buf.prev_row(self.cr))      # skips folded blocks
            self.cc = self.buf.llen(self.cr)
        self.sync_want()

    def move_right(mut self, shift: Bool, word: Bool):
        if not shift and self.has_sel():
            var s = self.sel_range()
            self.begin_move(False)
            self.cr = s.r2
            self.cc = s.c2
            self.sync_want()
            return
        self.begin_move(shift)
        var n = self.buf.llen(self.cr)
        if self.cc < n:
            if word:
                var c = self.cc
                while c < n and is_ident(self.buf.at(self.cr, c)):
                    c += 1
                while c < n and not is_ident(self.buf.at(self.cr, c)):
                    c += 1
                self.cc = c
            else:
                self.cc = cluster_end(self.buf.line(self.cr), self.cc)
        elif self.cr + 1 < self.buf.count():
            self.buf.sync_folds()
            var nr = self.buf.next_row(self.cr)                # skips folded blocks
            if nr < self.buf.count():
                self.cr = nr
                self.cc = 0
        self.sync_want()

    def move_vert(mut self, d: Int, shift: Bool):
        self.begin_move(shift)
        self.buf.sync_folds()
        if self.rowwise():
            # by screen rows, keeping the horizontal offset
            var steps = d if d > 0 else -d
            var count = self.buf.count()
            for _ in range(steps):
                var starts = List[Int]()
                var vs = List[Int]()
                self.wrap_layout(self.buf.line(self.cr), starts, vs)
                var k = self.seg_of(starts, self.cc)
                if d > 0:
                    if k + 1 < len(starts):
                        self.cc = self.col_in_seg(self.cr, k + 1, self.want)
                    elif self.buf.next_row(self.cr) < count:
                        self.cr = self.buf.next_row(self.cr)
                        self.cc = self.col_in_seg(self.cr, 0, self.want)
                    else:
                        break
                else:
                    if k > 0:
                        self.cc = self.col_in_seg(self.cr, k - 1, self.want)
                    elif self.buf.prev_row(self.cr) >= 0:
                        self.cr = self.buf.prev_row(self.cr)
                        self.cc = self.col_in_seg(self.cr, self.text_row_segs(self.cr) - 1, self.want)
                    else:
                        break
            return
        self.cr = max(0, min(self.buf.count() - 1, self.cr + d))
        self.cc = self.col_at_vcol(self.cr, self.want)

    def page(mut self, d: Int, shift: Bool):
        var n = self.rows() - 1
        self.buf.sync_folds()
        if self.rowwise():
            self.advance_top(d * n)
        else:
            self.top = max(0, min(self.buf.count() - 1, self.top + d * n))
        self.move_vert(d * n, shift)

    def home(mut self, shift: Bool, doc: Bool):
        self.begin_move(shift)
        if doc:
            self.cr = 0
            self.cc = 0
        else:
            var ind = 0
            var n = self.buf.llen(self.cr)
            while ind < n and self.buf.at(self.cr, ind) == 32:
                ind += 1
            self.cc = 0 if self.cc == ind else ind
        self.sync_want()

    def end(mut self, shift: Bool, doc: Bool):
        self.begin_move(shift)
        if doc:
            self.cr = self.buf.count() - 1
        self.cc = self.buf.llen(self.cr)
        self.sync_want()

    # ------------------------------------------------------------ editing
    def delete_sel(mut self, g: Int) -> Bool:
        if not self.has_sel():
            self.sel = False
            return False
        var s = self.sel_range()
        _ = self.buf.delete(s.r1, s.c1, s.r2, s.c2, self.cr, self.cc, g)
        self.cr = s.r1
        self.cc = s.c1
        self.sel = False
        return True

    def insert_text(mut self, text: List[Int], act: Int):
        var g = self.group_for(act)
        _ = self.delete_sel(g)
        var p = self.buf.insert(self.cr, self.cc, text, self.cr, self.cc, g)
        self.cr = p.r
        self.cc = p.c
        self.sync_want()
        self.follow = True

    def type_char(mut self, ch: Int, insert_mode: Bool):
        if not insert_mode and not self.has_sel() and self.cc < self.buf.llen(self.cr):
            var g = self.group_for(ACT_TYPE)
            _ = self.buf.delete(self.cr, self.cc, self.cr, self.cc + 1, self.cr, self.cc, g)
        var t = List[Int]()
        t.append(ch)
        self.insert_text(t, ACT_TYPE)

    def indent_of(self, r: Int) -> Int:
        """Number of leading whitespace characters (spaces or tabs)."""
        var i = 0
        var ln = self.buf.line(r)
        var n = len(ln)
        while i < n and (ln[i] == 32 or ln[i] == 9):
            i += 1
        return i

    def indent_unit(self) -> List[Int]:
        var t = List[Int]()
        if self.buf.use_tabs:
            t.append(9)
        else:
            for _ in range(self.buf.indent_size):
                t.append(32)
        return t^

    def newline(mut self, auto_indent: Bool):
        var t = List[Int]()
        t.append(10)
        if auto_indent:
            var ind = min(self.indent_of(self.cr), self.cc)
            var cur_line = self.buf.line(self.cr)
            for i in range(ind):
                t.append(cur_line[i])
            var k = self.cc - 1
            while k >= 0 and (self.buf.at(self.cr, k) == 32 or self.buf.at(self.cr, k) == 9):
                k -= 1
            if k >= 0 and self.buf.at(self.cr, k) == 58:
                for u in self.indent_unit():
                    t.append(u)
        self.insert_text(t, ACT_OTHER)
        self.break_group()

    def backspace(mut self):
        var g = self.group_for(ACT_BACK)
        if self.delete_sel(g):
            self.follow = True
            return
        if self.cc > 0:
            var n = 1
            var all_spaces = True
            var ln = self.buf.line(self.cr)
            for i in range(min(self.cc, len(ln))):
                if ln[i] != 32:
                    all_spaces = False
                    break
            if all_spaces:
                n = self.cc - ((self.cc - 1) // self.buf.indent_size) * self.buf.indent_size
            else:
                # a whole cluster (emoji sequence, flag, syllable) goes at once; a letter
                # with accents loses only its last accent
                var cs = cluster_start(ln, self.cc)
                if not ends_with_plain_mark(ln, cs, min(self.cc, len(ln))):
                    n = max(1, self.cc - cs)
            _ = self.buf.delete(self.cr, self.cc - n, self.cr, self.cc, self.cr, self.cc, g)
            self.cc -= n
        elif self.cr > 0:
            var pl = self.buf.llen(self.cr - 1)
            _ = self.buf.delete(self.cr - 1, pl, self.cr, 0, self.cr, self.cc, g)
            self.cr -= 1
            self.cc = pl
        self.sync_want()
        self.follow = True

    def delete_fwd(mut self):
        var g = self.group_for(ACT_DEL)
        if self.delete_sel(g):
            self.follow = True
            return
        if self.cc < self.buf.llen(self.cr):
            var ce = cluster_end(self.buf.line(self.cr), self.cc)
            _ = self.buf.delete(self.cr, self.cc, self.cr, ce, self.cr, self.cc, g)
        elif self.cr + 1 < self.buf.count():
            _ = self.buf.delete(self.cr, self.cc, self.cr + 1, 0, self.cr, self.cc, g)
        self.follow = True

    def line_span(self) -> Range:
        """Rows covered by the selection (or the cursor line)."""
        if not self.has_sel():
            return Range(self.cr, 0, self.cr, 0)
        var s = self.sel_range()
        var r2 = s.r2
        if s.c2 == 0 and r2 > s.r1:
            r2 -= 1
        return Range(s.r1, 0, r2, 0)

    def indent_lines(mut self, dir: Int):
        var span = self.line_span()
        var g = self.new_group()
        for r in range(span.r1, span.r2 + 1):
            if dir > 0:
                if self.buf.llen(r) == 0:
                    continue
                var sp = self.indent_unit()
                _ = self.buf.insert(r, 0, sp, self.cr, self.cc, g)
                if r == self.cr:
                    self.cc += len(sp)
                if self.sel and r == self.ar and self.ac > 0:
                    self.ac += len(sp)
            else:
                var n = 0
                if self.buf.at(r, 0) == 9:
                    n = 1
                else:
                    while n < self.buf.indent_size and self.buf.at(r, n) == 32:
                        n += 1
                if n == 0:
                    continue
                _ = self.buf.delete(r, 0, r, n, self.cr, self.cc, g)
                if r == self.cr:
                    self.cc = max(0, self.cc - n)
                if self.sel and r == self.ar:
                    self.ac = max(0, self.ac - n)
        self.break_group()
        self.clamp()
        self.follow = True

    def tab(mut self, shift: Bool):
        if shift or (self.has_sel() and self.sel_range().r1 != self.sel_range().r2):
            self.indent_lines(-1 if shift else 1)
            return
        var t = List[Int]()
        if self.buf.use_tabs:
            t.append(9)
        else:
            var n = self.buf.indent_size - (self.vcol(self.cr, self.cc) % self.buf.indent_size)
            for _ in range(n):
                t.append(32)
        self.insert_text(t, ACT_TYPE)

    def toggle_comment(mut self):
        var span = self.line_span()
        var all_commented = True
        var min_ind = 1 << 30
        for r in range(span.r1, span.r2 + 1):
            if self.buf.llen(r) == 0:
                continue
            var ind = self.indent_of(r)
            min_ind = min(min_ind, ind)
            if self.buf.at(r, ind) != 35:
                all_commented = False
        if min_ind == 1 << 30:
            return
        var g = self.new_group()
        for r in range(span.r1, span.r2 + 1):
            if self.buf.llen(r) == 0:
                continue
            if all_commented:
                var ind = self.indent_of(r)
                var n = 2 if self.buf.at(r, ind + 1) == 32 else 1
                _ = self.buf.delete(r, ind, r, ind + n, self.cr, self.cc, g)
                if r == self.cr and self.cc > ind:
                    self.cc = max(ind, self.cc - n)
            else:
                var t = List[Int]()
                t.append(35)
                t.append(32)
                _ = self.buf.insert(r, min_ind, t, self.cr, self.cc, g)
                if r == self.cr and self.cc >= min_ind:
                    self.cc += 2
        self.sel = False
        self.break_group()
        self.clamp()
        self.follow = True

    def duplicate_line(mut self):
        var g = self.new_group()
        var t = List[Int]()
        t.append(10)
        for c in self.buf.line(self.cr):
            t.append(c)
        _ = self.buf.insert(self.cr, self.buf.llen(self.cr), t, self.cr, self.cc, g)
        self.cr += 1
        self.sel = False
        self.break_group()
        self.follow = True

    def delete_line(mut self) -> List[Int]:
        var g = self.new_group()
        var out: List[Int]
        if self.cr + 1 < self.buf.count():
            out = self.buf.delete(self.cr, 0, self.cr + 1, 0, self.cr, self.cc, g)
        elif self.cr > 0:
            out = self.buf.delete(self.cr - 1, self.buf.llen(self.cr - 1), self.cr, self.buf.llen(self.cr), self.cr, self.cc, g)
            self.cr -= 1
        else:
            out = self.buf.delete(0, 0, 0, self.buf.llen(0), self.cr, self.cc, g)
        self.sel = False
        self.clamp()
        self.break_group()
        self.follow = True
        return out^

    def trim_trailing_whitespace(mut self) -> Int:
        """Remove spaces and tabs at line ends as one undo step. Returns lines changed."""
        var g = 0
        var changed = 0
        for r in range(self.buf.count()):
            var ln = self.buf.line(r)
            var n = len(ln)
            var e = n
            while e > 0 and (ln[e - 1] == 32 or ln[e - 1] == 9):
                e -= 1
            if e < n:
                if g == 0:
                    g = self.new_group()
                _ = self.buf.delete(r, e, r, n, self.cr, self.cc, g)
                changed += 1
        if changed > 0:
            self.clamp()
            if self.sel:
                self.ar = max(0, min(self.ar, self.buf.count() - 1))
                self.ac = max(0, min(self.ac, self.buf.llen(self.ar)))
            self.sync_want()
            self.break_group()
        return changed

    def undo(mut self):
        self.extra.clear()
        var p = self.buf.undo()
        if p.r >= 0:
            self.sel = False
            self.cr = p.r
            self.cc = p.c
            self.clamp()
            self.sync_want()
        self.break_group()
        self.follow = True

    def redo(mut self):
        self.extra.clear()
        var p = self.buf.redo()
        if p.r >= 0:
            self.sel = False
            self.cr = p.r
            self.cc = p.c
            self.clamp()
            self.sync_want()
        self.break_group()
        self.follow = True

    def replace_all_text(mut self, cps: List[Int]):
        """Replace the whole buffer as one undo step (used by the formatter)."""
        self.extra.clear()
        var g = self.new_group()
        _ = replace_all_text_diff(self.buf, cps, g)
        self.sel = False
        self.clamp()
        self.break_group()
        self.follow = True

    def set_cell_badge(mut self, row: Int, badge: String):
        self.buf.set_cell_badge(row, badge)
        self.sync_cell_badges()

    def set_cell_output(
        mut self,
        row: Int,
        text: String,
        is_err: Bool,
        plots_joined: String = "",
        exec_count: Int = 0,
    ):
        self.buf.set_cell_output(row, text, is_err, plots_joined, exec_count)
        self.sync_cell_badges()

    def clear_cell_outputs(mut self):
        self.buf.clear_cell_outputs()
        self.img_cache[].clear(self.gfx_tmux)
        self.top_seg = 0
        self.follow = True

    def clear_cell_badges(mut self):
        self.buf.clear_cell_badges()
        self.cell_badge_rows.clear()
        self.cell_badges.clear()
        self.top_seg = 0

    def sync_cell_badges(mut self):
        var count = self.buf.count()
        if len(self.buf.cell_badge_rows) > 0:
            var krows = List[Int]()
            var kvals = List[String]()
            for i in range(len(self.buf.cell_badge_rows)):
                var br = self.buf.cell_badge_rows[i]
                if br >= 0 and br < count and i < len(self.buf.cell_badges):
                    if br == 0 or self.buf.is_cell_header(br):
                        krows.append(br)
                        kvals.append(self.buf.cell_badges[i])
            self.buf.cell_badge_rows = krows.copy()
            self.buf.cell_badges = kvals.copy()
            self.cell_badge_rows = krows^
            self.cell_badges = kvals^
        if len(self.buf.cell_out_rows) > 0:
            var orows = List[Int]()
            var otexts = List[String]()
            var oerrs = List[Bool]()
            var oplots = List[String]()
            var ocounts = List[Int]()
            for i in range(len(self.buf.cell_out_rows)):
                var obr = self.buf.cell_out_rows[i]
                if obr >= 0 and obr < count and i < len(self.buf.cell_out_texts):
                    if obr == 0 or self.buf.is_cell_header(obr):
                        orows.append(obr)
                        otexts.append(self.buf.cell_out_texts[i])
                        oerrs.append(self.buf.cell_out_errs[i])
                        oplots.append(self.buf.cell_out_plots[i])
                        ocounts.append(self.buf.cell_out_counts[i])
            self.buf.cell_out_rows = orows^
            self.buf.cell_out_texts = otexts^
            self.buf.cell_out_errs = oerrs^
            self.buf.cell_out_plots = oplots^
            self.buf.cell_out_counts = ocounts^

    def lsp_to_virtual_pos(self, row: Int, col16: Int) -> Tuple[Int, Int]:
        if self.lsp_nb_active and row >= 0 and row < len(self.lsp_nb_b2v_row):
            var vr = self.lsp_nb_b2v_row[row]
            if vr >= 0:
                return (vr, col16 + self.lsp_nb_b2v_col[row])
        return (row, col16)

    def lsp_from_virtual_pos(self, vrow: Int, vcol16: Int) -> Tuple[Int, Int]:
        if self.lsp_nb_active:
            if vrow < 0 or vrow >= len(self.lsp_nb_v2b_row):
                return (-1, 0)
            var br = self.lsp_nb_v2b_row[vrow]
            if br < 0:
                return (-1, 0)
            return (br, max(0, vcol16 - self.lsp_nb_v2b_col[vrow]))
        return (vrow, vcol16)
