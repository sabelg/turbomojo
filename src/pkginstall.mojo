"""Install what a program uses (P11-13). When a build or a run fails because a library
is not installed - Mojo says "unable to locate module 'max'", Python (through
Python.import_module) "No module named 'numpy'" - TurboMojo names it, looks for its
package on the project's channels (`pixi search`, in the project's folder), and with a
yes adds it (`pixi add`), then builds or runs again. Nothing is installed without a yes.

The program then has to run inside the project's environment, where the package went:
builds and runs in a pixi project run with its environment active (in_env: `pixi
shell-hook`, as `pixi run` would), unless the IDE already runs in that environment.

This module reads the messages and names the packages; the IDE does the rest
(app_pkginstall.mojo)."""
from std.collections import List

comptime PK_MOJO = 0
comptime PK_PYTHON = 1


struct MissingModule(Copyable, Movable):
    var kind: Int           # PK_MOJO or PK_PYTHON
    var module: String      # the top-level name the program imports ("numpy", "max")

    def __init__(out self, kind: Int, module: String):
        self.kind = kind
        self.module = module


def quoted_after(line: String, marker: String) -> String:
    """The text in quotes ('...' or "...") just after `marker` in `line` ("" if none)."""
    var k = line.find(marker)
    if k < 0:
        return ""
    var rest = String(line[byte=k + marker.byte_length():])
    if rest.byte_length() < 2:
        return ""
    var q = String(rest[byte=0:1])
    if q != "'" and q != "\"":
        return ""
    var end = String(rest[byte=1:]).find(q)
    if end < 0:
        return ""
    return String(rest[byte=1 : 1 + end])


def top_level(module: String) -> String:
    var dot = module.find(".")
    return String(module[byte=0:dot]) if dot >= 0 else module


def built_in(kind: Int, module: String) -> Bool:
    """Part of Mojo or Python themselves: if missing, the installation is broken - no
    package to add."""
    if kind == PK_MOJO:
        for m in ["std", "builtin", "python", "collections", "memory", "testing", "sys", "os", "math", "algorithm", "time", "utils", "random", "pathlib", "tempfile", "ffi", "io", "hashlib", "logger", "runtime", "subprocess", "complex", "bit", "benchmark", "compile", "documentation", "reflection", "itertools", "format", "base64", "iter", "prelude"]:
            if module == String(m):
                return True
        return False
    for m in ["sys", "os", "math", "json", "re", "time", "collections", "itertools", "functools", "subprocess", "pathlib", "random", "typing", "io", "string", "datetime", "struct", "socket", "threading", "unittest", "logging", "argparse", "csv", "copy", "pickle", "hashlib", "abc", "enum", "dataclasses", "shutil", "glob", "tempfile", "platform", "builtins", "__main__"]:
        if module == String(m):
            return True
    return False


def imported_top(source_line: String) -> String:
    """The first name of what a `from a.b import c` / `import a.b` line imports ("a")."""
    var s = String(source_line.strip())
    var rest: String
    if s.startswith("from "):
        rest = String(s[byte=5:])
    elif s.startswith("import "):
        rest = String(s[byte=7:])
    else:
        return ""
    var t = String(rest.strip())
    var end = t.byte_length()
    for k in range(t.byte_length()):
        var c = Int(t.as_bytes()[k])
        if c == 46 or c == 32 or c == 44 or c == 9:     # ".", " ", ",", a tab
            end = k
            break
    return String(t[byte=0:end])


def missing_modules(output: String) -> List[MissingModule]:
    """The libraries a build's or run's output says are not there, each once, in the
    order they are named; modules that belong to Mojo or Python are left out. Mojo names
    only the part it could not find - for `from max.tensor import` that is "tensor", a
    part of max - so a Mojo name counts only when it is what the source line under the
    message imports first."""
    var out = List[MissingModule]()
    var lines = output.split("\n")
    for li in range(len(lines)):
        var line = String(lines[li])
        var kind = -1
        var name = quoted_after(line, "unable to locate module ")
        if name.byte_length() > 0:
            kind = PK_MOJO
            var src = String(lines[li + 1]) if li + 1 < len(lines) else String("")
            var top = imported_top(src)
            if top.byte_length() > 0 and top != name:
                continue            # a module inside a package that is there
        else:
            name = quoted_after(line, "No module named ")
            if name.byte_length() > 0:
                kind = PK_PYTHON
        if kind < 0:
            continue
        name = top_level(name)
        if name.byte_length() == 0 or built_in(kind, name):
            continue
        var seen = False
        for m in out:
            if m.kind == kind and m.module == name:
                seen = True
        if not seen:
            out.append(MissingModule(kind, name))
    return out^


def package_for(kind: Int, module: String) -> String:
    """The conda package that brings the module: mostly the same name, lower case; a few
    Python modules come in packages with other names."""
    if kind == PK_PYTHON:
        var names = ["yaml", "cv2", "PIL", "sklearn", "skimage", "bs4", "dateutil", "Crypto", "serial", "dotenv", "torch", "attr", "jwt", "zmq", "usb", "magic", "gi", "OpenSSL", "Levenshtein", "docx", "pptx", "fitz", "mpl_toolkits", "tensorflow_datasets", "sentencepiece"]
        var pkgs = ["pyyaml", "opencv", "pillow", "scikit-learn", "scikit-image", "beautifulsoup4", "python-dateutil", "pycryptodome", "pyserial", "python-dotenv", "pytorch", "attrs", "pyjwt", "pyzmq", "pyusb", "python-magic", "pygobject", "pyopenssl", "python-levenshtein", "python-docx", "python-pptx", "pymupdf", "matplotlib", "tensorflow-datasets", "sentencepiece"]
        for k in range(len(names)):
            if module == String(names[k]):
                return String(pkgs[k])
    elif module == "gpu" or module == "layout" or module == "tensor" or module == "engine" or module == "driver":
        return "max"            # (Mojo 1.2: GPU and layout/TileTensor modules ship in MAX)
    return module.lower()


def import_note(kind: Int, module: String) -> String:
    """What else the program needs besides the package ("" mostly)."""
    if kind == PK_MOJO and module == "gpu":
        return "In Mojo 1.2 the GPU modules ship in MAX as max.gpu (from max.gpu.host import DeviceContext; host checks via from std.sys import has_accelerator)."
    if kind == PK_MOJO and module == "layout":
        return "TileTensor and row_major live in the layout package bundled with MAX (from layout import TileTensor, row_major)."
    return ""


def what_it_is(kind: Int) -> String:
    return "a Mojo package" if kind == PK_MOJO else String("a Python package")


def in_env(cmd: String, pixi_cmd: String, manifest: String, env: String = "default") -> String:
    """`cmd` run with the project's environment active, as `pixi run` has it (its
    activation scripts are bash, so bash runs it)."""
    var eflag = ""
    if env.byte_length() > 0 and env != "default":
        eflag = " -e '" + env.replace("'", "'\\''") + "'"
    var hook = "eval \"$(" + pixi_cmd + " shell-hook --shell bash" + eflag + " --manifest-path " + "'" + manifest.replace("'", "'\\''") + "')\" && "
    return "bash -c '" + (hook + cmd).replace("'", "'\\''") + "'"
