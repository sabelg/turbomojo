"""The docs pane's text: the section of a documentation page that one heading starts
(the way the finder's index names headings), so the pane shows what a declaration of
the standard library says without the rest of its page."""
from std.collections import List
from doclib import cut, text_lines, trimmed, plain_inline
from pydocs import is_ident

comptime DOCPANE_SECTION_MAX = 260      # lines of a section the pane shows


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


def md_mojo_blocks(md: String) -> List[String]:
    """Fenced Mojo code blocks of `md` (or all fenced blocks if none name Mojo)."""
    var mojo_blocks = List[String]()
    var all_blocks = List[String]()
    var in_code = False
    var is_mojo = False
    var cur = String("")
    for l in text_lines(md):
        var t = trimmed(l)
        if t.startswith("```") or t.startswith("~~~"):
            if in_code:
                while cur.endswith("\n\n"):
                    cur = cut(cur, 0, cur.byte_length() - 1)
                if cur.byte_length() > 0:
                    all_blocks.append(cur)
                    if is_mojo:
                        mojo_blocks.append(cur)
                cur = ""
                in_code = False
                is_mojo = False
            else:
                var rest = trimmed(cut(t, 3, -1)).lower()
                is_mojo = rest.byte_length() == 0 or rest.startswith("mojo") or rest.startswith("🔥")
                in_code = True
                cur = ""
            continue
        if in_code:
            cur += l + "\n"
    if len(mojo_blocks) > 0:
        return mojo_blocks^
    return all_blocks^


def clean_type_name(raw: String) -> String:
    """Base type identifier from an annotation like `mut List[Int]` -> `List`."""
    var s = trimmed(raw)
    for kw in ["mut ", "var ", "out ", "imm ", "read ", "deinit ", "ref "]:
        if s.startswith(String(kw)):
            s = trimmed(cut(s, String(kw).byte_length(), -1))
    if s.startswith("Self."):
        s = cut(s, 5, -1)
    var end = 0
    var sb = s.as_bytes()
    while end < len(sb):
        var c = Int(sb[end])
        if c == 95 or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (end > 0 and c >= 48 and c <= 57):
            end += 1
        else:
            break
    return cut(s, 0, end)


def infer_receiver_owner(text: String, cur_row: Int, chain: String) -> String:
    """Owner type of the receiver before the last `.` in `chain` ('' if none is known):
    `Python.import_module` -> `Python`, `self.x` inside `struct Foo` -> `Foo`, or a
    typed / constructed local `var items = List[Int]()` -> `List`."""
    var parts = chain.split(".")
    if len(parts) < 2:
        return ""
    var recv = String(parts[len(parts) - 2])
    if not is_ident(recv):
        return ""
    var rb = Int(recv.as_bytes()[0])
    if rb >= 65 and rb <= 90:
        return recv
    var lines = text_lines(text)
    var limit = min(max(0, cur_row), max(0, len(lines) - 1))
    if recv == "self":
        var r = limit
        while r >= 0:
            var t = trimmed(lines[r])
            if t.startswith("struct ") or t.startswith("trait "):
                var sp = t.find(" ")
                return clean_type_name(cut(t, sp + 1, -1))
            r -= 1
        return ""
    var found = String("")
    for r in range(limit + 1):
        var t = trimmed(lines[r])
        # parameter in `def ...(..., recv: Type, ...)`:
        if t.startswith("def "):
            var pat = recv + ":"
            var at = t.find(pat)
            if at > 0:
                var prev = Int(t.as_bytes()[at - 1])
                if prev == 40 or prev == 32 or prev == 44:
                    var ty = clean_type_name(cut(t, at + pat.byte_length(), -1))
                    if ty.byte_length() > 0:
                        found = ty
        # `var recv: Type ...` or `var recv = Expr`
        if t.startswith("var "):
            var rest = trimmed(cut(t, 4, -1))
            if rest.startswith(recv):
                var after = trimmed(cut(rest, recv.byte_length(), -1))
                if after.startswith(":"):
                    var ty = clean_type_name(cut(after, 1, -1))
                    if ty.byte_length() > 0:
                        found = ty
                elif after.startswith("="):
                    var rhs = trimmed(cut(after, 1, -1))
                    if rhs.startswith("\"") or rhs.startswith("'") or rhs.startswith("String("):
                        found = "String"
                    elif rhs.startswith("[") or rhs.startswith("List[") or rhs.startswith("List("):
                        found = "List"
                    elif rhs.startswith("{") or rhs.startswith("Dict[") or rhs.startswith("Dict("):
                        found = "Dict"
                    elif rhs.byte_length() > 0:
                        var fb = Int(rhs.as_bytes()[0])
                        if fb >= 65 and fb <= 90:
                            var cand = clean_type_name(rhs)
                            var tail = trimmed(cut(rhs, cand.byte_length(), -1))
                            if cand.byte_length() > 0 and (tail.startswith("(") or tail.startswith("[")):
                                found = cand
    return found^
