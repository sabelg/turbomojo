"""Explanations of Mojo error messages: what a message means, why Mojo says it, how to
fix it, and a small program before and after the fix.

The pages are help/errors/*.md, built in (src/errhelp_pages.mojo, made by
scripts/gen_errhelp.py). Each starts with `<!-- match: TEXT -->` (several texts separated by
` || `): an error whose message contains one is explained by that page. F1 on a row of the Problems page, or in an
editor on a line with a problem, opens the explanation beside the code; the help book
has them all as one page ("Mojo error messages"), which the finder (/) searches.
"""
from std.collections import List
from errhelp_pages import ERR_PAGE_COUNT, err_page_key, err_page_text


def err_matches(i: Int) -> List[String]:
    """The texts an error message may contain to be explained by page i (the match
    line lists them separated by " || ")."""
    var out = List[String]()
    var t = err_page_text(i)
    var b = t.find(" -->")
    if not t.startswith("<!-- match: ") or b < 0:
        return out^
    for part in String(t[byte=12:b]).split(" || "):
        var m = String(String(part).strip())
        if m.byte_length() > 0:
            out.append(m)
    return out^


def explain_for(message: String) -> Int:
    """The page that explains `message`, or -1."""
    for i in range(ERR_PAGE_COUNT):
        for m in err_matches(i):
            if message.find(m) >= 0:
                return i
    return -1


def err_body(i: Int) -> String:
    """Page i without its match line."""
    var t = err_page_text(i)
    var nl = t.find("\n")
    return String(t[byte=nl + 1:]) if nl >= 0 else t


def err_title(i: Int) -> String:
    var b = err_body(i)
    if b.startswith("# "):
        var nl = b.find("\n")
        return String(b[byte=2:nl]) if nl > 0 else String(b[byte=2:])
    return err_page_key(i)


def errors_book() -> String:
    """Every explanation as one page of the help book, headings one level down."""
    var out = String("# Mojo error messages\n\nWhat the most frequent messages of the Mojo compiler mean and how to fix them. **F1** on a problem (in the Problems page, or on its line in the editor) opens its explanation beside the code.\n")
    for i in range(ERR_PAGE_COUNT):
        out += "\n"
        var code = False
        for line in err_body(i).split("\n"):
            var l = String(line)
            if l.startswith("```"):
                code = not code
            elif l.startswith("#") and not code:
                out += "#"
            out += l + "\n"
    return out^
