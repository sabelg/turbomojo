"""The docs pane's text: the section of a documentation page that one heading starts
(the way the finder's index names headings), so the pane shows what a declaration of
the standard library says without the rest of its page."""
from std.collections import List
from doclib import cut, text_lines, trimmed, plain_inline

comptime DOCPANE_SECTION_MAX = 120      # lines of a section the pane shows


def heading_level(t: String) -> Int:
    var level = 0
    for c in t.as_bytes():
        if Int(c) != 35:
            break
        level += 1
    return level


def md_section(text: String, heading: String, nth: Int) -> String:
    """The part of Markdown `text` from its `nth` heading whose plain text is `heading`
    up to the next heading of the same or a higher level (headings in code blocks do
    not count). "" if there is no such heading. A long section is cut short."""
    var lines = text_lines(text)
    var in_code = False
    var start = -1
    var level = 0
    var seen = 0
    var out = String("")
    var n = 0
    for k in range(len(lines)):
        var t = trimmed(lines[k])
        var fence = t.startswith("```") or t.startswith("~~~")
        var head = not in_code and not fence and t.startswith("#")
        if start < 0:
            if fence:
                in_code = not in_code
            elif head:
                var l = heading_level(t)
                if plain_inline(trimmed(cut(t, l, -1))) == heading:
                    if seen == nth:
                        start = k
                        level = l
                    else:
                        seen += 1
            if start < 0:
                continue
        elif head and heading_level(t) <= level:
            break
        elif fence:
            in_code = not in_code
        if n >= DOCPANE_SECTION_MAX:
            out += ("```\n" if in_code else String("")) + "\n..."
            break
        out += lines[k] + "\n"
        n += 1
    return out^
