"""Self-contained HTML notebook export and zero-server AF_UNIX collaborative Live Share.

Provides:
- Standalone zero-CDN/zero-JS HTML5 notebook exporter (`export_notebook_html`,
  `render_notebook_cells_html`, `export_ipynb_bytes_to_html`, `export_ipynb_file_to_html`)
  with polyglot Mojo/Python syntax highlighting, Markdown + inline math rendering,
  collapsible hidden-source `<details>` cells, `[Tensor]` / `[DataFrame]` badges, and
  embedded base64 PNG/GIF media (`data:image/png;base64,...`, `data:image/gif;base64,...`).
- Zero-server collaborative Live Share (`LiveShareSession`, `LiveShareEvent`, `PeerCursor`)
  over non-blocking POSIX `AF_UNIX` stream sockets (local `/tmp/*.sock` or SSH `-L`
  forwarded UNIX domain sockets) across Linux and macOS.
"""
import platform
from std.collections import List
from std.ffi import external_call
from highlight import (
    Highlighter,
    HL_MOJO,
    HL_PYTHON,
    lang_for_path,
    C_KW,
    C_TYPE,
    C_CMT,
    C_STR,
    C_NUM,
    C_DECO,
    C_SYM,
    C_BUILTIN,
    C_SELF,
    C_DEF,
)
from ipynb import (
    IpynbDocument,
    IpynbCellOutput,
    ipynb_to_percent_text,
    ipynb_b64_decode,
    is_ipynb_path,
    strip_utf8_bom,
)
from json import json_parse, JsonWriter, J_ARR, J_OBJ, J_STR
from nb_widgets import encode_gif89a
from png import Picture, png_decode
from proc import ignore_sigpipe
from util import (
    read_file,
    write_file,
    str_bytes,
    bytes_to_str,
    base64,
    decode,
    slice_str,
    lower_str,
    basename,
    path_exists,
)

comptime IS_MACOS = platform.IS_MACOS
comptime AF_UNIX = 1
comptime SOCK_STREAM = 1
comptime F_SETFD = platform.F_SETFD
comptime FD_CLOEXEC = platform.FD_CLOEXEC
comptime F_GETFL = platform.F_GETFL
comptime F_SETFL = platform.F_SETFL
comptime O_NONBLOCK = platform.O_NONBLOCK

comptime SOCKADDR_UN_LEN = 106 if IS_MACOS else 110
comptime SUN_PATH_MAX = 103 if IS_MACOS else 107

comptime LS_OFF = 0
comptime LS_HOST = 1
comptime LS_CLIENT = 2


# ---------------------------------------------------------------------------
# Part 1: Self-Contained Standalone HTML Notebook Exporter
# ---------------------------------------------------------------------------


@fieldwise_init
struct HtmlCellView(Copyable, Movable):
    var index: Int
    var title: String
    var is_markdown: Bool
    var is_folded: Bool
    var exec_count: Int
    var source: String
    var output_text: String
    var is_error: Bool
    var media_data_uris: List[String]


def html_escape(s: String) -> String:
    """Escape `&`, `<`, `>`, `\"`, and `'` for safe HTML text and attribute contexts."""
    var out = List[UInt8]()
    for b in s.as_bytes():
        if b == 38:  # &
            for c in "&amp;".as_bytes():
                out.append(c)
        elif b == 60:  # <
            for c in "&lt;".as_bytes():
                out.append(c)
        elif b == 62:  # >
            for c in "&gt;".as_bytes():
                out.append(c)
        elif b == 34:  # "
            for c in "&quot;".as_bytes():
                out.append(c)
        elif b == 39:  # '
            for c in "&#39;".as_bytes():
                out.append(c)
        else:
            out.append(b)
    return bytes_to_str(out)


def _token_css_class(tok_cls: Int) -> String:
    if tok_cls == C_KW:
        return "tk-kw"
    if tok_cls == C_STR:
        return "tk-str"
    if tok_cls == C_CMT:
        return "tk-cmt"
    if tok_cls == C_NUM:
        return "tk-num"
    if tok_cls == C_TYPE:
        return "tk-type"
    if tok_cls == C_DEF:
        return "tk-fn"
    if tok_cls == C_BUILTIN:
        return "tk-builtin"
    if tok_cls == C_DECO:
        return "tk-preproc"
    if tok_cls == C_SELF:
        return "tk-self"
    if tok_cls == C_SYM:
        return "tk-sym"
    return ""


def highlight_code_to_html(code: String, is_mojo: Bool = True) -> String:
    """Syntax-highlight Mojo or Python source into `<pre><code>` HTML with zero JS/CDN deps."""
    var norm = code.replace("\r\n", "\n")
    if norm.endswith("\n"):
        var trimmed = String(norm[byte=0 : norm.byte_length() - 1])
        norm = trimmed
    var hl = Highlighter()
    var lang = HL_MOJO if is_mojo else HL_PYTHON
    var st = 0
    var cls = List[Int]()
    var out_lines = List[String]()

    if norm.byte_length() == 0:
        return "<pre><code></code></pre>"

    for ln_slice in norm.split("\n"):
        var ln = String(ln_slice)
        var cps = decode(ln)
        var n = len(cps)
        st = hl.line(cps, st, cls, lang)
        var line_parts = List[String]()
        var i = 0
        while i < n:
            var cur_c = cls[i]
            var j = i + 1
            while j < n and cls[j] == cur_c:
                j += 1
            var esc = html_escape(slice_str(cps, i, j))
            var css = _token_css_class(cur_c)
            if css.byte_length() > 0:
                line_parts.append("<span class=\"" + css + "\">" + esc + "</span>")
            else:
                line_parts.append(esc)
            i = j
        out_lines.append("".join(line_parts))

    return "<pre><code>" + "\n".join(out_lines) + "</code></pre>"


def _sanitize_link_url(raw_url: String) -> String:
    var u = String(raw_url.strip())
    var low = lower_str(u)
    if (
        low.startswith("javascript:")
        or low.startswith("vbscript:")
        or low.startswith("data:text/html")
    ):
        return "#"
    return html_escape(u)


def _render_inline_markdown(text: String) -> String:
    """Convert inline code, `$...$` math, `[lbl](url)` links, `**bold**`, and `*em*` to HTML."""
    var cps = decode(text)
    var n = len(cps)
    var parts = List[String]()
    var i = 0

    while i < n:
        var c = cps[i]
        # Inline code `...`
        if c == 96:
            var j = i + 1
            while j < n and cps[j] != 96:
                j += 1
            if j < n:
                parts.append("<code>" + html_escape(slice_str(cps, i + 1, j)) + "</code>")
                i = j + 1
                continue

        # Display/inline math $$...$$ or $...$
        if c == 36:
            if i + 1 < n and cps[i + 1] == 36:
                var j2 = i + 2
                var found2 = -1
                while j2 + 1 < n:
                    if cps[j2] == 36 and cps[j2 + 1] == 36:
                        found2 = j2
                        break
                    j2 += 1
                if found2 > i + 2:
                    parts.append(
                        "<span class=\"nb-math nb-math-display\">"
                        + html_escape(slice_str(cps, i + 2, found2))
                        + "</span>"
                    )
                    i = found2 + 2
                    continue
            else:
                var j1 = i + 1
                var found1 = -1
                while j1 < n:
                    if cps[j1] == 36:
                        found1 = j1
                        break
                    j1 += 1
                if found1 > i + 1:
                    parts.append(
                        "<span class=\"nb-math\">"
                        + html_escape(slice_str(cps, i + 1, found1))
                        + "</span>"
                    )
                    i = found1 + 1
                    continue

        # Markdown link [label](url)
        if c == 91:
            var rb = -1
            for k in range(i + 1, n):
                if cps[k] == 93:
                    rb = k
                    break
            if rb >= i + 1 and rb + 1 < n and cps[rb + 1] == 40:
                var rp = -1
                for k in range(rb + 2, n):
                    if cps[k] == 41:
                        rp = k
                        break
                if rp > rb + 1:
                    var lbl = slice_str(cps, i + 1, rb)
                    var url = slice_str(cps, rb + 2, rp)
                    parts.append(
                        "<a href=\""
                        + _sanitize_link_url(url)
                        + "\">"
                        + _render_inline_markdown(lbl)
                        + "</a>"
                    )
                    i = rp + 1
                    continue

        # Bold **...**
        if c == 42 and i + 1 < n and cps[i + 1] == 42:
            var jb = i + 2
            var found_b = -1
            while jb + 1 < n:
                if cps[jb] == 42 and cps[jb + 1] == 42:
                    found_b = jb
                    break
                jb += 1
            if found_b > i + 2:
                parts.append(
                    "<strong>"
                    + _render_inline_markdown(slice_str(cps, i + 2, found_b))
                    + "</strong>"
                )
                i = found_b + 2
                continue

        # Italic *...*
        if c == 42 and i + 1 < n and cps[i + 1] != 32:
            var ji = i + 1
            var found_i = -1
            while ji < n:
                if cps[ji] == 42:
                    found_i = ji
                    break
                ji += 1
            if found_i > i + 1:
                parts.append(
                    "<em>"
                    + _render_inline_markdown(slice_str(cps, i + 1, found_i))
                    + "</em>"
                )
                i = found_i + 1
                continue

        parts.append(html_escape(slice_str(cps, i, i + 1)))
        i += 1

    return "".join(parts)


def _flush_md_para(mut para: List[String], mut blocks: List[String]):
    if len(para) > 0:
        blocks.append("<p>" + _render_inline_markdown(" ".join(para)) + "</p>")
        para.clear()


def _flush_md_list(mut items: List[String], mut blocks: List[String]):
    if len(items) > 0:
        blocks.append("<ul>" + "".join(items) + "</ul>")
        items.clear()


def _flush_md_quote(mut qlines: List[String], mut blocks: List[String]):
    if len(qlines) > 0:
        blocks.append("<blockquote><p>" + _render_inline_markdown(" ".join(qlines)) + "</p></blockquote>")
        qlines.clear()


def render_markdown_to_html(md: String) -> String:
    """Render Markdown headings, lists, quotes, code fences, links, bold, code, and `$...$` math."""
    var norm = md.replace("\r\n", "\n")
    var lines = List[String]()
    for s in norm.split("\n"):
        lines.append(String(s))

    var blocks = List[String]()
    var para = List[String]()
    var list_items = List[String]()
    var quote_lines = List[String]()

    var i = 0
    var total = len(lines)
    while i < total:
        var raw_ln = lines[i]
        var lstripped = String(raw_ln.lstrip())
        var stripped = String(raw_ln.strip())

        # Fenced code block ```lang ... ```
        if lstripped.startswith("```"):
            _flush_md_para(para, blocks)
            _flush_md_list(list_items, blocks)
            _flush_md_quote(quote_lines, blocks)
            var fence_info = lower_str(String(lstripped[byte=3:].strip()))
            var code_lines = List[String]()
            i += 1
            while i < total:
                var cl = String(lines[i].lstrip())
                if cl.startswith("```"):
                    i += 1
                    break
                code_lines.append(lines[i])
                i += 1
            var body = "\n".join(code_lines)
            if fence_info == "mojo" or fence_info == "🔥":
                blocks.append(highlight_code_to_html(body, True))
            elif fence_info == "python" or fence_info == "py":
                blocks.append(highlight_code_to_html(body, False))
            else:
                blocks.append("<pre><code>" + html_escape(body) + "</code></pre>")
            continue

        # Blank line
        if stripped.byte_length() == 0:
            _flush_md_para(para, blocks)
            _flush_md_list(list_items, blocks)
            _flush_md_quote(quote_lines, blocks)
            i += 1
            continue

        # Headings # .. ######
        if lstripped.startswith("#"):
            var h_bytes = lstripped.as_bytes()
            var lvl = 0
            while lvl < len(h_bytes) and lvl < 6 and h_bytes[lvl] == 35:
                lvl += 1
            if lvl > 0 and lvl < len(h_bytes) and h_bytes[lvl] == 32:
                _flush_md_para(para, blocks)
                _flush_md_list(list_items, blocks)
                _flush_md_quote(quote_lines, blocks)
                var h_text = String(lstripped[byte=lvl + 1 :].strip())
                var tag = "h" + String(lvl)
                blocks.append("<" + tag + ">" + _render_inline_markdown(h_text) + "</" + tag + ">")
                i += 1
                continue

        # Horizontal rule
        if stripped == "---" or stripped == "***" or stripped == "___":
            _flush_md_para(para, blocks)
            _flush_md_list(list_items, blocks)
            _flush_md_quote(quote_lines, blocks)
            blocks.append("<hr>")
            i += 1
            continue

        # Blockquote > ...
        if lstripped.startswith(">"):
            _flush_md_para(para, blocks)
            _flush_md_list(list_items, blocks)
            var q_body = String(lstripped[byte=1:])
            if q_body.startswith(" "):
                var sub_q = String(q_body[byte=1:])
                q_body = sub_q
            quote_lines.append(String(q_body.strip()))
            i += 1
            continue

        # Bullet list - / * / +
        if (
            lstripped.startswith("- ")
            or lstripped.startswith("* ")
            or lstripped.startswith("+ ")
        ):
            _flush_md_para(para, blocks)
            _flush_md_quote(quote_lines, blocks)
            var item_txt = String(lstripped[byte=2:].strip())
            list_items.append("<li>" + _render_inline_markdown(item_txt) + "</li>")
            i += 1
            continue

        _flush_md_list(list_items, blocks)
        _flush_md_quote(quote_lines, blocks)
        para.append(stripped)
        i += 1

    _flush_md_para(para, blocks)
    _flush_md_list(list_items, blocks)
    _flush_md_quote(quote_lines, blocks)
    return "\n".join(blocks)


def _format_output_line_html(raw_line: String) -> String:
    """Style `[Tensor ...]`, `[Array ...]`, `[SIMD ...]`, and `[DataFrame ...]` badges."""
    var ln = raw_line
    if ln.startswith("__TM_CARD__ "):
        var trimmed = String(ln[byte=12:])
        ln = trimmed
    var lb = ln.find("[")
    var rb = ln.rfind("]")
    if lb >= 0 and rb > lb:
        var card = String(ln[byte=lb : rb + 1])
        var is_tensor = (
            card.startswith("[Tensor")
            or card.startswith("[Array")
            or card.startswith("[SIMD")
        )
        var is_df = card.startswith("[DataFrame") or card.startswith("[Polars")
        if is_tensor or is_df:
            var pre = String(ln[byte=0:lb])
            var post = String(ln[byte=rb + 1 :])
            var bcls = "nb-badge nb-badge-tensor" if is_tensor else "nb-badge nb-badge-df"
            return (
                html_escape(pre)
                + "<span class=\""
                + bcls
                + "\">"
                + html_escape(card)
                + "</span>"
                + html_escape(post)
            )
    return html_escape(ln)


def _render_output_text_html(text: String, is_error: Bool) -> String:
    var norm = text.replace("\r\n", "\n")
    if is_error:
        return "<pre class=\"nb-traceback\">" + html_escape(norm) + "</pre>"
    var rendered = List[String]()
    for s in norm.split("\n"):
        rendered.append(_format_output_line_html(String(s)))
    return "<pre class=\"nb-stdout\">" + "\n".join(rendered) + "</pre>"


def _normalize_media_data_uri(raw: String) -> String:
    var u = String(raw.strip())
    if u.byte_length() == 0:
        return ""
    var low = lower_str(u)
    if low.startswith("data:image/png;base64,") or low.startswith("data:image/gif;base64,"):
        return u
    if low.startswith("data:image/"):
        return u
    if low.startswith("data:") or low.startswith("javascript:"):
        return ""
    if u.startswith("ANIM|"):
        var body = String(u[byte=5:])
        var bar = body.find("|")
        if bar > 0:
            var fps_raw = String(body[byte=0:bar].strip())
            var fps = 12
            if fps_raw.byte_length() > 0:
                var acc = 0
                for fb in fps_raw.as_bytes():
                    if fb >= 48 and fb <= 57:
                        acc = acc * 10 + (Int(fb) - 48)
                if acc > 0:
                    fps = min(60, acc)
            var rest = String(body[byte=bar + 1 :])
            var sep = "\t" if rest.find("\t") >= 0 else "|"
            var pics = List[Picture]()
            var first_b64 = String("")
            for frame_s in rest.split(sep):
                var f = String(frame_s.strip())
                if f.byte_length() == 0:
                    continue
                var png_bytes = read_file(f) if (f.startswith("/") or path_exists(f)) else ipynb_b64_decode(f)
                if first_b64.byte_length() == 0 and len(png_bytes) > 0:
                    first_b64 = base64(png_bytes)
                var pic = png_decode(png_bytes)
                if pic.ok:
                    pics.append(pic^)
            if len(pics) >= 2:
                var gif_bytes = encode_gif89a(pics, fps)
                if len(gif_bytes) > 0:
                    return "data:image/gif;base64," + base64(gif_bytes)
            if first_b64.byte_length() > 0:
                return "data:image/png;base64," + first_b64
        return ""
    if u.startswith("R0lGOD"):
        return "data:image/gif;base64," + u
    return "data:image/png;base64," + u


comptime _NOTEBOOK_HTML_CSS = """
:root {
  color-scheme: dark light;
  --bg: #0d1117;
  --card-bg: #161b22;
  --code-bg: #0f141b;
  --hdr-bg: #1c2330;
  --out-bg: #121720;
  --border: #30363d;
  --fg: #e6edf3;
  --muted: #8b949e;
  --accent: #ff7b39;
  --out-accent: #58a6ff;
  --err-bg: #2d1216;
  --err-border: #f85149;
  --err-fg: #ffa198;
  --badge-tensor-bg: #162b44;
  --badge-tensor-fg: #79c0ff;
  --badge-df-bg: #163325;
  --badge-df-fg: #56d364;
  --tk-kw: #ff7b72;
  --tk-str: #a5d6ff;
  --tk-cmt: #8b949e;
  --tk-num: #79c0ff;
  --tk-type: #ffa657;
  --tk-fn: #d2a8ff;
  --tk-builtin: #7ee787;
  --tk-preproc: #f2cc60;
  --tk-self: #ff9bce;
  --tk-sym: #c9d1d9;
}
@media (prefers-color-scheme: light) {
  :root {
    --bg: #f6f8fa;
    --card-bg: #ffffff;
    --code-bg: #f6f8fa;
    --hdr-bg: #eef2f7;
    --out-bg: #fafbfc;
    --border: #d0d7de;
    --fg: #1f2328;
    --muted: #59636e;
    --accent: #cf4a08;
    --out-accent: #0969da;
    --err-bg: #ffebe9;
    --err-border: #cf222e;
    --err-fg: #a40e26;
    --badge-tensor-bg: #ddf4ff;
    --badge-tensor-fg: #0550ae;
    --badge-df-bg: #dafbe1;
    --badge-df-fg: #116329;
    --tk-kw: #cf222e;
    --tk-str: #0a3069;
    --tk-cmt: #6e7781;
    --tk-num: #0550ae;
    --tk-type: #953800;
    --tk-fn: #8250df;
    --tk-builtin: #116329;
    --tk-preproc: #7d4e00;
    --tk-self: #bf3989;
    --tk-sym: #24292f;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0;
  padding: 2rem 1rem 4rem;
  background: var(--bg);
  color: var(--fg);
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  line-height: 1.6;
}
.nb-container { max-width: 960px; margin: 0 auto; }
.nb-banner {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1rem;
  margin-bottom: 1.75rem;
  padding-bottom: 1rem;
  border-bottom: 1px solid var(--border);
}
.nb-banner h1 { margin: 0; font-size: 1.55rem; letter-spacing: -0.01em; }
.nb-kernel-pill {
  font-size: 0.78rem;
  font-weight: 600;
  padding: 0.22rem 0.65rem;
  border-radius: 999px;
  border: 1px solid var(--border);
  background: var(--card-bg);
  color: var(--accent);
}
.nb-cell {
  margin-bottom: 1.25rem;
  border: 1px solid var(--border);
  border-radius: 10px;
  background: var(--card-bg);
  overflow: hidden;
}
.nb-markdown { padding: 1rem 1.35rem; }
.nb-markdown h1, .nb-markdown h2, .nb-markdown h3, .nb-markdown h4 {
  margin-top: 0.4rem;
  margin-bottom: 0.6rem;
}
.nb-markdown code {
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 0.88em;
  background: var(--code-bg);
  padding: 0.12rem 0.36rem;
  border-radius: 4px;
}
.nb-markdown blockquote {
  margin: 0.75rem 0;
  padding: 0.25rem 1rem;
  border-left: 3px solid var(--accent);
  color: var(--muted);
}
.nb-math {
  font-family: "Cambria Math", "STIX Two Math", Georgia, serif;
  font-style: italic;
  padding: 0.05rem 0.25rem;
  border-radius: 4px;
  background: var(--code-bg);
}
.nb-cell-header {
  display: flex;
  align-items: center;
  gap: 0.65rem;
  padding: 0.45rem 0.9rem;
  background: var(--hdr-bg);
  border-bottom: 1px solid var(--border);
  font-size: 0.82rem;
}
details.nb-fold > summary.nb-cell-header {
  cursor: pointer;
  user-select: none;
  border-bottom: none;
}
details.nb-fold[open] > summary.nb-cell-header {
  border-bottom: 1px solid var(--border);
}
.nb-prompt {
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-weight: 600;
  font-size: 0.78rem;
}
.nb-in { color: var(--accent); }
.nb-out { color: var(--out-accent); }
.nb-cell-title { color: var(--muted); font-weight: 500; }
.nb-source pre, .nb-markdown pre {
  margin: 0;
  padding: 0.9rem 1.1rem;
  background: var(--code-bg);
  overflow-x: auto;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 0.86rem;
  line-height: 1.5;
}
.nb-output {
  border-top: 1px solid var(--border);
  background: var(--out-bg);
  padding: 0.65rem 1rem 0.85rem;
}
.nb-output-error {
  background: var(--err-bg);
  border-top-color: var(--err-border);
}
.nb-out-header { margin-bottom: 0.35rem; }
.nb-stdout, .nb-traceback {
  margin: 0;
  white-space: pre-wrap;
  word-break: break-word;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 0.84rem;
  line-height: 1.48;
}
.nb-traceback { color: var(--err-fg); }
.nb-badge {
  display: inline-block;
  padding: 0.12rem 0.5rem;
  border-radius: 6px;
  font-weight: 600;
  font-size: 0.81rem;
}
.nb-badge-tensor { background: var(--badge-tensor-bg); color: var(--badge-tensor-fg); }
.nb-badge-df { background: var(--badge-df-bg); color: var(--badge-df-fg); }
.nb-media {
  display: flex;
  justify-content: center;
  margin-top: 0.65rem;
}
.nb-plot {
  max-width: 100%;
  height: auto;
  border-radius: 6px;
  border: 1px solid var(--border);
}
.tk-kw { color: var(--tk-kw); font-weight: 600; }
.tk-str { color: var(--tk-str); }
.tk-cmt { color: var(--tk-cmt); font-style: italic; }
.tk-num { color: var(--tk-num); }
.tk-type { color: var(--tk-type); }
.tk-fn { color: var(--tk-fn); font-weight: 600; }
.tk-builtin { color: var(--tk-builtin); }
.tk-preproc { color: var(--tk-preproc); }
.tk-self { color: var(--tk-self); }
.tk-sym { color: var(--tk-sym); }
"""


def render_notebook_cells_html(
    title: String, cells: List[HtmlCellView], is_mojo: Bool = True
) -> String:
    """Render `cells` as a standalone responsive HTML5 notebook report with dark/light CSS."""
    var doc_title = title if title.byte_length() > 0 else String("TurboMojo Notebook")
    var kernel_label = "Mojo 1.2" if is_mojo else "Python 3"
    var parts = List[String]()

    parts.append("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n")
    parts.append("  <meta charset=\"utf-8\">\n")
    parts.append("  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
    parts.append("  <title>" + html_escape(doc_title) + "</title>\n")
    parts.append("  <style>" + _NOTEBOOK_HTML_CSS + "</style>\n")
    parts.append("</head>\n<body>\n  <main class=\"nb-container\">\n")
    parts.append(
        "    <header class=\"nb-banner\"><h1>"
        + html_escape(doc_title)
        + "</h1><span class=\"nb-kernel-pill\">"
        + kernel_label
        + "</span></header>\n"
    )

    for idx in range(len(cells)):
        var c = cells[idx].copy()
        var cid = "cell-" + String(c.index)
        if c.is_markdown:
            var md_html = render_markdown_to_html(c.source)
            if c.is_folded:
                var sum_lbl = c.title if c.title.byte_length() > 0 else String("Markdown")
                parts.append(
                    "    <section class=\"nb-cell nb-md-cell\" id=\""
                    + cid
                    + "\"><details class=\"nb-fold\"><summary class=\"nb-cell-header\">"
                    + "<span class=\"nb-cell-title\">"
                    + html_escape(sum_lbl)
                    + "</span></summary><div class=\"nb-markdown\">"
                    + md_html
                    + "</div></details></section>\n"
                )
            else:
                parts.append(
                    "    <section class=\"nb-cell nb-md-cell\" id=\""
                    + cid
                    + "\"><div class=\"nb-markdown\">"
                    + md_html
                    + "</div></section>\n"
                )
            continue

        var in_badge = (
            "In [" + String(c.exec_count) + "]" if c.exec_count > 0 else String("In [ ]")
        )
        var out_badge = (
            "Out [" + String(c.exec_count) + "]" if c.exec_count > 0 else String("Out [ ]")
        )
        var code_html = highlight_code_to_html(c.source, is_mojo)
        var title_html = (
            "<span class=\"nb-cell-title\">" + html_escape(c.title) + "</span>"
            if c.title.byte_length() > 0
            else String("")
        )

        parts.append("    <section class=\"nb-cell nb-code-cell\" id=\"" + cid + "\">\n")
        if c.is_folded:
            var fold_hint = (
                c.title if c.title.byte_length() > 0 else String("Hidden code cell")
            )
            parts.append(
                "      <details class=\"nb-fold\"><summary class=\"nb-cell-header\">"
                + "<span class=\"nb-prompt nb-in\">"
                + in_badge
                + "</span><span class=\"nb-cell-title\">"
                + html_escape(fold_hint)
                + "</span></summary><div class=\"nb-source\">"
                + code_html
                + "</div></details>\n"
            )
        else:
            parts.append(
                "      <div class=\"nb-cell-header\"><span class=\"nb-prompt nb-in\">"
                + in_badge
                + "</span>"
                + title_html
                + "</div>\n      <div class=\"nb-source\">"
                + code_html
                + "</div>\n"
            )

        var valid_uris = List[String]()
        for m_uri in c.media_data_uris:
            var norm_u = _normalize_media_data_uri(m_uri)
            if norm_u.byte_length() > 0:
                valid_uris.append(norm_u)

        var has_output = (
            c.output_text.byte_length() > 0 or len(valid_uris) > 0 or c.is_error
        )
        if has_output:
            var out_cls = "nb-output nb-output-error" if c.is_error else "nb-output"
            parts.append("      <div class=\"" + out_cls + "\">\n")
            parts.append(
                "        <div class=\"nb-out-header\"><span class=\"nb-prompt nb-out\">"
                + out_badge
                + "</span></div>\n"
            )
            if c.output_text.byte_length() > 0 or c.is_error:
                parts.append(
                    "        " + _render_output_text_html(c.output_text, c.is_error) + "\n"
                )
            for v_uri in valid_uris:
                parts.append(
                    "        <div class=\"nb-media\"><img class=\"nb-plot\" src=\""
                    + html_escape(v_uri)
                    + "\" alt=\"Notebook plot output\"></div>\n"
                )
            parts.append("      </div>\n")

        parts.append("    </section>\n")

    parts.append("  </main>\n</body>\n</html>\n")
    return "".join(parts)


def export_notebook_html(
    title: String, cells: List[HtmlCellView], is_mojo: Bool = True
) -> String:
    """Alias for `render_notebook_cells_html`."""
    return render_notebook_cells_html(title, cells, is_mojo)


def _parse_pct_header(line: String) -> Tuple[Bool, String, String]:
    var s = String(line.lstrip())
    if not s.startswith("#"):
        return (False, "", "")
    var after_hash = String(s[byte=1:].lstrip())
    if not after_hash.startswith("%%"):
        return (False, "", "")
    var rest = String(after_hash[byte=2:].strip())
    var low = lower_str(rest)
    if low.startswith("[markdown]") or low.startswith("[md]"):
        var close_b = rest.find("]")
        var t = String(rest[byte=close_b + 1 :].strip()) if close_b >= 0 else String("")
        return (True, "markdown", t)
    if low.startswith("[raw]"):
        var close_b = rest.find("]")
        var t = String(rest[byte=close_b + 1 :].strip()) if close_b >= 0 else String("")
        return (True, "raw", t)
    return (True, "code", rest)


def _uncomment_md_line(line: String) -> String:
    var s = String(line.lstrip())
    if s == "#":
        return ""
    if s.startswith("# "):
        return String(s[byte=2:])
    if s.startswith("#"):
        return String(s[byte=1:])
    return line


def _extract_ipynb_gif_uris_by_code_ord(cleaned_json: String) -> List[List[String]]:
    """Scan `.ipynb` JSON `outputs[].data["image/gif"]` per code cell ordinal."""
    var per_code = List[List[String]]()
    var doc = json_parse(cleaned_json)
    if not doc.ok or doc.kind(0) != J_OBJ:
        return per_code^
    var cells_n = doc.get(0, "cells")
    if doc.kind(cells_n) != J_ARR:
        var ws_n = doc.get(0, "worksheets")
        if doc.kind(ws_n) == J_ARR and doc.size(ws_n) > 0:
            cells_n = doc.get(doc.at(ws_n, 0), "cells")
    if doc.kind(cells_n) != J_ARR:
        return per_code^

    for c in doc.children(cells_n):
        var ctype = doc.str(doc.get(c, "cell_type"), "code")
        if ctype != "code":
            continue
        var gifs = List[String]()
        var outs_n = doc.get(c, "outputs")
        if doc.kind(outs_n) == J_ARR:
            for o in doc.children(outs_n):
                var data_n = doc.get(o, "data")
                if doc.kind(data_n) == J_OBJ:
                    var gif_n = doc.get(data_n, "image/gif")
                    var gif_raw = String("")
                    if doc.kind(gif_n) == J_STR:
                        gif_raw = doc.str(gif_n, "")
                    elif doc.kind(gif_n) == J_ARR:
                        var gparts = List[String]()
                        for gc in doc.children(gif_n):
                            gparts.append(doc.str(gc, ""))
                        gif_raw = "".join(gparts)
                    var gif_clean = gif_raw.replace("\n", "").replace("\r", "").replace(" ", "")
                    if gif_clean.byte_length() > 0:
                        gifs.append("data:image/gif;base64," + gif_clean)
        per_code.append(gifs^)
    return per_code^


def parse_ipynb_bytes(ipynb_bytes: List[UInt8], default_mojo: Bool = False) -> IpynbDocument:
    """Parse `.ipynb` UTF-8 bytes into an `IpynbDocument` (erroring on empty or malformed JSON)."""
    var cleaned = strip_utf8_bom(bytes_to_str(ipynb_bytes))
    if String(cleaned.strip()).byte_length() == 0:
        return IpynbDocument(False, "Empty .ipynb JSON input", "", default_mojo, 4, 5)
    return ipynb_to_percent_text(cleaned, default_mojo)


def percent_text_to_html_cells(
    text: String,
    outputs: List[IpynbCellOutput] = List[IpynbCellOutput](),
    folded_headers: List[Int] = List[Int](),
    extra_gif_by_ord: List[List[String]] = List[List[String]](),
) -> List[HtmlCellView]:
    """Convert `# %%` / `# %% [markdown]` text + cell outputs into `List[HtmlCellView]`."""
    var norm = text.replace("\r\n", "\n")
    if norm.endswith("\n"):
        var trimmed = String(norm[byte=0 : norm.byte_length() - 1])
        norm = trimmed

    var raw_types = List[String]()
    var raw_titles = List[String]()
    var raw_hdr_rows = List[Int]()
    var raw_bodies = List[String]()

    var cur_type = String("code")
    var cur_title = String("")
    var cur_hdr_row = -1
    var cur_lines = List[String]()
    var seen_hdr = False

    if norm.byte_length() > 0:
        var row_idx = 0
        for ln_s in norm.split("\n"):
            var ln = String(ln_s)
            var hdr = _parse_pct_header(ln)
            if hdr[0]:
                if seen_hdr:
                    raw_types.append(cur_type)
                    raw_titles.append(cur_title)
                    raw_hdr_rows.append(cur_hdr_row)
                    raw_bodies.append("\n".join(cur_lines))
                else:
                    var has_pre = False
                    for pl in cur_lines:
                        if String(pl.strip()).byte_length() > 0:
                            has_pre = True
                            break
                    if has_pre:
                        raw_types.append("code")
                        raw_titles.append("")
                        raw_hdr_rows.append(-1)
                        raw_bodies.append("\n".join(cur_lines))
                cur_lines = List[String]()
                cur_type = hdr[1]
                cur_title = hdr[2]
                cur_hdr_row = row_idx
                seen_hdr = True
            else:
                if seen_hdr and (cur_type == "markdown" or cur_type == "raw"):
                    cur_lines.append(_uncomment_md_line(ln))
                else:
                    cur_lines.append(ln)
            row_idx += 1

    if seen_hdr or len(cur_lines) > 0:
        raw_types.append(cur_type)
        raw_titles.append(cur_title)
        raw_hdr_rows.append(cur_hdr_row)
        raw_bodies.append("\n".join(cur_lines))

    var out = List[HtmlCellView]()
    var code_ord = 0
    for idx in range(len(raw_types)):
        var ctype = raw_types[idx]
        var is_md = ctype == "markdown"
        var hrow = raw_hdr_rows[idx]
        var folded = hrow in folded_headers
        var exec_cnt = 0
        var out_txt = String("")
        var is_err = False
        var media = List[String]()

        if ctype == "code":
            for oi in range(len(outputs)):
                if outputs[oi].code_ordinal == code_ord:
                    exec_cnt = outputs[oi].execution_count
                    out_txt = outputs[oi].text
                    is_err = outputs[oi].is_error
                    for b64 in outputs[oi].png_b64:
                        var uri = _normalize_media_data_uri(b64)
                        if uri.byte_length() > 0:
                            media.append(uri)
                    break
            if code_ord < len(extra_gif_by_ord):
                for g_uri in extra_gif_by_ord[code_ord]:
                    media.append(g_uri)
            code_ord += 1

        out.append(
            HtmlCellView(
                idx,
                raw_titles[idx],
                is_md,
                folded,
                exec_cnt,
                raw_bodies[idx],
                out_txt,
                is_err,
                media^,
            )
        )
    return out^


def export_ipynb_bytes_to_html(
    title: String, ipynb_bytes: List[UInt8]
) -> Tuple[Bool, String, String]:
    """Convert `.ipynb` JSON bytes into a standalone HTML5 report `(ok, html_doc, err)`."""
    var nb_doc = parse_ipynb_bytes(ipynb_bytes)
    if not nb_doc.ok:
        return (False, "", nb_doc.error)
    var cleaned = strip_utf8_bom(bytes_to_str(ipynb_bytes))
    var extra_gifs = _extract_ipynb_gif_uris_by_code_ord(cleaned)
    var cells = percent_text_to_html_cells(
        nb_doc.text, nb_doc.outputs, nb_doc.folded_headers, extra_gifs
    )
    var doc_title = title if title.byte_length() > 0 else String("Notebook")
    var html = render_notebook_cells_html(doc_title, cells, nb_doc.is_mojo)
    return (True, html, "")


def export_ipynb_file_to_html(in_path: String, out_html_path: String) -> Tuple[Bool, String]:
    """Read `.ipynb` or `# %%` `.mojo`/`.py` source from `in_path` and write HTML to `out_html_path`."""
    if in_path.byte_length() == 0 or not path_exists(in_path):
        return (False, "Input file not found: " + in_path)
    if out_html_path.byte_length() == 0:
        return (False, "Output HTML path is empty")

    var raw_bytes = read_file(in_path)
    var doc_title = basename(in_path)

    if is_ipynb_path(in_path):
        var res = export_ipynb_bytes_to_html(doc_title, raw_bytes)
        if not res[0]:
            return (False, res[2])
        if not write_file(out_html_path, str_bytes(res[1])):
            return (False, "Failed to write HTML output: " + out_html_path)
        return (True, "")

    var is_mj = lang_for_path(in_path) == HL_MOJO
    var cells = percent_text_to_html_cells(bytes_to_str(raw_bytes))
    var html = render_notebook_cells_html(doc_title, cells, is_mj)
    if not write_file(out_html_path, str_bytes(html)):
        return (False, "Failed to write HTML output: " + out_html_path)
    return (True, "")


# ---------------------------------------------------------------------------
# Part 2: Zero-Server Collaborative Live Share over Non-Blocking AF_UNIX
# ---------------------------------------------------------------------------


@fieldwise_init
struct LiveShareEvent(Copyable, Movable):
    var kind: String
    var peer_name: String
    var path: String
    var row: Int
    var col: Int
    var end_row: Int
    var text: String


@fieldwise_init
struct PeerCursor(Copyable, Movable):
    var peer_name: String
    var path: String
    var row: Int
    var col: Int


def encode_live_share_event(ev: LiveShareEvent) -> String:
    """Serialize `ev` as a single newline-terminated JSON wire frame."""
    var w = JsonWriter()
    w.begin_obj()
    w.kv_str("kind", ev.kind)
    w.kv_str("peer_name", ev.peer_name)
    w.kv_str("path", ev.path)
    w.kv_int("row", ev.row)
    w.kv_int("col", ev.col)
    w.kv_int("end_row", ev.end_row)
    w.kv_str("text", ev.text)
    w.end_obj()
    return w.text() + "\n"


def decode_live_share_event(line: String) -> Tuple[Bool, LiveShareEvent]:
    """Parse a single JSON line into `(ok, LiveShareEvent)`."""
    var trimmed = String(line.strip())
    if trimmed.byte_length() == 0:
        return (False, LiveShareEvent("", "", "", 0, 0, 0, ""))
    var doc = json_parse(trimmed)
    if not doc.ok or doc.kind(0) != J_OBJ:
        return (False, LiveShareEvent("", "", "", 0, 0, 0, ""))
    var kind = doc.str(doc.get(0, "kind"), "")
    if kind.byte_length() == 0:
        return (False, LiveShareEvent("", "", "", 0, 0, 0, ""))
    return (
        True,
        LiveShareEvent(
            kind,
            doc.str(doc.get(0, "peer_name"), ""),
            doc.str(doc.get(0, "path"), ""),
            doc.int(doc.get(0, "row"), 0),
            doc.int(doc.get(0, "col"), 0),
            doc.int(doc.get(0, "end_row"), 0),
            doc.str(doc.get(0, "text"), ""),
        ),
    )


def _build_sockaddr_un(sock_path: String) -> Tuple[Bool, List[UInt8]]:
    """Build OS-specific `struct sockaddr_un` (Linux 110B vs macOS 106B with `sun_len`)."""
    var pbytes = str_bytes(sock_path)
    if len(pbytes) == 0 or len(pbytes) > SUN_PATH_MAX:
        return (False, List[UInt8]())
    var addr = List[UInt8](length=SOCKADDR_UN_LEN, fill=0)
    comptime if IS_MACOS:
        addr[0] = UInt8(SOCKADDR_UN_LEN)
        addr[1] = UInt8(AF_UNIX)
    else:
        addr[0] = UInt8(AF_UNIX & 0xFF)
        addr[1] = UInt8((AF_UNIX >> 8) & 0xFF)
    for i in range(len(pbytes)):
        addr[2 + i] = pbytes[i]
    return (True, addr^)


def _set_fd_nonblock_cloexec(fd: Int) -> Bool:
    _ = external_call["fcntl", Int32](Int32(fd), Int32(F_SETFD), Int32(FD_CLOEXEC))
    var flags = external_call["fcntl", Int32](Int32(fd), Int32(F_GETFL), Int32(0))
    if Int(flags) < 0:
        return False
    var rc = external_call["fcntl", Int32](Int32(fd), Int32(F_SETFL), flags | Int32(O_NONBLOCK))
    return Int(rc) == 0


def _fd_poll_revents(fd: Int, events_mask: Int, timeout_ms: Int) -> Int:
    var pf = List[Int32](length=2, fill=0)
    pf[0] = Int32(fd)
    pf[1] = Int32(events_mask)
    var rc = Int(external_call["poll", Int32](pf.unsafe_ptr(), UInt64(1), Int32(timeout_ms)))
    if rc <= 0:
        return 0
    return (Int(pf[1]) >> 16) & 0xFFFF


def _send_wire_bytes(fd: Int, data: List[UInt8]) -> Bool:
    """Write full frame `data` to non-blocking `fd`, polling briefly on backpressure."""
    var total = len(data)
    var sent = 0
    var retries = 0
    while sent < total:
        var n = external_call["write", Int](
            Int32(fd), data.unsafe_ptr().unsafe_offset(sent), total - sent
        )
        if n > 0:
            sent += n
            retries = 0
            continue
        if n == 0:
            return False
        if retries < 50:
            var rev = _fd_poll_revents(fd, 4, 5)  # POLLOUT = 4
            if (rev & (8 | 16 | 32)) != 0:        # POLLERR | POLLHUP | POLLNVAL
                return False
            retries += 1
            continue
        return False
    return True


struct LiveShareSession(Copyable, Movable):
    var mode: Int
    var sock_path: String
    var peer_name: String
    var listen_fd: Int
    var client_fds: List[Int]
    var rx_bufs: List[String]
    var peer_cursors: List[PeerCursor]

    def __init__(out self):
        self.mode = LS_OFF
        self.sock_path = ""
        self.peer_name = ""
        self.listen_fd = -1
        self.client_fds = List[Int]()
        self.rx_bufs = List[String]()
        self.peer_cursors = List[PeerCursor]()

    def is_active(self) -> Bool:
        return self.mode != LS_OFF

    def connected_peer_count(self) -> Int:
        return len(self.client_fds)

    def poll_fds(self) -> List[Int]:
        var fds = List[Int]()
        if self.listen_fd >= 0:
            fds.append(self.listen_fd)
        for cfd in self.client_fds:
            if cfd >= 0:
                fds.append(cfd)
        return fds^

    def _upsert_peer_cursor(mut self, peer_name: String, path: String, row: Int, col: Int):
        if peer_name.byte_length() == 0 or peer_name == self.peer_name:
            return
        for i in range(len(self.peer_cursors)):
            if self.peer_cursors[i].peer_name == peer_name:
                self.peer_cursors[i] = PeerCursor(peer_name, path, row, col)
                return
        self.peer_cursors.append(PeerCursor(peer_name, path, row, col))

    def _remove_client_at(mut self, idx: Int):
        if idx < 0 or idx >= len(self.client_fds):
            return
        var fd = self.client_fds[idx]
        if fd >= 0:
            _ = external_call["close", Int32](Int32(fd))
        var next_fds = List[Int]()
        var next_rxs = List[String]()
        for i in range(len(self.client_fds)):
            if i != idx:
                next_fds.append(self.client_fds[i])
                next_rxs.append(self.rx_bufs[i])
        self.client_fds = next_fds^
        self.rx_bufs = next_rxs^

    def start_host(mut self, sock_path: String, host_name: String = "host") -> Bool:
        """Unlink stale `sock_path` and start a non-blocking `AF_UNIX` listening host."""
        self.stop()
        var addr_res = _build_sockaddr_un(sock_path)
        if not addr_res[0]:
            return False
        var addr = addr_res[1].copy()

        ignore_sigpipe()
        var p = String(sock_path)
        _ = external_call["unlink", Int32](p.as_c_string_span())

        var fd = Int(external_call["socket", Int32](Int32(AF_UNIX), Int32(SOCK_STREAM), Int32(0)))
        if fd < 0:
            return False
        if not _set_fd_nonblock_cloexec(fd):
            _ = external_call["close", Int32](Int32(fd))
            return False

        var brc = Int(
            external_call["bind", Int32](Int32(fd), addr.unsafe_ptr(), UInt32(SOCKADDR_UN_LEN))
        )
        if brc != 0:
            _ = external_call["close", Int32](Int32(fd))
            return False

        var lrc = Int(external_call["listen", Int32](Int32(fd), Int32(8)))
        if lrc != 0:
            _ = external_call["close", Int32](Int32(fd))
            _ = external_call["unlink", Int32](p.as_c_string_span())
            return False

        self.mode = LS_HOST
        self.sock_path = sock_path
        self.peer_name = host_name if host_name.byte_length() > 0 else String("host")
        self.listen_fd = fd
        return True

    def connect_client(mut self, sock_path: String, client_name: String = "guest") -> Bool:
        """Connect to a local or SSH-forwarded `AF_UNIX` host socket and send `hello`."""
        self.stop()
        var addr_res = _build_sockaddr_un(sock_path)
        if not addr_res[0]:
            return False
        var addr = addr_res[1].copy()

        ignore_sigpipe()
        var fd = Int(external_call["socket", Int32](Int32(AF_UNIX), Int32(SOCK_STREAM), Int32(0)))
        if fd < 0:
            return False

        var crc = Int(
            external_call["connect", Int32](Int32(fd), addr.unsafe_ptr(), UInt32(SOCKADDR_UN_LEN))
        )
        if crc != 0:
            _ = external_call["close", Int32](Int32(fd))
            return False

        if not _set_fd_nonblock_cloexec(fd):
            _ = external_call["close", Int32](Int32(fd))
            return False

        self.mode = LS_CLIENT
        self.sock_path = sock_path
        self.peer_name = client_name if client_name.byte_length() > 0 else String("guest")
        self.listen_fd = -1
        self.client_fds.append(fd)
        self.rx_bufs.append("")

        self.broadcast(LiveShareEvent("hello", self.peer_name, "", 0, 0, 0, ""))
        return True

    def broadcast(mut self, ev: LiveShareEvent):
        """Send `ev` to all connected clients (when host) or to the host (when client)."""
        if self.mode == LS_OFF or len(self.client_fds) == 0:
            return
        var wire = str_bytes(encode_live_share_event(ev))
        var dead_indices = List[Int]()
        for i in range(len(self.client_fds)):
            if not _send_wire_bytes(self.client_fds[i], wire):
                dead_indices.append(i)
        var k = len(dead_indices) - 1
        while k >= 0:
            self._remove_client_at(dead_indices[k])
            k -= 1
        if self.mode == LS_CLIENT and len(self.client_fds) == 0:
            self.mode = LS_OFF

    def poll_events(mut self) -> List[LiveShareEvent]:
        """Accept pending clients, drain non-blocking frames, relay on host, and update cursors."""
        var events = List[LiveShareEvent]()
        if self.mode == LS_OFF:
            return events^

        # 1. Accept any pending incoming guest connections when hosting
        if self.mode == LS_HOST and self.listen_fd >= 0:
            for _ in range(16):
                var cfd = Int(
                    external_call["accept", Int32](Int32(self.listen_fd), Int(0), Int(0))
                )
                if cfd < 0:
                    break
                if not _set_fd_nonblock_cloexec(cfd):
                    _ = external_call["close", Int32](Int32(cfd))
                    continue
                self.client_fds.append(cfd)
                self.rx_bufs.append("")

        # 2. Read available bytes from each peer socket
        var n_peers = len(self.client_fds)
        if n_peers == 0:
            return events^

        var dead = List[Bool](length=n_peers, fill=False)
        var relay_src = List[Int]()
        var relay_wire = List[List[UInt8]]()
        var chunk = List[UInt8](length=16384, fill=0)

        for idx in range(n_peers):
            var fd = self.client_fds[idx]
            var acc = str_bytes(self.rx_bufs[idx])
            for _ in range(64):
                var rev = _fd_poll_revents(fd, 1, 0)  # POLLIN = 1
                if rev == 0:
                    break
                var r = external_call["read", Int](Int32(fd), chunk.unsafe_ptr(), Int(16384))
                if r > 0:
                    for bi in range(r):
                        acc.append(chunk[bi])
                    continue
                if r == 0 or (rev & (8 | 16 | 32)) != 0:
                    dead[idx] = True
                break

            # Split complete '\n'-delimited frames
            var line_start = 0
            var total_b = len(acc)
            for pos in range(total_b):
                if acc[pos] == 10:
                    var line_bytes = List[UInt8]()
                    for li in range(line_start, pos):
                        if acc[li] != 13:
                            line_bytes.append(acc[li])
                    line_start = pos + 1
                    if len(line_bytes) > 0:
                        var parsed = decode_live_share_event(bytes_to_str(line_bytes))
                        if parsed[0]:
                            var ev = parsed[1].copy()
                            if ev.kind == "cursor":
                                self._upsert_peer_cursor(ev.peer_name, ev.path, ev.row, ev.col)
                            if self.mode == LS_HOST:
                                relay_src.append(idx)
                                relay_wire.append(str_bytes(encode_live_share_event(ev)))
                            events.append(ev^)

            if line_start == 0:
                self.rx_bufs[idx] = bytes_to_str(acc)
            elif line_start >= total_b:
                self.rx_bufs[idx] = ""
            else:
                var rem = List[UInt8]()
                for ri in range(line_start, total_b):
                    rem.append(acc[ri])
                self.rx_bufs[idx] = bytes_to_str(rem)

        # 3. Relay guest events to all other connected guests when hosting
        if self.mode == LS_HOST and len(relay_src) > 0:
            for ri in range(len(relay_src)):
                var sender_idx = relay_src[ri]
                for dst_idx in range(n_peers):
                    if dst_idx == sender_idx or dead[dst_idx]:
                        continue
                    if not _send_wire_bytes(self.client_fds[dst_idx], relay_wire[ri]):
                        dead[dst_idx] = True

        # 4. Prune disconnected peers in reverse order
        var di = n_peers - 1
        while di >= 0:
            if dead[di]:
                self._remove_client_at(di)
            di -= 1

        if self.mode == LS_CLIENT and len(self.client_fds) == 0:
            self.mode = LS_OFF

        return events^

    def stop(mut self):
        """Close all sockets cleanly and unlink `sock_path` when hosting."""
        var was_host = self.mode == LS_HOST
        var saved_path = self.sock_path
        for fd in self.client_fds:
            if fd >= 0:
                _ = external_call["close", Int32](Int32(fd))
        self.client_fds.clear()
        self.rx_bufs.clear()
        if self.listen_fd >= 0:
            _ = external_call["close", Int32](Int32(self.listen_fd))
            self.listen_fd = -1
        if was_host and saved_path.byte_length() > 0:
            var p = String(saved_path)
            _ = external_call["unlink", Int32](p.as_c_string_span())
        self.mode = LS_OFF
        self.sock_path = ""
        self.peer_cursors.clear()
