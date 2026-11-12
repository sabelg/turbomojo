"""Grounded "explain" prompts for the coding agent: what TurboMojo knows locally (the
code with its line numbers, the compiler's message, the built-in explanation of that
message, the downloaded documentation of the names involved) is put into the prompt,
with the request to answer from it and to name the pages used. And the imports an
answer suggests, so they can be checked against the Mojo that is installed.
"""
from std.collections import List

comptime EXCERPT_MAX = 1500         # characters of one documentation excerpt
comptime EXCERPTS_MAX = 3           # excerpts in one prompt

comptime MOJO_KEYWORDS = "def struct trait var ref mut out owned raises return if elif else for while in not and or is pass break continue import from as with try except finally raise comptime True False None self Self print range len"


def numbered(lines: List[String], first: Int) -> String:
    """`lines` with their numbers (`first` is the number of the first), as a block."""
    var out = String("")
    for k in range(len(lines)):
        out += String(first + k) + ": " + lines[k] + "\n"
    return out^


def grounding(explanation: String, excerpts: List[String]) -> String:
    var out = String("")
    if explanation.byte_length() > 0:
        out += "\n### Page: TurboMojo's explanation of this message\n\n" + explanation + "\n"
    for e in excerpts:
        out += "\n" + e + "\n"
    return out^


comptime RULES = "Answer from the material below where it applies, and say which pages you used, as [page: title]. If the material does not cover something, say so rather than guessing. This is Mojo 1.x: functions are `def` (there is no `fn`), constants are `comptime` (there is no `alias`), standard library imports start with `std.` (`from std.collections import List`). Keep the answer short; show a corrected snippet if there is a fix."


def explain_error_prompt(message: String, place: String, code: String, explanation: String, excerpts: List[String]) -> String:
    return "Explain this Mojo compiler error and how to fix it.\n\n" + RULES + "\n\n### The error\n\n" + place + ": " + message + "\n\n### The code (line numbers on the left)\n\n```mojo\n" + code + "```\n" + grounding(explanation, excerpts)


def explain_code_prompt(place: String, code: String, excerpts: List[String]) -> String:
    return "Explain what this Mojo code does, step by step, and point out anything that looks wrong.\n\n" + RULES + "\n\n### The code (" + place + ", line numbers on the left)\n\n```mojo\n" + code + "```\n" + grounding("", excerpts)


def doc_excerpt(page_title: String, section: String) -> String:
    var s = section
    if s.byte_length() > EXCERPT_MAX:
        var cut = String(s[byte=0:EXCERPT_MAX])
        s = cut + "\n..."
    return "### Page: " + page_title + "\n\n" + s


def is_name_start(c: Int) -> Bool:
    return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95


def is_name_char(c: Int) -> Bool:
    return is_name_start(c) or (c >= 48 and c <= 57)


def names_in(text: String) -> List[String]:
    """The names a text uses, each once, in order: those in 'quotes' first (the
    compiler quotes the names its message is about), keywords left out."""
    var quoted = List[String]()
    var plain = List[String]()
    var keywords = MOJO_KEYWORDS.split(" ")
    var b = text.as_bytes()
    var inq = False
    var k = 0
    while k < len(b):
        var c = Int(b[k])
        if c == 39:
            inq = not inq
            k += 1
            continue
        if is_name_start(c):
            var j = k
            while j < len(b) and is_name_char(Int(b[j])):
                j += 1
            var w = String(text[byte=k:j])
            var known = False
            for kw in keywords:
                if String(kw) == w:
                    known = True
            if not known and w.byte_length() >= 2:
                if inq:
                    if w not in quoted:
                        quoted.append(w)
                elif w not in plain:
                    plain.append(w)
            k = j
            continue
        k += 1
    for w in plain:
        if w not in quoted:
            quoted.append(w)
    return quoted^


def answer_imports(text: String) -> List[String]:
    """The import lines of the Mojo code blocks in an answer, each once."""
    var out = List[String]()
    var in_code = False
    for raw in text.split("\n"):
        var t = String(String(raw).strip())
        if t.startswith("```"):
            in_code = not in_code
            continue
        if in_code and (t.startswith("from ") and t.find(" import ") > 0 or t.startswith("import ")):
            if t not in out:
                out.append(t)
    return out^


def import_check_program(imports: List[String]) -> String:
    """A program that only imports: it builds if every import is right."""
    var out = String("")
    for i in imports:
        out += i + "\n"
    return out + "\n\ndef main():\n    pass\n"


def failed_import_lines(output: String, file: String) -> List[Int]:
    """The 1-based lines of `file` the compiler's output names with an error."""
    var out = List[Int]()
    for raw in output.split("\n"):
        var l = String(raw)
        var k = l.find(file + ":")
        if k < 0 or l.find("error:") < 0:
            continue
        var rest = String(l[byte=k + file.byte_length() + 1:])
        var colon = rest.find(":")
        if colon <= 0:
            continue
        try:
            var n = atol(String(rest[byte=0:colon]))
            if n not in out:
                out.append(n)
        except:
            pass
    return out^
