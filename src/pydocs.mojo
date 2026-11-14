"""The documentation of the Python libraries a Mojo program uses (P11-14). A Mojo program
reaches Python through `var np = Python.import_module("numpy")`; Ctrl-F1 on `np.zeros`
asks that Python - the project's own, where pixi installed the library - for pydoc's
text of `numpy.zeros`, and shows it in the documentation window.

(Mojo libraries need nothing of their own: installed packages come compiled, which
`mojo doc` cannot read, but the language server can - it runs in the project's
environment, see app_lsp.lsp_server_command.)"""
from std.collections import List
from pkginstall import quoted_after

comptime PYDOC_MAX_LINES = 1500


struct PyBinding(Copyable, Movable):
    var name: String        # the Mojo variable ("np")
    var module: String      # the module it holds ("numpy")

    def __init__(out self, name: String, module: String):
        self.name = name
        self.module = module


def is_ident(s: String) -> Bool:
    if s.byte_length() == 0:
        return False
    for k in range(s.byte_length()):
        var c = Int(s.as_bytes()[k])
        var ok = c == 95 or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (k > 0 and c >= 48 and c <= 57)
        if not ok:
            return False
    return True


def python_bindings(text: String) -> List[PyBinding]:
    """The variables a Mojo file binds to Python modules: `var np = Python.import_module("numpy")`
    (also without `var`, and with `: PythonObject`). Later ones win, as in the program."""
    var out = List[PyBinding]()
    for raw in text.split("\n"):
        var line = String(String(raw).strip())
        var k = line.find("Python.import_module(")
        var eq = line.find("=")
        if k < 0 or eq < 0:            # (a "=" after the call leaves no plain name before it)
            continue
        var module = quoted_after(line, "Python.import_module(")
        var name = String(String(line[byte=0:eq]).strip())
        if name.startswith("var "):
            name = String(String(name[byte=4:]).strip())
        var colon = name.find(":")
        if colon >= 0:
            name = String(String(name[byte=0:colon]).strip())
        if not is_ident(name) or module.byte_length() == 0:
            continue
        for i in range(len(out)):
            if out[i].name == name:
                _ = out.pop(i)
                break
        out.append(PyBinding(name, module))
    return out^


def is_chain_cp(c: Int) -> Bool:
    return c == 95 or c == 46 or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57)


def dotted_at(line: List[Int], col: Int) -> String:
    """The dotted name ending with the word the cursor is on: on `linalg` in
    `np.linalg.norm(x)` that is "np.linalg" ('' if the cursor is on no name)."""
    var a = min(col, len(line))
    var b = a
    while a > 0 and is_chain_cp(line[a - 1]):
        a -= 1
    while b < len(line) and is_chain_cp(line[b]) and line[b] != 46:
        b += 1
    var s = String("")
    for q in range(a, b):
        s += chr(line[q])
    var lo = 0
    var hi = s.byte_length()
    while lo < hi and Int(s.as_bytes()[lo]) == 46:
        lo += 1
    while hi > lo and Int(s.as_bytes()[hi - 1]) == 46:
        hi -= 1
    return String(s[byte=lo:hi])


def python_target(chain: String, bindings: List[PyBinding]) -> String:
    """What to ask pydoc about: the chain with its first name replaced by the module
    that variable holds ("np.linalg.norm" -> "numpy.linalg.norm"); '' if the chain
    does not start with such a variable."""
    if chain.byte_length() == 0:
        return ""
    var dot = chain.find(".")
    var first = String(chain[byte=0:dot]) if dot >= 0 else chain
    var rest = String(chain[byte=dot:]) if dot >= 0 else String("")
    for b in bindings:
        if b.name == first:
            return b.module + rest
    return ""


def pydoc_command(python: String, target: String) -> String:
    """A shell command that prints pydoc's plain text for `target`, or "pydoc: <why>"
    and a non-zero exit when Python cannot find it."""
    var script = "import pydoc, sys\ntry:\n    print(pydoc.render_doc(sys.argv[1], '%s', renderer=pydoc.plaintext))\nexcept BaseException as e:\n    print('pydoc: ' + str(e)); sys.exit(1)\n"
    return python + " -c '" + script.replace("'", "'\\''") + "' '" + target.replace("'", "'\\''") + "' 2>&1 </dev/null"


def pydoc_markdown(target: String, text: String, which_python: String) -> String:
    """pydoc's text as a page of the documentation window (long ones cut)."""
    var lines = text.split("\n")
    var body = String("")
    var n = 0
    for l in lines:
        if n >= PYDOC_MAX_LINES:
            body += "... (" + String(len(lines) - n) + " more lines: `python -m pydoc " + target + "`)\n"
            break
        body += String(l).replace("```", "'''") + "\n"
        n += 1
    return "# " + target + "\n\n*Python's documentation (pydoc), from " + which_python + "*\n\n```\n" + String(body.rstrip()) + "\n```\n"
