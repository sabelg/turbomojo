"""The documentation library: the folders `scripts/fetch-docs.sh` downloads, seen as
books with a table of contents, and their pages cleaned up for the reader (front
matter, includes, admonitions and web-only markup turned into plain Markdown)."""
from helpbook import help_pages
from std.collections import List
from json import Json, json_parse
from util import (
    decode, to_str, read_file, bytes_to_str, decode_list, join_path, dirname, basename, path_exists,
    is_dir, list_dir, env_or, slice_str,
)

comptime DK_BOOK = 0        # a book's title line
comptime DK_HEADING = 1     # a chapter heading without a page of its own
comptime DK_PAGE = 2        # a Markdown page
comptime DK_SOURCE = 3      # a source file shown as code


@fieldwise_init
struct DocPage(Copyable, Movable):
    var title: String
    var path: String        # '' for headings
    var depth: Int
    var kind: Int


def default_docs_home() -> String:
    """Where the downloaded documentation lives: $XDG_DATA_HOME/turbomojo/docs, by
    default ~/.local/share/turbomojo/docs."""
    var data = env_or("XDG_DATA_HOME", "")
    if data.byte_length() == 0:
        var home = env_or("HOME", "")
        if home.byte_length() == 0:
            return ""
        data = home + "/.local/share"
    return data + "/turbomojo/docs"


def cut(s: String, a: Int, b: Int) -> String:
    """Bytes a..b of a string as a new one (b = -1: to the end)."""
    var e = s.byte_length() if b < 0 else b
    return String(s[byte=a:e])


def file_text(path: String) -> String:
    return bytes_to_str(read_file(path))


def text_lines(text: String) -> List[String]:
    var out = List[String]()
    for raw in text.split("\n"):
        var l = String(raw)
        if l.endswith("\r"):
            l = cut(l, 0, l.byte_length() - 1)
        out.append(l)
    return out^


def trimmed(s: String) -> String:
    return String(s.strip())


def unquoted(s: String) -> String:
    var t = trimmed(s)
    if t.byte_length() >= 2 and ((t.startswith("\"") and t.endswith("\"")) or (t.startswith("'") and t.endswith("'"))):
        return String(t[byte=1:t.byte_length() - 1])
    return t


def is_source_path(path: String) -> Bool:
    """A program of the documentation (an example, a lesson) rather than a page."""
    return path.endswith(".mojo") or path.endswith(".🔥") or path.endswith(".py")


def practice_path(home: String, path: String) -> String:
    """Where the reader's own copy of a program of the documentation lives: next to the
    download, in practice/, under the same folders ('' for a file outside the download)."""
    if home.byte_length() == 0 or not path.startswith(home + "/"):
        return ""
    return join_path(join_path(dirname(home), "practice"), cut(path, home.byte_length() + 1, -1))


def tree_notes(readme: String) -> List[String]:
    """What a workshop's README says about its files, from the folder tree it draws
    (lines like "├── hello.mojo   # Entry point"): pairs of "folder/file" and note, in
    the order of the tree - which is the order the lessons are taught in."""
    var out = List[String]()
    var folder = String("")
    for l in text_lines(readme):
        var at = l.find("── ")
        if at < 0:
            continue
        var rest = String(cut(l, at + "── ".byte_length(), -1).strip())
        var note = String("")
        var hash = rest.find("#")
        if hash >= 0:
            note = String(cut(rest, hash + 1, -1).strip())
            rest = String(cut(rest, 0, hash).strip())
        if rest.byte_length() == 0 or rest.find(" ") >= 0:
            continue
        if rest.endswith("/"):
            folder = rest
            continue
        out.append(folder + rest)
        out.append(note)
    return out^


def nice_name(file_name: String) -> String:
    """A title made from a file name: "get-started.mdx" -> "Get started"."""
    var name = file_name
    var dot = name.rfind(".")
    if dot > 0:
        name = cut(name, 0, dot)
    var cps = decode(name)
    var out = List[Int]()
    for k in range(len(cps)):
        var c = cps[k]
        if c == 45 or c == 95:
            c = 32
        if k == 0 and c >= 97 and c <= 122:
            c -= 32
        out.append(c)
    return to_str(out)


def front_matter(text: String) -> Tuple[String, Int, String]:
    """Split a page into (title, sidebar position, body). Pages without a "---" header
    give ('', 9999, text)."""
    if not text.startswith("---"):
        return (String(""), 9999, text)
    var lines = text_lines(text)
    var title = String("")
    var pos = 9999
    var end = -1
    for k in range(1, len(lines)):
        var l = lines[k]
        if trimmed(l) == "---":
            end = k
            break
        if l.startswith("title:"):
            title = unquoted(String(l[byte=6:]))
        elif l.startswith("sidebar_label:") and title.byte_length() == 0:
            title = unquoted(String(l[byte=14:]))
        elif l.startswith("sidebar_position:"):
            var n = 0
            var any = False
            for c in trimmed(String(l[byte=17:])).as_bytes():
                var d = Int(c) - 48
                if d < 0 or d > 9:
                    break
                n = n * 10 + d
                any = True
            if any:
                pos = n
    if end < 0:
        return (String(""), 9999, text)
    var body = String("")
    for k in range(end + 1, len(lines)):
        body += lines[k] + "\n"
    return (title, pos, body)


def page_title(path: String) -> String:
    """The title of a page: from its header, else its first heading, else its name."""
    var text = file_text(path)
    var fm = front_matter(text)
    if fm[0].byte_length() > 0:
        return fm[0]
    var in_code = False
    for l in text_lines(fm[2]):
        var t = trimmed(l)
        if t.startswith("```"):
            in_code = not in_code
        elif not in_code and t.startswith("# "):
            return clean_heading(String(t[byte=2:]))
    var name = basename(path)
    if name.startswith("index.") or name.startswith("README."):
        return nice_name(basename(dirname(path)))
    return nice_name(name)


def clean_heading(text: String) -> String:
    """A heading without its "{#anchor}" and without link markup."""
    var t = text
    var brace = t.find("{#")
    if brace >= 0:
        t = cut(t, 0, brace)
    return trimmed(t)


# ------------------------------------------------------------------ includes
def include_text(path: String, anchor: String) -> String:
    """The content of a file for "{{#include path:anchor}}": the whole file, or the
    lines between "ANCHOR: name" and "ANCHOR_END: name" (other anchor lines left out)."""
    if not path_exists(path) or is_dir(path):
        return "(missing: " + basename(path) + ")"
    var lines = text_lines(file_text(path))
    var out = String("")
    var on = anchor.byte_length() == 0
    for l in lines:
        if l.find("ANCHOR_END:") >= 0:
            if anchor.byte_length() > 0 and trimmed(String(l[byte=l.find("ANCHOR_END:") + 11:])) == anchor:
                on = False
            continue
        if l.find("ANCHOR:") >= 0:
            if anchor.byte_length() > 0 and trimmed(String(l[byte=l.find("ANCHOR:") + 7:])) == anchor:
                on = True
            continue
        if on:
            out += l + "\n"
    while out.endswith("\n\n"):
        out = cut(out, 0, out.byte_length() - 1)
    return out


def expand_includes(line: String, dir: String) -> String:
    """Replace every "{{#include ...}}" of a line."""
    var out = line
    var guard = 0
    while guard < 8:
        guard += 1
        var a = out.find("{{#include ")
        if a < 0:
            break
        var b = out.find("}}", a)
        if b < 0:
            break
        var spec = trimmed(String(out[byte=a + 11:b]))
        var anchor = String("")
        var colon = spec.rfind(":")
        if colon > 0:
            anchor = String(spec[byte=colon + 1:])
            spec = cut(spec, 0, colon)
        var text = include_text(join_path(dir, spec), anchor)
        if text.endswith("\n"):
            text = cut(text, 0, text.byte_length() - 1)
        out = cut(out, 0, a) + text + String(out[byte=b + 2:])
    return out


# --------------------------------------------------------------- clean-up
def attr_of(tag: String, name: String) -> String:
    """The value of name="..." in a tag ('' if it has none)."""
    var a = tag.find(name + "=\"")
    if a < 0:
        return ""
    a += name.byte_length() + 2
    var b = tag.find("\"", a)
    if b < 0:
        return ""
    return String(tag[byte=a:b])


def inline_html(line: String) -> String:
    """The few inline HTML tags the sources use, as Markdown; other tags are dropped."""
    var s = line
    var guard = 0
    while guard < 40:
        guard += 1
        var a = s.find("<")
        while a >= 0:
            # a tag starts with a letter or "/" right after "<"
            if a + 1 < s.byte_length():
                var c = Int(s.as_bytes()[a + 1])
                if c == 47 or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 33:
                    break
            a = s.find("<", a + 1)
        if a < 0:
            break
        var b = s.find(">", a)
        if b < 0:
            break
        var tag = String(s[byte=a + 1:b])
        var lower = tag.lower()
        var put = String("")
        if lower.startswith("a ") and attr_of(tag, "href").byte_length() > 0:
            var close = s.find("</a>", b)
            if close > 0:
                var text = String(s[byte=b + 1:close])
                s = cut(s, 0, a) + "[" + text + "](" + attr_of(tag, "href") + ")" + String(s[byte=close + 4:])
                continue
        elif lower == "strong" or lower == "/strong" or lower == "b" or lower == "/b":
            put = "**"
        elif lower == "em" or lower == "/em" or lower == "i" or lower == "/i":
            put = "*"
        elif lower == "code" or lower == "/code":
            put = "`"
        elif lower.startswith("br"):
            put = " "
        elif lower.startswith("summary"):
            put = "**▸ "
        elif lower == "/summary":
            put = "**"
        elif lower.startswith("img"):
            put = image_markdown(attr_of(tag, "alt"), attr_of(tag, "src"))
        s = cut(s, 0, a) + put + String(s[byte=b + 1:])
    return s


def image_markdown(alt: String, src: String) -> String:
    """An HTML picture as a Markdown image, so the reader keeps where it is (and shows
    it as "[image: alt]", or the picture itself where the terminal can); without a
    source, just the words."""
    if src.byte_length() == 0:
        return ("*[image: " + alt + "]*") if alt.byte_length() > 0 else String("*[image]*")
    return "![" + alt.replace("]", ")").replace("[", "(") + "](" + src.replace(" ", "%20").replace(")", "%29") + ")"


def doc_prepare(text: String, path: String) -> String:
    """A documentation page as plain Markdown for the reader: the header's title as
    first heading, includes expanded, admonitions as quotes, web-only markup (imports,
    components, comments) removed or put into words; images are kept as Markdown images."""
    var fm = front_matter(text)
    var dir = dirname(path)
    var out = String("")
    var lines = text_lines(fm[2])
    var has_h1 = False
    var in_code = False
    for l in lines:
        var t = trimmed(l)
        if t.startswith("```"):
            in_code = not in_code
        elif not in_code and t.startswith("# "):
            has_h1 = True
    if fm[0].byte_length() > 0 and not has_h1:
        out += "# " + fm[0] + "\n\n"
    in_code = False
    var in_import = False       # inside "import {" ... "} from '...'"
    var in_comment = False
    var admonition = False
    var svg = 0
    for raw in lines:
        var l = raw
        var t = trimmed(l)
        if l.find("{{#include ") >= 0:
            l = expand_includes(l, dir)
            t = trimmed(l)
        if t.startswith("```") or t.startswith("~~~"):
            if not in_code and admonition:
                out += "\n"             # code inside an admonition is shown as a code block after its text
            in_code = not in_code
            out += l + "\n"
            continue
        if in_code:
            out += l + "\n"      # (code inside an admonition is shown as a code block after it)
            continue
        if in_import:
            if t.find(" from ") >= 0 or t.endswith(";"):
                in_import = False
            continue
        if in_comment:
            if t.find("-->") >= 0 or t.find("*/}") >= 0:
                in_comment = False
            continue
        if t.startswith("<!--") or t.startswith("{/*"):
            if not (t.find("-->") >= 0 or t.find("*/}") >= 0):
                in_comment = True
            continue
        if t.startswith("import ") and (t.find(" from ") >= 0 or t.endswith("{")):
            if t.endswith("{") or (t.find("{") >= 0 and t.find("}") < 0):
                in_import = True
            continue
        if t.startswith("export "):
            continue
        # drawings embedded as SVG cannot be shown
        if t.startswith("<svg"):
            svg += 1
            if t.find("</svg>") >= 0:
                svg -= 1
            if svg == 0 or t.find("</svg>") < 0:
                out += "*[drawing]*\n" if svg == 1 or t.find("</svg>") >= 0 else String("")
            continue
        if svg > 0:
            if t.find("</svg>") >= 0:
                svg -= 1
            continue
        # admonitions: ":::note Title" ... ":::"
        if t.startswith(":::"):
            if admonition and t == ":::":
                admonition = False
                out += "\n"
                continue
            var kind = trimmed(String(t[byte=3:]))
            var title = String("")
            var sp = kind.find(" ")
            if sp > 0:
                title = trimmed(String(kind[byte=sp + 1:]))
                kind = cut(kind, 0, sp)
            if kind.byte_length() > 0:
                var label = String(kind[byte=0:1]).upper() + String(kind[byte=1:])
                out += "\n> **" + label + (": " + title if title.byte_length() > 0 else String("")) + "**\n>\n"
                admonition = True
                continue
        # components: a title where they have one, otherwise just their content
        if t.startswith("<") and t.endswith(">") and t.find("</") != 0:
            var name_end = 1
            var tb = t.as_bytes()
            while name_end < len(tb) and ((Int(tb[name_end]) >= 65 and Int(tb[name_end]) <= 90) or (Int(tb[name_end]) >= 97 and Int(tb[name_end]) <= 122)):
                name_end += 1
            var name = String(t[byte=1:name_end])
            var first = Int(tb[1]) if len(tb) > 1 else 0
            if first >= 65 and first <= 90:
                var title = attr_of(t, "title")
                if title.byte_length() == 0:
                    title = attr_of(t, "label")
                if title.byte_length() > 0:
                    out += "\n### " + title + "\n\n"
                    var summary = attr_of(t, "summary")
                    if summary.byte_length() > 0:
                        out += "*" + summary + "*\n\n"
                continue
            if name == "div" or name == "details" or name == "section" or name == "span" or name == "p" or name == "center":
                if t.find("</") < 0:
                    continue        # an opening tag alone on its line
        if t.startswith("</") and t.endswith(">") and t.find(" ") < 0:
            continue                # a closing tag alone on its line
        if l.find("<") >= 0:
            l = inline_html(l)
        t = trimmed(l)
        if t.startswith("#"):
            var brace = l.find("{#")
            if brace > 0:
                l = trimmed(cut(l, 0, brace))
        if admonition:
            if t.byte_length() == 0:
                if not out.endswith(">\n"):
                    out += ">\n"
            else:
                out += "> " + l + "\n"
        else:
            out += l + "\n"
    return tidy_blank_lines(out)


def tidy_blank_lines(text: String) -> String:
    """No blank lines at the top, never more than one in a row (code blocks are left
    alone), and no empty quote line at the end of a quote."""
    var out = String("")
    var in_code = False
    var blank_run = 0
    var started = False
    var lines = text_lines(text)
    if len(lines) > 0 and lines[len(lines) - 1].byte_length() == 0:
        _ = lines.pop()
    for k in range(len(lines)):
        var l = lines[k]
        var t = trimmed(l)
        if t.startswith("```") or t.startswith("~~~"):
            in_code = not in_code
            out += l + "\n"
            blank_run = 0
            started = True
            continue
        if in_code:
            out += l + "\n"
            blank_run = 0
            started = True
            continue
        if t.byte_length() == 0:
            blank_run += 1
            if started and blank_run == 1:
                out += "\n"
            continue
        if t == ">" and (k + 1 >= len(lines) or not trimmed(lines[k + 1]).startswith(">")):
            continue                    # a quote does not end on an empty line
        blank_run = 0
        started = True
        out += l + "\n"
    while out.endswith("\n\n"):
        out = cut(out, 0, out.byte_length() - 1)
    return out


# ------------------------------------------------------------ HTML pages
def decode_entities(text: String) -> String:
    """&lt; &gt; &amp; &quot; &#39; &nbsp; and numeric references as their characters."""
    if text.find("&") < 0:
        return text
    var cps = decode(text)
    var out = List[Int]()
    var i = 0
    var n = len(cps)
    while i < n:
        if cps[i] == 38:
            var j = i + 1
            while j < n and j - i < 10 and cps[j] != 59:
                j += 1
            if j < n and cps[j] == 59:
                var name = slice_str(cps, i + 1, j)
                var value = -1
                if name == "lt":
                    value = 60
                elif name == "gt":
                    value = 62
                elif name == "amp":
                    value = 38
                elif name == "quot":
                    value = 34
                elif name == "apos":
                    value = 39
                elif name == "nbsp":
                    value = 32
                elif name.startswith("#x") or name.startswith("#X"):
                    value = 0
                    for c in cut(name, 2, -1).lower().as_bytes():
                        var d = Int(c)
                        if d >= 48 and d <= 57:
                            value = value * 16 + d - 48
                        elif d >= 97 and d <= 102:
                            value = value * 16 + d - 87
                        else:
                            value = -1
                            break
                elif name.startswith("#"):
                    value = 0
                    for c in cut(name, 1, -1).as_bytes():
                        var d = Int(c) - 48
                        if d < 0 or d > 9:
                            value = -1
                            break
                        value = value * 10 + d
                if value > 0:
                    out.append(value)
                    i = j + 1
                    continue
        out.append(cps[i])
        i += 1
    return to_str(out)


def html_markdown(html: String) -> String:
    """The text of an HTML page (what is inside <main>, else the whole of it) as
    Markdown: headings, paragraphs, lists, quotes, code blocks with their language,
    links, bold, italic and inline code. Images become Markdown images; scripts, styles
    and drawings are left out. Made for the pages mdBook writes."""
    var src = html
    var a = src.find("<main")
    if a >= 0:
        var a2 = src.find(">", a)
        var b = src.find("</main>", a)
        if a2 > 0 and b > a2:
            src = cut(src, a2 + 1, b)
    var out = String("")        # finished blocks
    var cur = String("")        # the block being collected
    var lists = List[Int]()     # open lists: 0 bullets, else the next number
    var quote = 0
    var item_open = False       # the block in `cur` is the first of a list item
    var i = 0
    var n = src.byte_length()
    while i < n:
        var lt = src.find("<", i)
        if lt < 0:
            lt = n
        if lt > i:
            # text: line breaks and runs of blanks are one blank
            var t = decode_entities(String(src[byte=i:lt]))
            var squeezed = String("")
            var blank = False
            for c in decode(t):
                if c == 32 or c == 10 or c == 13 or c == 9:
                    blank = True
                else:
                    if blank and (squeezed.byte_length() > 0 or cur.byte_length() > 0):
                        squeezed += " "
                    blank = False
                    squeezed += to_str([c])
            if blank and squeezed.byte_length() > 0:
                squeezed += " "
            elif blank and cur.byte_length() > 0 and not cur.endswith(" "):
                squeezed = " "
            cur += squeezed
            i = lt
            continue
        if lt >= n:
            break
        if src.find("<!--", lt) == lt:
            var e = src.find("-->", lt)
            i = n if e < 0 else e + 3
            continue
        var gt = src.find(">", lt)
        if gt < 0:
            break
        var tag = String(src[byte=lt + 1:gt])
        i = gt + 1
        var closing = tag.startswith("/")
        var name = String("")
        for c in (cut(tag, 1, -1) if closing else tag).lower().as_bytes():
            var d = Int(c)
            if (d >= 97 and d <= 122) or (d >= 48 and d <= 57):
                name += to_str([d])
            else:
                break
        # ---- things that are skipped whole
        if not closing and (name == "script" or name == "style" or name == "svg" or name == "nav"):
            var e = src.find("</" + name, i)
            var e2 = src.find(">", e) if e >= 0 else -1
            if name == "svg":
                cur += "*[drawing]*"
            i = n if e2 < 0 else e2 + 1
            continue
        # ---- code blocks: everything up to </pre> as it is
        if not closing and name == "pre":
            var e = src.find("</pre>", i)
            if e < 0:
                e = n
            var body = String(src[byte=i:e])
            var lang = String("")
            if body.startswith("<code"):
                var cgt = body.find(">")
                var ctag = String(body[byte=0:cgt])
                var lp = ctag.find("language-")
                if lp >= 0:
                    for c in cut(ctag, lp + 9, -1).as_bytes():
                        var d = Int(c)
                        if (d >= 97 and d <= 122) or (d >= 65 and d <= 90) or (d >= 48 and d <= 57):
                            lang += to_str([d])
                        else:
                            break
                body = cut(body, cgt + 1, -1)
            # highlighting spans inside the code are dropped
            var code = String("")
            var k = 0
            while k < body.byte_length():
                var l2 = body.find("<", k)
                if l2 < 0:
                    code += String(body[byte=k:])
                    break
                code += String(body[byte=k:l2])
                var g2 = body.find(">", l2)
                if g2 < 0:
                    break
                k = g2 + 1
            code = decode_entities(code)
            while code.endswith("\n"):
                code = cut(code, 0, code.byte_length() - 1)
            out += html_block(cur, lists, quote, item_open)
            cur = ""
            item_open = False
            out += "```" + lang + "\n" + code + "\n```\n\n"
            i = min(n, e + 6)
            continue
        # ---- inline
        if name == "code":
            cur += "`"
            continue
        if name == "strong" or name == "b":
            cur += "**"
            continue
        if name == "em" or name == "i":
            cur += "*"
            continue
        if name == "br":
            cur += " "
            continue
        if name == "a":
            if closing:
                if cur.find("\x02") >= 0:
                    # "\x02" marks where the link text began; the target follows "\x03"
                    var m = cur.rfind("\x02")
                    var t3 = cur.find("\x03", m)
                    if t3 > m:
                        var target = String(cur[byte=m + 1:t3])
                        var text = String(cur[byte=t3 + 1:])
                        cur = String(cur[byte=0:m]) + (("[" + text + "](" + target + ")") if target.byte_length() > 0 else text)
            else:
                var href = attr_of(tag, "href")
                if tag.find("class=\"header\"") >= 0:
                    href = ""           # the anchor mdBook puts around a heading
                cur += "\x02" + href + "\x03"
            continue
        if name == "img":
            if tag.find("dark") < 0:    # pictures come twice, for the light and the dark theme
                cur += image_markdown(attr_of(tag, "alt"), attr_of(tag, "src"))
            continue
        if name == "summary":
            cur += "**▸ " if not closing else "**"
            if closing:
                out += html_block(cur, lists, quote, item_open)
                cur = ""
                item_open = False
            continue
        # ---- blocks
        if name.byte_length() == 2 and name.startswith("h") and Int(name.as_bytes()[1]) >= 49 and Int(name.as_bytes()[1]) <= 54:
            if closing:
                var marks = String("")
                for _ in range(Int(name.as_bytes()[1]) - 48):
                    marks += "#"
                out += marks + " " + trimmed(cur) + "\n\n"
                cur = ""
            else:
                out += html_block(cur, lists, quote, item_open)
                cur = ""
                item_open = False
            continue
        if name == "ul" or name == "ol":
            out += html_block(cur, lists, quote, item_open)
            cur = ""
            item_open = False
            if closing:
                if len(lists) > 0:
                    _ = lists.pop()
                if len(lists) == 0 and not out.endswith("\n\n"):
                    out += "\n"
            else:
                lists.append(0 if name == "ul" else 1)
            continue
        if name == "li":
            out += html_block(cur, lists, quote, item_open)
            cur = ""
            item_open = not closing
            continue
        if name == "blockquote":
            out += html_block(cur, lists, quote, item_open)
            cur = ""
            item_open = False
            quote += -1 if closing else 1
            quote = max(0, quote)
            continue
        if name == "p" or name == "div" or name == "section" or name == "details" or name == "tr" or name == "table" or name == "hr":
            out += html_block(cur, lists, quote, item_open)
            cur = ""
            item_open = False
            if name == "hr":
                out += "---\n\n"
            continue
        # anything else: the tag is dropped, what it holds stays
    out += html_block(cur, lists, quote, item_open)
    return tidy_blank_lines(out)


def html_block(text: String, mut lists: List[Int], quote: Int, item: Bool) -> String:
    """One finished paragraph as Markdown lines: inside a list as an item (numbered if
    the list is), inside a quote with its bar."""
    var t = trimmed(text)
    # a link that was opened and never closed: keep its text
    var guard = 0
    while t.find("\x02") >= 0 and guard < 50:
        guard += 1
        var m = t.find("\x02")
        var e = t.find("\x03", m)
        if e < 0:
            e = m
        t = String(t[byte=0:m]) + String(t[byte=e + 1:])
    if t.byte_length() == 0:
        return ""
    var prefix = String("")
    for _ in range(quote):
        prefix += "> "
    if len(lists) > 0:
        var indent = String("")
        for _ in range(len(lists) - 1):
            indent += "  "
        var last = len(lists) - 1
        if item:
            if lists[last] == 0:
                return prefix + indent + "- " + t + "\n"
            var num = lists[last]
            lists[last] = num + 1
            return prefix + indent + String(num) + ". " + t + "\n"
        return prefix + indent + "  " + t + "\n"
    return prefix + t + "\n\n"


def source_markdown(path: String) -> String:
    """A source file as a page: its name and its text as a code block."""
    var name = basename(path)
    var lang = "mojo" if (name.endswith(".mojo") or name.endswith(".🔥")) else ("python" if name.endswith(".py") else "text")
    return "# " + name + "\n\n```" + lang + "\n" + file_text(path) + "\n```\n"


# ------------------------------------------------------------- the library
struct DocLibrary(Copyable, Movable):
    var home: String
    var pages: List[DocPage]    # every book, one after the other; a book starts with its DK_BOOK line
    var help_dir: String        # TurboMojo's own help pages ('' for none): the first book
    var help_count: Int         # how many of `pages` are that book

    def __init__(out self):
        self.home = ""
        self.pages = List[DocPage]()
        self.help_dir = ""
        self.help_count = 0

    def book(mut self, title: String):
        self.pages.append(DocPage(title, "", 0, DK_BOOK))

    def last_is_empty_book(self) -> Bool:
        return len(self.pages) > 0 and self.pages[len(self.pages) - 1].kind == DK_BOOK

    def drop_empty_book(mut self):
        if self.last_is_empty_book():
            _ = self.pages.pop()

    def add_page(mut self, path: String, depth: Int, title: String = ""):
        var kind = DK_PAGE if (path.endswith(".md") or path.endswith(".mdx") or path.endswith(".html")) else DK_SOURCE
        var t = title
        if t.byte_length() == 0:
            t = page_title(path) if kind == DK_PAGE else basename(path)
        self.pages.append(DocPage(t, path, depth, kind))

    def find_path(self, path: String) -> Int:
        if path.byte_length() == 0:
            return -1
        for k in range(len(self.pages)):
            if self.pages[k].path == path:
                return k
        return -1

    def book_of(self, k: Int) -> String:
        """The title of the book page k is in."""
        var j = min(k, len(self.pages) - 1)
        while j >= 0:
            if self.pages[j].kind == DK_BOOK:
                return self.pages[j].title
            j -= 1
        return ""

    def next_page(self, k: Int, step: Int) -> Int:
        """The next (step 1) or previous (step -1) entry that has a page (-1 if none)."""
        var j = k + step
        while j >= 0 and j < len(self.pages):
            if self.pages[j].kind >= DK_PAGE:
                return j
            j += step
        return -1

    # --------------------------------------------------- docusaurus sidebars
    def resolve_id(self, site: String, id: String) -> String:
        """The file of a sidebar id such as "docs/manual/basics" ('' if it is not here)."""
        var rel = id
        if rel.startswith("docs/"):
            rel = cut(rel, 5, -1)
        for cand in [rel + ".mdx", rel + ".md", rel + "/index.mdx", rel + "/index.md"]:
            var p = join_path(site, String(cand))
            if path_exists(p) and not is_dir(p):
                return p
        return ""

    def add_folder(mut self, dir: String, depth: Int, sources: Bool):
        """Every page of a folder (and its folders), ordered by the position their
        headers give, then by name. With `sources`, source files are listed too."""
        var files = List[String]()
        var order = List[Int]()
        var dirs = List[String]()
        for n in list_dir(dir):
            if n == "../" or n.startswith(".") or n.startswith("_"):
                continue
            if n.endswith("/"):
                var d = String(n[byte=0:n.byte_length() - 1])
                if d != "images" and d != "image" and d != "static" and d != "gifs" and d != "fonts" and d != "node_modules" and d != "scripts":
                    dirs.append(d)
            elif n.endswith(".md") or n.endswith(".mdx") or (sources and (n.endswith(".mojo") or n.endswith(".🔥") or n.endswith(".py"))):
                var p = join_path(dir, n)
                var pos = 9999
                if n.endswith(".md") or n.endswith(".mdx"):
                    pos = front_matter(file_text(p))[1]
                    if n.startswith("index.") or n.startswith("README.") or n.startswith("readme."):
                        pos = -1
                # insertion sort by (position, name order as listed)
                var at = len(files)
                while at > 0 and order[at - 1] > pos:
                    at -= 1
                files.insert(at, p)
                order.insert(at, pos)
        for p in files:
            self.add_page(p, depth)
        for d in dirs:
            var before = len(self.pages)
            self.pages.append(DocPage(nice_name(d), "", depth, DK_HEADING))
            self.add_folder(join_path(dir, d), depth + 1, sources)
            if len(self.pages) == before + 1:
                _ = self.pages.pop()        # nothing in it

    def add_workshop(mut self, title: String, dir: String):
        """A workshop as a course: what it is about, then every session with its agenda
        and its lessons - the programs, in the order they are taught, each with the
        note the workshop gives it."""
        if not is_dir(dir):
            return
        self.book(title)
        var notes = List[String]()
        var readme = join_path(dir, "README.md")
        if path_exists(readme):
            notes = tree_notes(file_text(readme))
            self.add_page(readme, 1, "About this workshop")
        for n in list_dir(dir):
            if not n.endswith("/") or n == "../" or n.startswith(".") or n.startswith("_"):
                continue
            var d = String(n[byte=0:n.byte_length() - 1])
            var folder = join_path(dir, d)
            var agenda = join_path(folder, "agenda.md")
            var before = len(self.pages)
            if path_exists(agenda):
                self.pages.append(DocPage(page_title(agenda), "", 1, DK_HEADING))
                self.add_page(agenda, 2, "Agenda")
            else:
                self.pages.append(DocPage(nice_name(d), "", 1, DK_HEADING))
            var files = List[String]()
            var order = List[Int]()
            var titles = List[String]()
            for f in list_dir(folder):
                if f.endswith("/") or f.startswith(".") or f == "agenda.md":
                    continue
                if not (is_source_path(f) or f.endswith(".md")):
                    continue
                var pos = 9999
                var t = String("")
                var key = d + "/" + f
                var k = 0
                while k + 1 < len(notes):
                    if notes[k] == key:
                        pos = k
                        if notes[k + 1].byte_length() > 0:
                            t = f + " - " + notes[k + 1]
                        break
                    k += 2
                var at = len(files)
                while at > 0 and order[at - 1] > pos:
                    at -= 1
                files.insert(at, join_path(folder, f))
                order.insert(at, pos)
                titles.insert(at, t)
            for k in range(len(files)):
                self.add_page(files[k], 2, titles[k])
            if len(self.pages) == before + 1:
                _ = self.pages.pop()
        self.drop_empty_book()

    def add_sidebar_items(mut self, doc: Json, items: Int, site: String, depth: Int):
        for it in doc.children(items):
            if doc.kind(it) == 3:
                var p = self.resolve_id(site, doc.str(it))
                if p.byte_length() > 0:
                    self.add_page(p, depth)
                continue
            var ty = doc.str(doc.get(it, "type"))
            if ty == "category":
                var before = len(self.pages)
                self.pages.append(DocPage(doc.str(doc.get(it, "label")), "", depth, DK_HEADING))
                var link = doc.path(it, "link/id")
                if link >= 0:
                    var lp = self.resolve_id(site, doc.str(link))
                    if lp.byte_length() > 0:
                        self.add_page(lp, depth + 1)
                self.add_sidebar_items(doc, doc.get(it, "items"), site, depth + 1)
                if len(self.pages) == before + 1:
                    _ = self.pages.pop()
            elif ty == "doc":
                var p = self.resolve_id(site, doc.str(doc.get(it, "id")))
                if p.byte_length() > 0:
                    self.add_page(p, depth, doc.str(doc.get(it, "label")))
            elif ty == "autogenerated":
                var d = doc.str(doc.get(it, "dirName"))
                if d.startswith("docs/"):
                    d = cut(d, 5, -1)
                if is_dir(join_path(site, d)):
                    self.add_folder(join_path(site, d), depth, False)

    def add_sidebar(mut self, title: String, site: String, sidebars: String, key: String):
        """A book from one sidebar of a docusaurus `sidebars.json`."""
        if not path_exists(sidebars):
            return
        try:
            var doc = json_parse(file_text(sidebars))
            var items = doc.get(0, key)
            if items < 0:
                return
            self.book(title)
            self.add_sidebar_items(doc, items, site, 1)
            self.drop_empty_book()
        except e:
            self.drop_empty_book()

    # ----------------------------------------------------------- mdBook
    def add_summary(mut self, title: String, summary: String):
        """A book from an mdBook SUMMARY.md: "## Part" lines and nested link lists."""
        if not path_exists(summary):
            return
        self.book(title)
        var dir = dirname(summary)
        for l in text_lines(file_text(summary)):
            var t = trimmed(l)
            if t.startswith("## ") or (t.startswith("# ") and t != "# Summary"):
                self.pages.append(DocPage(trimmed(String(t[byte=t.find(" ") + 1:])), "", 1, DK_HEADING))
                continue
            var a = t.find("[")
            var b = t.find("](")
            var c = t.rfind(")")
            if a < 0 or b < a or c < b:
                continue
            var indent = 0
            for ch in l.as_bytes():
                if Int(ch) == 32:
                    indent += 1
                elif Int(ch) == 9:
                    indent += 2
                else:
                    break
            var target = String(t[byte=b + 2:c])
            if target.startswith("./"):
                target = cut(target, 2, -1)
            var p = join_path(dir, target)
            if path_exists(p) and not is_dir(p):
                self.add_page(p, 2 + indent // 2, String(t[byte=a + 1:b]))
        self.drop_empty_book()

    # ------------------------------------------------- a saved mdBook site
    def add_site(mut self, title: String, dir: String):
        """A book that was downloaded as web pages: its contents page (`toc.html`)
        names the chapters in order; "2.1." in front of a title is one level in."""
        var toc = dir + "/toc.html"
        if not path_exists(toc):
            return
        self.book(title)
        var text = file_text(toc)
        var i = 0
        while True:
            var a = text.find("<a href=\"", i)
            if a < 0:
                break
            var q = text.find("\"", a + 9)
            var gt = text.find(">", a)
            var end = text.find("</a>", a)
            if q < 0 or gt < 0 or end < 0:
                break
            i = end + 4
            var href = String(text[byte=a + 9:q])
            var hash = href.find("#")
            if hash >= 0:
                href = cut(href, 0, hash)
            var inner = String(text[byte=gt + 1:end])
            # the number mdBook puts in front says how deep the chapter is
            var depth = 1
            var num = inner.find("<strong")
            if num >= 0:
                var ne = inner.find("</strong>", num)
                if ne > num:
                    var number = String(inner[byte=inner.find(">", num) + 1:ne])
                    depth = max(1, number.count("."))
                    inner = String(inner[byte=0:num]) + String(inner[byte=ne + 9:])
            var label = trimmed(decode_entities(inline_html(inner)))
            var p = join_path(dir, href)
            if href.endswith(".html") and href.find("/") < 0 and href != "cover.html" and path_exists(p) and self.find_path(p) < 0:
                self.add_page(p, depth, label)
        self.drop_empty_book()

    # --------------------------------------------------------- everything
    def load(mut self, home: String):
        """Read what is in the documentation folder. Parts that were not downloaded are
        simply missing."""
        self.home = home
        self.pages.clear()
        self.help_count = 0
        if self.help_dir.byte_length() > 0 and path_exists(self.help_dir + "/guide.md"):
            self.book("TurboMojo")
            var hp = help_pages()
            var k = 0
            while k + 1 < len(hp):
                if path_exists(self.help_dir + "/" + hp[k]):
                    self.add_page(self.help_dir + "/" + hp[k], 1, hp[k + 1])
                k += 2
            self.help_count = len(self.pages)
        var mojo_site = home + "/modular/Mojo/docs/site"
        var mojo_bars = mojo_site + "/docs_root/sidebars.json"
        self.add_sidebar("Mojo Manual", mojo_site, mojo_bars, "manualSidebar")
        self.add_sidebar("Mojo Reference", mojo_site, mojo_bars, "referenceSidebar")
        self.add_sidebar("About Mojo", mojo_site, mojo_bars, "projectSidebar")
        if path_exists(mojo_site + "/nightly-changelog.md") and len(self.pages) > 0:
            self.add_page(mojo_site + "/nightly-changelog.md", 1, "Changelog")
        # the standard library reference, made from the sources (see stdref_build)
        var index = home + "/stdref/index.txt"
        if path_exists(index):
            self.book("Standard Library")
            for l in text_lines(file_text(index)):
                var parts = l.split("\t")
                if len(parts) != 3:
                    continue
                var depth = 1
                try:
                    depth = atol(String(parts[0]))
                except:
                    continue
                var rel = String(parts[2])
                if rel.byte_length() == 0:
                    self.pages.append(DocPage(String(parts[1]), "", depth, DK_HEADING))
                else:
                    self.pages.append(DocPage(String(parts[1]), home + "/stdref/" + rel, depth, DK_PAGE))
            self.drop_empty_book()
        var examples = home + "/modular/Mojo/examples"
        if is_dir(examples):
            self.book("Mojo Examples")
            self.add_folder(examples, 1, True)
            self.drop_empty_book()
        self.add_summary("Course: Mojo GPU Puzzles", home + "/mojo-gpu-puzzles/book/src/SUMMARY.md")
        self.add_summary("Course: Build an LLM from Scratch", home + "/max-llm-book/book/src/SUMMARY.md")
        self.add_site("Course: Advent of Mojo", home + "/advent-of-mojo")
        # the developer relations workshops: each one a course of its own
        var extras = home + "/devrel-extras/workshops"
        for n in list_dir(extras):
            if n.endswith("/") and n != "../" and not n.startswith("."):
                var d = String(n[byte=0:n.byte_length() - 1])
                var name = nice_name(d)
                self.add_workshop("Course: " + name, join_path(extras, d))
        if is_dir(home + "/workshops"):
            self.book("Workshops")
            self.add_folder(home + "/workshops", 1, True)
            self.drop_empty_book()
        var max_site = home + "/modular/max/docs/site"
        var max_bars = max_site + "/sidebars.json"
        self.add_sidebar("MAX: Serving", max_site, max_bars, "servingDevSidebar")
        self.add_sidebar("MAX: Model Development", max_site, max_bars, "modelDevSidebar")
        self.add_sidebar("MAX: GPU Programming", max_site, max_bars, "gpuDevSidebar")

    def page_markdown(self, k: Int) -> String:
        """The Markdown the reader shows for entry k."""
        if k < 0 or k >= len(self.pages):
            return ""
        return path_markdown(self.pages[k].path)

    def resolve_link(self, from_path: String, target: String) -> Tuple[String, String]:
        """Where a link of a page leads: (file, anchor). The file is '' for links to
        the web and for links that lead nowhere here; an anchor-only link gives the
        page itself."""
        var t = target
        var anchor = String("")
        var hash = t.find("#")
        if hash >= 0:
            anchor = String(t[byte=hash + 1:])
            t = cut(t, 0, hash)
        if t.byte_length() == 0:
            return (from_path, anchor)
        if t.find("://") > 0 or t.startswith("mailto:"):
            return (String(""), anchor)
        while t.byte_length() > 1 and t.endswith("/"):
            t = cut(t, 0, t.byte_length() - 1)
        var bases = List[String]()
        if t.startswith("/"):
            # a path of the web site: the Mojo site keeps its pages under /docs
            var rel = String(t[byte=1:])
            if rel.startswith("docs/"):
                rel = cut(rel, 5, -1)
            bases.append(join_path(self.home + "/modular/Mojo/docs/site", rel))
            bases.append(join_path(self.home + "/modular/max/docs/site", rel))
            if rel.startswith("max/"):
                bases.append(join_path(self.home + "/modular/max/docs/site", String(rel[byte=4:])))
        else:
            bases.append(join_path(dirname(from_path), t))
        for b in bases:
            for suffix in ["", ".mdx", ".md", "/index.mdx", "/index.md", "/README.md"]:
                var p = normal_path(b + String(suffix))
                if path_exists(p) and not is_dir(p):
                    return (p, anchor)
        return (String(""), anchor)


def path_markdown(path: String) -> String:
    """The Markdown for any file of the library (a page, or a source file as code)."""
    if path.byte_length() == 0 or not path_exists(path):
        return ""
    if path.endswith(".md") or path.endswith(".mdx"):
        return doc_prepare(file_text(path), path)
    if path.endswith(".html"):
        return html_markdown(file_text(path))
    return source_markdown(path)


def normal_path(path: String) -> String:
    """A path without "." and ".." parts."""
    var parts = List[String]()
    for raw in path.split("/"):
        var s = String(raw)
        if s.byte_length() == 0 or s == ".":
            continue
        if s == "..":
            if len(parts) > 0:
                _ = parts.pop()
            continue
        parts.append(s)
    var out = String("")
    for p in parts:
        out += "/" + p
    return out if out.byte_length() > 0 else String("/")


# ----------------------------------------------------- anchors and search
def heading_slug(text: String) -> String:
    """The anchor a heading gets on the web: lower case, blanks as "-", other
    punctuation dropped."""
    var out = List[Int]()
    for c in decode(text.lower()):
        if (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95 or c >= 128:
            out.append(c)
        elif (c == 32 or c == 45) and len(out) > 0:
            out.append(45)
    while len(out) > 0 and out[len(out) - 1] == 45:
        _ = out.pop()
    return to_str(out)


# ----------------------------------------------------------- the help index
comptime IK_API = 0         # a struct, trait, function or method of the standard library
comptime IK_TITLE = 1       # the title of a page
comptime IK_HEADING = 2     # a section heading
comptime IK_TEXT = 3        # a line of text
comptime IK_CODE = 4        # a line of a code example


struct IndexEntry(Copyable, Movable):
    var kind: Int
    var page: Int           # index into the library's pages
    var text: String        # as shown in the result list
    var low: String         # lower case, what is searched
    var nth: Int            # for headings: which heading of that text on its page (0 = first)
    var owner: String       # API entries: the struct or trait a method belongs to

    def __init__(out self, kind: Int, page: Int, text: String, nth: Int, owner: String):
        self.kind = kind
        self.page = page
        self.text = text
        self.low = text.lower()
        self.nth = nth
        self.owner = owner


def plain_inline(text: String) -> String:
    """A line without the commonest Markdown marks: `code`, **bold**, *italic* and
    [links](...) show as their text."""
    var out = List[Int]()
    var cps = decode(text)
    var i = 0
    var n = len(cps)
    while i < n:
        var c = cps[i]
        if c == 96 or c == 42:
            i += 1
            continue
        if c == 93 and i + 1 < n and cps[i + 1] == 40:
            # "](target)": skip the target
            var j = i + 2
            while j < n and cps[j] != 41:
                j += 1
            i = j + 1
            continue
        if c == 91:
            i += 1
            continue
        out.append(c)
        i += 1
    return to_str(out)


struct DocIndex(Copyable, Movable):
    var entries: List[IndexEntry]
    var built: Bool

    def __init__(out self):
        self.entries = List[IndexEntry]()
        self.built = False

    def add_page(mut self, lib: DocLibrary, k: Int):
        """Index one page: its title, headings, text and code lines; on standard
        library pages the headings that name a declaration become API entries."""
        var page = lib.pages[k].copy()
        var is_std = lib.book_of(k) == "Standard Library"
        self.entries.append(IndexEntry(IK_TITLE, k, page.title, 0, ""))
        var in_code = False
        var owner = String("")
        var seen = List[String]()       # heading texts so far, to number repeats
        for raw in text_lines(path_markdown(page.path)):
            var t = trimmed(raw)
            if t.startswith("```") or t.startswith("~~~"):
                in_code = not in_code
                continue
            if t.byte_length() == 0:
                continue
            if in_code:
                if t.byte_length() >= 3:
                    self.entries.append(IndexEntry(IK_CODE, k, t, 0, ""))
                continue
            if t.startswith("#"):
                var level = 0
                for c in t.as_bytes():
                    if Int(c) != 35:
                        break
                    level += 1
                var head = plain_inline(trimmed(cut(t, level, -1)))
                if head.byte_length() == 0 or level == 1:
                    continue            # the first heading is the title again
                var nth = 0
                for s in seen:
                    if s == head:
                        nth += 1
                seen.append(head)
                var api = is_std and t.find("`") > 0
                if api and (head.startswith("struct ") or head.startswith("trait ")):
                    owner = trimmed(cut(head, head.find(" ") + 1, -1))
                    self.entries.append(IndexEntry(IK_API, k, head, nth, ""))
                elif api:
                    self.entries.append(IndexEntry(IK_API, k, head, nth, owner if level >= 4 else String("")))
                else:
                    if is_std and level <= 2:
                        owner = ""      # "## Functions": what follows belongs to the module
                    self.entries.append(IndexEntry(IK_HEADING, k, head, nth, ""))
                continue
            if t.startswith(">") or t.startswith("|--") or t.startswith("---"):
                t = trimmed(cut(t, 1, -1)) if t.startswith(">") else String("")
                if t.byte_length() == 0:
                    continue
            var line = plain_inline(t)
            if line.byte_length() > 220:
                # by characters: a cut at a byte could fall inside one
                var chars = decode(line)
                line = slice_str(chars, 0, min(200, len(chars)))
            if line.byte_length() >= 3:
                self.entries.append(IndexEntry(IK_TEXT, k, line, 0, ""))

    def build(mut self, lib: DocLibrary):
        self.entries.clear()
        for k in range(len(lib.pages)):
            if lib.pages[k].kind >= DK_PAGE:
                self.add_page(lib, k)
        self.built = True


struct DocQuery(Copyable, Movable):
    """What was asked: words and "phrases" that must all be there, -words that must
    not, and limits - @ API names only, # titles and headings only, ` code only,
    in:book for one book."""
    var need: List[String]
    var avoid: List[String]
    var book: String
    var only: Int           # -1 everything, else an IK_* (IK_HEADING stands for titles too)

    def __init__(out self):
        self.need = List[String]()
        self.avoid = List[String]()
        self.book = ""
        self.only = -1

    def empty(self) -> Bool:
        return len(self.need) == 0


def parse_query(text: String) -> DocQuery:
    var q = DocQuery()
    var cps = decode(text.lower())
    var n = len(cps)
    var i = 0
    while i < n:
        while i < n and cps[i] == 32:
            i += 1
        if i >= n:
            break
        var negative = False
        if cps[i] == 45 and i + 1 < n and cps[i + 1] != 32:
            negative = True
            i += 1
        var word = List[Int]()
        if cps[i] == 34:
            i += 1
            while i < n and cps[i] != 34:
                word.append(cps[i])
                i += 1
            i += 1
        else:
            while i < n and cps[i] != 32:
                word.append(cps[i])
                i += 1
        var w = to_str(word)
        if w.byte_length() == 0:
            continue
        if not negative and len(q.need) == 0 and q.only < 0 and (w.startswith("@") or w.startswith("#") or w.startswith("`")):
            q.only = IK_API if w.startswith("@") else (IK_HEADING if w.startswith("#") else IK_CODE)
            w = cut(w, 1, -1)
            if w.byte_length() == 0:
                continue
        if not negative and w.startswith("in:"):
            q.book = cut(w, 3, -1)
            continue
        if negative:
            q.avoid.append(w)
        else:
            q.need.append(w)
    return q^


def is_word_byte(c: Int) -> Bool:
    return (c >= 48 and c <= 57) or (c >= 97 and c <= 122) or c == 95 or c >= 128


def match_score(e: IndexEntry, q: DocQuery) -> Int:
    """-1 if the entry does not match, else how good a match it is (higher = better)."""
    for a in q.avoid:
        if e.low.find(a) >= 0:
            return -1
    var score = 0
    var bytes = e.low.as_bytes()
    for w in q.need:
        var at = e.low.find(w)
        if at < 0:
            return -1
        # a whole word counts more than a part of one, the start of the line more than its middle
        var before_ok = at == 0 or not is_word_byte(Int(bytes[at - 1]))
        var end = at + w.byte_length()
        var after_ok = end >= len(bytes) or not is_word_byte(Int(bytes[end]))
        score += 40 if (before_ok and after_ok) else (20 if before_ok else 0)
        score += max(0, 20 - at)
    if e.kind == IK_API:
        score += 500
        # the name itself: "struct list", "append"
        var name = e.low
        var sp = name.rfind(" ")
        if sp >= 0:
            name = cut(name, sp + 1, -1)
        if len(q.need) == 1 and name == q.need[0]:
            score += 400
            if e.owner.byte_length() == 0:
                score += 100            # a type or a function before a method of that name
    elif e.kind == IK_TITLE:
        score += 400
        if len(q.need) == 1 and e.low == q.need[0]:
            score += 300
    elif e.kind == IK_HEADING:
        score += 300
    elif e.kind == IK_CODE:
        score += 120
    else:
        score += 100
    score -= min(60, e.low.byte_length() // 4)      # short lines say more
    return score


struct Found(Copyable, Movable):
    var entry: Int          # index into the index's entries
    var score: Int

    def __init__(out self, entry: Int, score: Int):
        self.entry = entry
        self.score = score


def find_help(index: DocIndex, lib: DocLibrary, q: DocQuery, most: Int) -> List[Found]:
    """The entries that match a query, best first; at most `most`, and not more than a
    few lines of running text from any one page (so that one long page does not push
    everything else out)."""
    var out = List[Found]()
    if q.empty():
        return out^
    var per_page = List[Int]()
    for _ in range(len(lib.pages)):
        per_page.append(0)
    var book_ok = List[Int]()           # per page: 1 in the wanted book, 0 not, -1 not looked at yet
    for _ in range(len(lib.pages)):
        book_ok.append(-1)
    for k in range(len(index.entries)):
        var kind = index.entries[k].kind
        if q.only == IK_API and kind != IK_API:
            continue
        if q.only == IK_HEADING and kind != IK_HEADING and kind != IK_TITLE:
            continue
        if q.only == IK_CODE and kind != IK_CODE:
            continue
        var page = index.entries[k].page
        if q.book.byte_length() > 0:
            if book_ok[page] < 0:
                book_ok[page] = 1 if lib.book_of(page).lower().find(q.book) >= 0 else 0
            if book_ok[page] == 0:
                continue
        var s = match_score(index.entries[k], q)
        if s < 0:
            continue
        if kind >= IK_TEXT:
            per_page[page] += 1
            if per_page[page] > 4:
                continue
        # the books a Mojo programmer looks in first come first among equals
        var book = lib.book_of(page)
        if book.startswith("MAX") or book == "Workshops":
            s -= 30
        # insertion by score, best first; equal scores stay in the order of the books
        var at = len(out)
        while at > 0 and out[at - 1].score < s:
            at -= 1
        if at < most:
            out.insert(at, Found(k, s))
            if len(out) > most:
                _ = out.pop()
    return out^
