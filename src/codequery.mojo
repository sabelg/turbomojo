"""What a search for help looks like, so one box can take code as well as words: a
name (`append`), a dotted path (`List.append`, `std.collections.list`), or a pasted
error line (`x.mojo:3:5: error: use of unknown declaration 'y'`), besides the
finder's own syntax (words, "a phrase", @api, #heading, `code, in:book).
"""
from std.collections import List
from doclib import Found, DocIndex, plain_inline

comptime QS_WORDS = 0       # the finder's own syntax: as it is
comptime QS_NAME = 1        # one identifier
comptime QS_PATH = 2        # identifiers joined by dots
comptime QS_ERROR = 3       # a compiler message


def is_ident_char(c: Int) -> Bool:
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95


def is_identifier(s: String) -> Bool:
    if s.byte_length() == 0:
        return False
    var b = s.as_bytes()
    if Int(b[0]) >= 48 and Int(b[0]) <= 57:
        return False
    for c in b:
        if not is_ident_char(Int(c)):
            return False
    return True


def error_text(text: String) -> String:
    """The message of a pasted compiler line: what follows "error: " (or "warning: ",
    "note: "); "" if it is not one."""
    for mark in ["error: ", "warning: ", "note: "]:
        var k = text.find(String(mark))
        if k >= 0:
            var rest = String(text[byte=k + String(mark).byte_length():])
            var nl = rest.find("\n")
            if nl >= 0:
                var line = String(rest[byte=0:nl])
                rest = line
            return String(rest.strip())
    return ""


def query_shape(text: String) -> Int:
    var t = String(text.strip())
    if t.byte_length() == 0:
        return QS_WORDS
    if error_text(t).byte_length() > 0:
        return QS_ERROR
    if is_identifier(t):
        return QS_NAME
    var parts = t.split(".")
    if len(parts) >= 2:
        for p in parts:
            if not is_identifier(String(p)):
                return QS_WORDS
        return QS_PATH
    return QS_WORDS


def path_parts(text: String) -> List[String]:
    var out = List[String]()
    for p in String(text.strip()).split("."):
        out.append(String(p))
    return out^


def unquoted_words(message: String) -> String:
    """The words of a message without what it quotes (the names in 'quotes' are the
    user's own, not the documentation's) and without punctuation."""
    var out = String("")
    var inq = False
    var word = String("")
    for c in message.codepoints():
        var n = Int(c)
        if n == 39 or n == 96:           # ' or `
            inq = not inq
            if word.byte_length() > 0 and not inq:
                word = ""
            continue
        if inq:
            continue
        if (n >= 65 and n <= 90) or (n >= 97 and n <= 122):
            word += chr(n)
        else:
            if word.byte_length() > 2:
                out += (" " if out.byte_length() > 0 else String("")) + word
            word = ""
    if word.byte_length() > 2 and not inq:
        out += (" " if out.byte_length() > 0 else String("")) + word
    return out^


def finder_query(text: String) -> String:
    """The finder's query for what was typed or pasted: a name or the last part of a
    path looks among the standard library's declarations; an error line searches for
    the words of its message; anything else is the finder's own syntax."""
    var shape = query_shape(text)
    if shape == QS_NAME:
        return "@" + String(text.strip())
    if shape == QS_PATH:
        var p = path_parts(text)
        return "@" + p[len(p) - 1]
    if shape == QS_ERROR:
        return unquoted_words(error_text(text))
    return text


def by_owner(found: List[Found], index: DocIndex, parts: List[String]) -> List[Found]:
    """For a dotted path: the declarations whose owner is the part before the last
    (`List` in `List.append`) first, the others after them, in their order."""
    if len(parts) < 2:
        return found.copy()
    var owner = parts[len(parts) - 2].lower()
    var first = List[Found]()
    var rest = List[Found]()
    for f in found:
        if index.entries[f.entry].owner.lower() == owner:
            first.append(f.copy())
        else:
            rest.append(f.copy())
    for f in rest:
        first.append(f.copy())
    return first^


def first_prose(section: String) -> String:
    """The first sentence of a section that is prose (not its heading, code, a list
    of fields or a label), without Markdown marks; "" if there is none."""
    var in_code = False
    for raw in section.split("\n"):
        var t = String(String(raw).strip())
        if t.startswith("```") or t.startswith("~~~"):
            in_code = not in_code
            continue
        if in_code or t.byte_length() == 0 or t.startswith("#") or t.startswith("-") or t.startswith("*") or t.startswith("|") or t.startswith(">"):
            continue
        var s = plain_inline(t)
        var dot = s.find(". ")
        if dot > 0:
            var sentence = String(s[byte=0:dot + 1])
            s = sentence
        return s^
    return ""
