"""The explanations of Mojo error messages, made from help/errors/ by
scripts/gen_errhelp.py - do not edit here."""

comptime ERR_PAGE_COUNT = 16

comptime ERR_UNKNOWN_NAME = "<!-- match: use of unknown declaration -->\n# Unknown name\n\nMojo says something like: `use of unknown declaration ...`\n\n## What it means\n\nMojo found a name it has no definition for: a variable, function or type that is not declared in this file, not imported, or spelled differently.\n\n## How to fix it\n\n- Check the spelling (Mojo names are case-sensitive).\n- Declare a variable with `var` before using it.\n- Import what comes from elsewhere: `from std.collections import List` (Mojo 1.x imports need the `std.` prefix).\n\n## Before (does not build)\n\n```mojo\ndef main():\n    print(totl)\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    var total = 3\n    print(total)\n```\n"
comptime ERR_IMPLICIT_DECLARATION = "<!-- match: implicit declaration of -->\n# A new name needs `var`\n\nMojo says something like: `implicit declaration of ...`\n\n## What it means\n\nUnlike Python, Mojo does not create a variable the first time you assign to it: a new name is declared with `var`.\n\n## How to fix it\n\n- Write `var x = 1` the first time; later assignments are `x = 2`.\n- Inside a struct, fields are declared with `var` in the struct body.\n\n## Before (does not build)\n\n```mojo\ndef main():\n    count = 1\n    print(count)\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    var count = 1\n    count = count + 1\n    print(count)\n```\n"
comptime ERR_FN_REMOVED = "<!-- match: 'fn' has been removed -->\n# `fn` no longer exists\n\nMojo says something like: `'fn' has been removed ...`\n\n## What it means\n\nMojo 1.x has one kind of function: `def`. A `def` does not raise unless it is marked `raises`, which is what `fn` used to mean.\n\n## How to fix it\n\n- Replace `fn` with `def`.\n- If the function can raise an error, add `raises`: `def load(path: String) raises -> String:`.\n\n## Before (does not build)\n\n```mojo\nfn main():\n    print(1)\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    print(1)\n```\n"
comptime ERR_IMPLICIT_CONVERSION = "<!-- match: cannot implicitly convert -->\n# A value of the wrong type\n\nMojo says something like: `cannot implicitly convert ...`\n\n## What it means\n\nA value of one type was used where another type is needed, and Mojo will not convert between them by itself (for example text where a number is expected).\n\n## How to fix it\n\n- Convert it yourself: `Int(\"12\")` or `atol(\"12\")` parses text (and raises if it is not a number); `String(42)` makes text of a number.\n- Or change the declared type, if the value is right and the type was wrong.\n\n## Before (does not build)\n\n```mojo\ndef main():\n    var n: Int = \"12\"\n    print(n)\n```\n\n## After (builds)\n\n```mojo\ndef main() raises:\n    var n: Int = Int(\"12\")\n    print(n)\n```\n"
comptime ERR_IMPLICIT_COPY = "<!-- match: cannot be implicitly copied -->\n# Copying must be asked for\n\nMojo says something like: `cannot be implicitly copied ...`\n\n## What it means\n\nSome types (List, String's larger cousins, your own structs) are not copied behind your back: `var b = a` would copy the whole list, so Mojo wants you to say what you mean.\n\n## How to fix it\n\n- `a.copy()` makes a copy and keeps `a`.\n- `a^` moves `a` into the new place; `a` cannot be used afterwards.\n- A struct can be made copyable with `(Copyable, Movable)` and copied with `.copy()`.\n\n## Before (does not build)\n\n```mojo\ndef main():\n    var a = List[Int]()\n    a.append(1)\n    var b = a\n    print(len(b), len(a))\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    var a = List[Int]()\n    a.append(1)\n    var b = a.copy()\n    print(len(b), len(a))\n```\n"
comptime ERR_UNINITIALIZED = "<!-- match: use of uninitialized value -->\n# A value used before it has one\n\nMojo says something like: `use of uninitialized value ...`\n\n## What it means\n\nThe variable was declared but never given a value on this path - or it was moved away with `^` and is empty now.\n\n## How to fix it\n\n- Give it a value where it is declared: `var x: Int = 0`.\n- Make sure every branch of an `if` sets it.\n- After `b = a^`, use `b`, not `a` (or copy with `a.copy()` instead of moving).\n\n## Before (does not build)\n\n```mojo\ndef main():\n    var x: Int\n    print(x)\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    var x: Int = 0\n    print(x)\n```\n"
comptime ERR_MAY_RAISE = "<!-- match: cannot call function that may raise -->\n# A call that can raise, in a function that cannot\n\nMojo says something like: `cannot call function that may raise ...`\n\n## What it means\n\nThe function you call is marked `raises` (it can fail with an Error), but the function calling it is not, so the error would have nowhere to go.\n\n## How to fix it\n\n- Mark the caller `raises` too: `def main() raises:`.\n- Or handle the error where it happens: `try: ... except e: print(e)`.\n\n## Before (does not build)\n\n```mojo\ndef parse() raises -> Int:\n    return atol(\"7\")\n\ndef main():\n    print(parse())\n```\n\n## After (builds)\n\n```mojo\ndef parse() raises -> Int:\n    return atol(\"7\")\n\ndef main():\n    try:\n        print(parse())\n    except e:\n        print(\"could not parse:\", e)\n```\n"
comptime ERR_ALIASING = "<!-- match: aliasing values passed mutably -->\n# Two arguments that are the same thing\n\nMojo says something like: `aliasing values passed mutably ...`\n\n## What it means\n\nYou pass something to a method that may change it (`mut self`) and, in the same call, a part of it to read. Mojo forbids this: the method could change what it is reading.\n\n## How to fix it\n\n- Copy the part to a local first: `var t = b.s` then `b.put(t)` (for List and other non-copyable values: `b.s.copy()`).\n\n## Before (does not build)\n\n```mojo\nstruct Box:\n    var s: String\n    def __init__(out self):\n        self.s = \"a\"\n    def put(mut self, t: String):\n        self.s = t\n\ndef main():\n    var b = Box()\n    b.put(b.s)\n```\n\n## After (builds)\n\n```mojo\nstruct Box:\n    var s: String\n    def __init__(out self):\n        self.s = \"a\"\n    def put(mut self, t: String):\n        self.s = t\n\ndef main():\n    var b = Box()\n    var t = b.s\n    b.put(t)\n    print(b.s)\n```\n"
comptime ERR_IMMUTABLE = "<!-- match: expression must be mutable -->\n# Changing something that may not be changed\n\nMojo says something like: `expression must be mutable ...`\n\n## What it means\n\nThe value you assign to or change in place is read-only here - most often `self` in a method declared without `mut`, or an argument (arguments are read-only by default).\n\n## How to fix it\n\n- Declare the method `def bump(mut self):` to change fields.\n- For an argument the function may change, write `mut x: Int`; to have your own copy, `var x: Int`.\n\n## Before (does not build)\n\n```mojo\nstruct Counter:\n    var n: Int\n    def __init__(out self):\n        self.n = 0\n    def bump(self):\n        self.n += 1\n\ndef main():\n    var c = Counter()\n    c.bump()\n```\n\n## After (builds)\n\n```mojo\nstruct Counter:\n    var n: Int\n    def __init__(out self):\n        self.n = 0\n    def bump(mut self):\n        self.n += 1\n\ndef main():\n    var c = Counter()\n    c.bump()\n    print(c.n)\n```\n"
comptime ERR_INIT_OUT = "<!-- match: __init__ method must return Self type with 'out' -->\n# `__init__` takes `out self`\n\nMojo says something like: `__init__ method must return Self type with 'out' ...`\n\n## What it means\n\nA constructor makes a new value: its `self` is written to, not read, so it is declared `out self`.\n\n## How to fix it\n\n- Write `def __init__(out self):`; every constructor takes `out self`.\n\n## Before (does not build)\n\n```mojo\nstruct Point:\n    var x: Int\n    def __init__(self):\n        self.x = 0\n\ndef main():\n    var p = Point()\n    print(p.x)\n```\n\n## After (builds)\n\n```mojo\nstruct Point:\n    var x: Int\n    def __init__(out self):\n        self.x = 0\n\ndef main():\n    var p = Point()\n    print(p.x)\n```\n"
comptime ERR_FIELD_UNINITIALIZED = "<!-- match: is uninitialized at the implicit return -->\n# A field the constructor does not set\n\nMojo says something like: `is uninitialized at the implicit return ...`\n\n## What it means\n\nEvery field of a struct must have a value when `__init__` ends; this one is never set.\n\n## How to fix it\n\n- Set every field in `__init__`: `self.n = 0`.\n- Or give the constructor an argument for it: `def __init__(out self, n: Int): self.n = n`.\n\n## Before (does not build)\n\n```mojo\nstruct Point:\n    var x: Int\n    var y: Int\n    def __init__(out self):\n        self.x = 0\n\ndef main():\n    var p = Point()\n    print(p.x)\n```\n\n## After (builds)\n\n```mojo\nstruct Point:\n    var x: Int\n    var y: Int\n    def __init__(out self):\n        self.x = 0\n        self.y = 0\n\ndef main():\n    var p = Point()\n    print(p.x, p.y)\n```\n"
comptime ERR_NO_ATTRIBUTE = "<!-- match: value has no attribute -->\n# No such field or method\n\nMojo says something like: `value has no attribute ...`\n\n## What it means\n\nThe type has no field or method of that name - a typo, a name from another language (Python's `.length`, Java's `.size()`), or a method of a different type.\n\n## How to fix it\n\n- Check the type's documentation: Ctrl-F1 on the name, or Alt-F1 to search (for example `@List` for List's methods).\n- Strings: `s.byte_length()` and `len(s.codepoints())`, not `len(s)`.\n\n## Before (does not build)\n\n```mojo\ndef main():\n    var l = List[Int]()\n    print(l.length)\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    var l = List[Int]()\n    print(len(l))\n```\n"
comptime ERR_INVALID_CALL = "<!-- match: invalid call to -->\n# Arguments that do not fit\n\nMojo says something like: `invalid call to ...`\n\n## What it means\n\nThe function exists, but not with these arguments: too many, too few, or of the wrong types. The notes below the error point at the declaration Mojo tried.\n\n## How to fix it\n\n- Compare with the declaration (F12 goes to it; the parameter tip shows it while you type).\n- Convert arguments of the wrong type, or pass them by name if the order is unclear.\n\n## Before (does not build)\n\n```mojo\ndef area(w: Int, h: Int) -> Int:\n    return w * h\n\ndef main():\n    print(area(2, 3, 4))\n```\n\n## After (builds)\n\n```mojo\ndef area(w: Int, h: Int) -> Int:\n    return w * h\n\ndef main():\n    print(area(2, 3))\n```\n"
comptime ERR_UNKNOWN_MODULE = "<!-- match: unable to locate module -->\n# A module that cannot be found\n\nMojo says something like: `unable to locate module ...`\n\n## What it means\n\nThe module in an import is not in the standard library, the project or the include folders.\n\n## How to fix it\n\n- Standard library modules start with `std.`: `from std.collections import List`.\n- Your own modules: the folder must be on the include path (`-I src`; TurboMojo's `tools.include_paths`).\n\n## Before (does not build)\n\n```mojo\nfrom collections import List\n\ndef main():\n    var l = List[Int]()\n    print(len(l))\n```\n\n## After (builds)\n\n```mojo\nfrom std.collections import List\n\ndef main():\n    var l = List[Int]()\n    print(len(l))\n```\n"
comptime ERR_STRING_LENGTH = "<!-- match: is not supported because Mojo strings are UTF-8 -->\n# The length of a string\n\nMojo says something like: `is not supported because Mojo strings are UTF-8 ...`\n\n## What it means\n\n`len()` of a string is not allowed: Mojo strings are UTF-8, so \"length\" could mean bytes, code points or characters as you see them.\n\n## How to fix it\n\n- `s.byte_length()`: bytes (what slicing with `[byte=...]` uses).\n- `len(s.codepoints())`: Unicode code points.\n\n## Before (does not build)\n\n```mojo\ndef main():\n    var s = String(\"héllo\")\n    print(len(s))\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    var s = String(\"héllo\")\n    print(s.byte_length(), len(s.codepoints()))\n```\n"
comptime ERR_INDENTATION = "<!-- match: body must not be empty || expressions must not appear at file scope -->\n# Code outside a block\n\nMojo says something like: `body must not be empty ...` or `expressions must not appear at file scope ...`\n\n## What it means\n\nAfter a line ending in `:` (def, if, for, struct...) Mojo expects an indented block; the lines below are not indented, or there are none. A line at the left edge is then outside every function, where only declarations may be - code there is \"at file scope\".\n\n## How to fix it\n\n- Indent the block (Tab indents the selected lines).\n- An empty block needs `pass`.\n- At the top of a file, constants are declared with `comptime` (`alias` was removed): `comptime SIZE = 8`.\n\n## Before (does not build)\n\n```mojo\ndef main():\nprint(1)\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    print(1)\n```\n"


def err_page_key(i: Int) -> String:
    """The file name (without .md) of explanation i."""
    if i == 0:
        return "unknown-name"
    elif i == 1:
        return "implicit-declaration"
    elif i == 2:
        return "fn-removed"
    elif i == 3:
        return "implicit-conversion"
    elif i == 4:
        return "implicit-copy"
    elif i == 5:
        return "uninitialized"
    elif i == 6:
        return "may-raise"
    elif i == 7:
        return "aliasing"
    elif i == 8:
        return "immutable"
    elif i == 9:
        return "init-out"
    elif i == 10:
        return "field-uninitialized"
    elif i == 11:
        return "no-attribute"
    elif i == 12:
        return "invalid-call"
    elif i == 13:
        return "unknown-module"
    elif i == 14:
        return "string-length"
    elif i == 15:
        return "indentation"
    return ""


def err_page_text(i: Int) -> String:
    """The text of explanation i."""
    if i == 0:
        return ERR_UNKNOWN_NAME
    elif i == 1:
        return ERR_IMPLICIT_DECLARATION
    elif i == 2:
        return ERR_FN_REMOVED
    elif i == 3:
        return ERR_IMPLICIT_CONVERSION
    elif i == 4:
        return ERR_IMPLICIT_COPY
    elif i == 5:
        return ERR_UNINITIALIZED
    elif i == 6:
        return ERR_MAY_RAISE
    elif i == 7:
        return ERR_ALIASING
    elif i == 8:
        return ERR_IMMUTABLE
    elif i == 9:
        return ERR_INIT_OUT
    elif i == 10:
        return ERR_FIELD_UNINITIALIZED
    elif i == 11:
        return ERR_NO_ATTRIBUTE
    elif i == 12:
        return ERR_INVALID_CALL
    elif i == 13:
        return ERR_UNKNOWN_MODULE
    elif i == 14:
        return ERR_STRING_LENGTH
    elif i == 15:
        return ERR_INDENTATION
    return ""
