"""The explanations of Mojo error messages, made from help/errors/ by
scripts/gen_errhelp.py - do not edit here."""

comptime ERR_PAGE_COUNT = 27

comptime ERR_VALUE_REMOVED = "<!-- match: use of unknown declaration 'value' -->\n# `@value` was replaced by `@fieldwise_init`\n\nMojo says something like: `use of unknown declaration 'value'`\n\n## What it means\n\nThe `@value` decorator from older Mojo versions was removed in Mojo 1.x. Structs now ask explicitly for a fieldwise constructor (`@fieldwise_init`) and for the traits they conform to (`Copyable`, `Movable`, `Writable`, `ImplicitlyCopyable`).\n\n## How to fix it\n\n- Replace `@value` with `@fieldwise_init`.\n- List the traits the struct needs in parentheses: `struct Pair(Copyable, Movable):` (add `ImplicitlyCopyable` for small plain-value structs that may be copied without `.copy()`).\n\n## Before (does not build)\n\n```mojo\n@value\nstruct Pair:\n    var a: Int\n    var b: Int\n\ndef main():\n    var p = Pair(1, 2)\n    print(p.a, p.b)\n```\n\n## After (builds)\n\n```mojo\n@fieldwise_init\nstruct Pair(Copyable, Movable):\n    var a: Int\n    var b: Int\n\ndef main():\n    var p = Pair(1, 2)\n    print(p.a, p.b)\n```\n"
comptime ERR_LET_REMOVED = "<!-- match: use of unknown declaration 'let' -->\n# `let` was removed: declare variables with `var`\n\nMojo says something like: `use of unknown declaration 'let'`\n\n## What it means\n\n`let` from early Mojo versions was removed. Every local variable is declared with `var` (the compiler tracks whether a variable is mutated and optimizes immutable bindings automatically).\n\n## How to fix it\n\n- Replace `let x = ...` with `var x = ...`.\n- For compile-time constants, use `comptime X = ...`.\n\n## Before (does not build)\n\n```mojo\ndef main():\n    let x = 5\n    print(x)\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    var x = 5\n    print(x)\n```\n"
comptime ERR_ALIAS_REMOVED = "<!-- match: use of unknown declaration 'alias' -->\n# `alias` was replaced by `comptime`\n\nMojo says something like: `use of unknown declaration 'alias'`\n\n## What it means\n\n`alias` from older Mojo versions was removed in Mojo 1.x. Compile-time constants and type aliases now use `comptime`.\n\n## How to fix it\n\n- Replace `alias N = ...` with `comptime N = ...`.\n- Compile-time branches, loops and assertions also use `comptime`: `comptime if ...`, `comptime for ...`, `comptime assert ...`.\n\n## Before (does not build)\n\n```mojo\ndef main():\n    alias N = 4\n    print(N)\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    comptime N = 4\n    print(N)\n```\n"
comptime ERR_UNKNOWN_NAME = "<!-- match: use of unknown declaration -->\n# Unknown name\n\nMojo says something like: `use of unknown declaration ...`\n\n## What it means\n\nMojo found a name it has no definition for: a variable, function or type that is not declared in this file, not imported, or spelled differently.\n\n## How to fix it\n\n- Check the spelling (Mojo names are case-sensitive).\n- Declare a variable with `var` before using it.\n- Import what comes from elsewhere: `from std.collections import List` (Mojo 1.x imports need the `std.` prefix).\n\n## Before (does not build)\n\n```mojo\ndef main():\n    print(totl)\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    var total = 3\n    print(total)\n```\n"
comptime ERR_IMPLICIT_DECLARATION = "<!-- match: implicit declaration of -->\n# A new name needs `var`\n\nMojo says something like: `implicit declaration of ...`\n\n## What it means\n\nUnlike Python, Mojo does not create a variable the first time you assign to it: a new name is declared with `var`.\n\n## How to fix it\n\n- Write `var x = 1` the first time; later assignments are `x = 2`.\n- Inside a struct, fields are declared with `var` in the struct body.\n\n## Coming from Python\n\nThis is a Python habit. The page *Coming from Python* (Help > Coming from Python, or\n**P** in this window) lists the other differences.\n\n## Before (does not build)\n\n```mojo\ndef main():\n    count = 1\n    print(count)\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    var count = 1\n    count = count + 1\n    print(count)\n```\n"
comptime ERR_FN_REMOVED = "<!-- match: 'fn' has been removed -->\n# `fn` no longer exists\n\nMojo says something like: `'fn' has been removed ...`\n\n## What it means\n\nMojo 1.x has one kind of function: `def`. A `def` does not raise unless it is marked `raises`, which is what `fn` used to mean.\n\n## How to fix it\n\n- Replace `fn` with `def`.\n- If the function can raise an error, add `raises`: `def load(path: String) raises -> String:`.\n\n## Coming from Python\n\nThis is a Python habit. The page *Coming from Python* (Help > Coming from Python, or\n**P** in this window) lists the other differences.\n\n## Before (does not build)\n\n```mojo\nfn main():\n    print(1)\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    print(1)\n```\n"
comptime ERR_PARAMETER_REMOVED = "<!-- match: statement does not support decorators -->\n# `@parameter` was replaced by `comptime`\n\nMojo says something like: `'if' statement does not support decorators; remove the decorator` (or `'for' statement does not support decorators`)\n\n## What it means\n\nOlder Mojo code used `@parameter` above `if` or `for` to evaluate branches and unroll loops at compile time. In Mojo 1.x, `@parameter` on statements was removed in favor of `comptime if` and `comptime for`.\n\n## How to fix it\n\n- Replace `@parameter` + `if cond:` with `comptime if cond:`.\n- Replace `@parameter` + `for i in range(N):` with `comptime for i in range(N):`.\n\n## Before (does not build)\n\n```mojo\ndef main():\n    @parameter\n    if True:\n        print(\"unrolled at compile time\")\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    comptime if True:\n        print(\"unrolled at compile time\")\n```\n"
comptime ERR_TRAIT_CONFORMANCE = "<!-- match: does not conform to trait -->\n# A type does not implement the required trait\n\nMojo says something like: `... argument type '...' does not conform to trait '...'`\n\n## What it means\n\nA generic function or container requires a trait (`Copyable`, `Movable`, `Writable`, `Equatable`, `Hashable`), and the struct passed to it has not declared (or implemented) that trait.\n\n## How to fix it\n\n- Add the trait to the struct header: `struct Tag(Copyable, Movable, Writable):`.\n- For `Copyable`, `Movable`, `Equatable`, `Hashable`, and `Writable`, Mojo 1.2 can synthesize the trait methods automatically when every field conforms to that trait; otherwise implement the required method (for example `def write_to(self, mut writer: Some[Writer]):` for `Writable`).\n\n## Before (does not build)\n\n```mojo\n@fieldwise_init\nstruct Tag(Copyable, Movable):\n    var id: Int\n\ndef show[T: Writable](x: T):\n    print(x)\n\ndef main():\n    var t = Tag(7)\n    show(t)\n```\n\n## After (builds)\n\n```mojo\n@fieldwise_init\nstruct Tag(Copyable, Movable, Writable):\n    var id: Int\n\ndef show[T: Writable](x: T):\n    print(x)\n\ndef main():\n    var t = Tag(7)\n    show(t)\n```\n"
comptime ERR_STRING_SLICE = "<!-- match: StringSpan[ || StringSlice[ -->\n# A string slice or span where an owned `String` is needed\n\nMojo says something like: `... cannot be converted from 'StringSpan[...]' to 'String'`\n\n## What it means\n\nByte slicing (`name[byte=0:2]`) and zero-copy views return a borrowed `StringSpan` or `StringSlice` pointing into existing UTF-8 bytes rather than allocating a new `String`. When a function or struct field requires an owned `String`, you convert the view explicitly.\n\n## How to fix it\n\n- Wrap the slice in `String(...)` to allocate an owned `String`: `String(name[byte=0:2])`.\n- Or, if the function only reads the text, let it accept `StringSlice` so callers need not copy.\n\n## Coming from Python\n\nThis is a Python habit. The page *Coming from Python* (Help > Coming from Python, or\n**P** in this window) lists the other differences.\n\n## Before (does not build)\n\n```mojo\ndef greet(s: String):\n    print(\"hi\", s)\n\ndef main():\n    var name = String(\"Ada\")\n    greet(name[byte=0:2])\n```\n\n## After (builds)\n\n```mojo\ndef greet(s: String):\n    print(\"hi\", s)\n\ndef main():\n    var name = String(\"Ada\")\n    greet(String(name[byte=0:2]))\n```\n"
comptime ERR_IMPLICIT_CONVERSION = "<!-- match: cannot implicitly convert -->\n# A value of the wrong type\n\nMojo says something like: `cannot implicitly convert ...`\n\n## What it means\n\nA value of one type was used where another type is needed, and Mojo will not convert between them by itself (for example text where a number is expected).\n\n## How to fix it\n\n- Convert it yourself: `Int(\"12\")` or `atol(\"12\")` parses text (and raises if it is not a number); `String(42)` makes text of a number.\n- Or change the declared type, if the value is right and the type was wrong.\n\n## Before (does not build)\n\n```mojo\ndef main():\n    var n: Int = \"12\"\n    print(n)\n```\n\n## After (builds)\n\n```mojo\ndef main() raises:\n    var n: Int = Int(\"12\")\n    print(n)\n```\n"
comptime ERR_IMPLICIT_COPY = "<!-- match: cannot be implicitly copied -->\n# Copying must be asked for\n\nMojo says something like: `cannot be implicitly copied ...`\n\n## What it means\n\nSome types (List, String's larger cousins, your own structs) are not copied behind your back: `var b = a` would copy the whole list, so Mojo wants you to say what you mean.\n\n## How to fix it\n\n- `a.copy()` makes a copy and keeps `a`.\n- `a^` moves `a` into the new place; `a` cannot be used afterwards.\n- A struct can be made copyable with `(Copyable, Movable)` and copied with `.copy()`.\n\n## Coming from Python\n\nThis is a Python habit. The page *Coming from Python* (Help > Coming from Python, or\n**P** in this window) lists the other differences.\n\n## Before (does not build)\n\n```mojo\ndef main():\n    var a = List[Int]()\n    a.append(1)\n    var b = a\n    print(len(b), len(a))\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    var a = List[Int]()\n    a.append(1)\n    var b = a.copy()\n    print(len(b), len(a))\n```\n"
comptime ERR_UNINITIALIZED = "<!-- match: use of uninitialized value -->\n# A value used before it has one\n\nMojo says something like: `use of uninitialized value ...`\n\n## What it means\n\nThe variable was declared but never given a value on this path - or it was moved away with `^` and is empty now.\n\n## How to fix it\n\n- Give it a value where it is declared: `var x: Int = 0`.\n- Make sure every branch of an `if` sets it.\n- After `b = a^`, use `b`, not `a` (or copy with `a.copy()` instead of moving).\n\n## Before (does not build)\n\n```mojo\ndef main():\n    var x: Int\n    print(x)\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    var x: Int = 0\n    print(x)\n```\n"
comptime ERR_MAY_RAISE = "<!-- match: cannot call function that may raise -->\n# A call that can raise, in a function that cannot\n\nMojo says something like: `cannot call function that may raise ...`\n\n## What it means\n\nThe function you call is marked `raises` (it can fail with an Error), but the function calling it is not, so the error would have nowhere to go.\n\n## How to fix it\n\n- Mark the caller `raises` too: `def main() raises:`.\n- Or handle the error where it happens: `try: ... except e: print(e)`.\n\n## Before (does not build)\n\n```mojo\ndef parse() raises -> Int:\n    return atol(\"7\")\n\ndef main():\n    print(parse())\n```\n\n## After (builds)\n\n```mojo\ndef parse() raises -> Int:\n    return atol(\"7\")\n\ndef main():\n    try:\n        print(parse())\n    except e:\n        print(\"could not parse:\", e)\n```\n"
comptime ERR_ALIASING = "<!-- match: aliasing values passed mutably -->\n# Two arguments that are the same thing\n\nMojo says something like: `aliasing values passed mutably ...`\n\n## What it means\n\nYou pass something to a method that may change it (`mut self`) and, in the same call, a part of it to read. Mojo forbids this: the method could change what it is reading.\n\n## How to fix it\n\n- Copy the part to a local first: `var t = b.s` then `b.put(t)` (for List and other non-copyable values: `b.s.copy()`).\n\n## Before (does not build)\n\n```mojo\nstruct Box:\n    var s: String\n    def __init__(out self):\n        self.s = \"a\"\n    def put(mut self, t: String):\n        self.s = t\n\ndef main():\n    var b = Box()\n    b.put(b.s)\n```\n\n## After (builds)\n\n```mojo\nstruct Box:\n    var s: String\n    def __init__(out self):\n        self.s = \"a\"\n    def put(mut self, t: String):\n        self.s = t\n\ndef main():\n    var b = Box()\n    var t = b.s\n    b.put(t)\n    print(b.s)\n```\n"
comptime ERR_IMMUTABLE = "<!-- match: expression must be mutable -->\n# Changing something that may not be changed\n\nMojo says something like: `expression must be mutable ...`\n\n## What it means\n\nThe value you assign to or change in place is read-only here - most often `self` in a method declared without `mut`, or an argument (arguments are read-only by default).\n\n## How to fix it\n\n- Declare the method `def bump(mut self):` to change fields.\n- For an argument the function may change, write `mut x: Int`; to have your own copy, `var x: Int`.\n\n## Coming from Python\n\nThis is a Python habit. The page *Coming from Python* (Help > Coming from Python, or\n**P** in this window) lists the other differences.\n\n## Before (does not build)\n\n```mojo\nstruct Counter:\n    var n: Int\n    def __init__(out self):\n        self.n = 0\n    def bump(self):\n        self.n += 1\n\ndef main():\n    var c = Counter()\n    c.bump()\n```\n\n## After (builds)\n\n```mojo\nstruct Counter:\n    var n: Int\n    def __init__(out self):\n        self.n = 0\n    def bump(mut self):\n        self.n += 1\n\ndef main():\n    var c = Counter()\n    c.bump()\n    print(c.n)\n```\n"
comptime ERR_INIT_OUT = "<!-- match: __init__ method must return Self type with 'out' -->\n# `__init__` takes `out self`\n\nMojo says something like: `__init__ method must return Self type with 'out' ...`\n\n## What it means\n\nA constructor makes a new value: its `self` is written to, not read, so it is declared `out self`.\n\n## How to fix it\n\n- Write `def __init__(out self):`; every constructor takes `out self`.\n\n## Coming from Python\n\nThis is a Python habit. The page *Coming from Python* (Help > Coming from Python, or\n**P** in this window) lists the other differences.\n\n## Before (does not build)\n\n```mojo\nstruct Point:\n    var x: Int\n    def __init__(self):\n        self.x = 0\n\ndef main():\n    var p = Point()\n    print(p.x)\n```\n\n## After (builds)\n\n```mojo\nstruct Point:\n    var x: Int\n    def __init__(out self):\n        self.x = 0\n\ndef main():\n    var p = Point()\n    print(p.x)\n```\n"
comptime ERR_FIELD_UNINITIALIZED = "<!-- match: is uninitialized at the implicit return -->\n# A field the constructor does not set\n\nMojo says something like: `is uninitialized at the implicit return ...`\n\n## What it means\n\nEvery field of a struct must have a value when `__init__` ends; this one is never set.\n\n## How to fix it\n\n- Set every field in `__init__`: `self.n = 0`.\n- Or give the constructor an argument for it: `def __init__(out self, n: Int): self.n = n`.\n\n## Before (does not build)\n\n```mojo\nstruct Point:\n    var x: Int\n    var y: Int\n    def __init__(out self):\n        self.x = 0\n\ndef main():\n    var p = Point()\n    print(p.x)\n```\n\n## After (builds)\n\n```mojo\nstruct Point:\n    var x: Int\n    var y: Int\n    def __init__(out self):\n        self.x = 0\n        self.y = 0\n\ndef main():\n    var p = Point()\n    print(p.x, p.y)\n```\n"
comptime ERR_SELF_PARAM = "<!-- match: unqualified access to struct parameter -->\n# Struct parameters are written `Self.T` inside the struct\n\nMojo says something like: `unqualified access to struct parameter 'T'; use 'Self.T' instead`\n\n## What it means\n\nInside a parametric `struct Box[T: ...]:`, the parameter `T` belongs to `Self`. Writing bare `T` in fields, method signatures, or method bodies is rejected so struct parameters are never confused with outer types or method parameters.\n\n## How to fix it\n\n- Prefix every struct parameter inside the struct body with `Self.`: `Self.T`, `Self.N`, `Self.origin`.\n\n## Before (does not build)\n\n```mojo\n@fieldwise_init\nstruct Box[T: Copyable & Deinitable](Copyable):\n    var item: T\n\ndef main():\n    var b = Box[Int](42)\n    print(b.item)\n```\n\n## After (builds)\n\n```mojo\n@fieldwise_init\nstruct Box[T: Copyable & Deinitable](Copyable):\n    var item: Self.T\n\ndef main():\n    var b = Box[Int](42)\n    print(b.item)\n```\n"
comptime ERR_NO_ATTRIBUTE = "<!-- match: value has no attribute -->\n# No such field or method\n\nMojo says something like: `value has no attribute ...`\n\n## What it means\n\nThe type has no field or method of that name - a typo, a name from another language (Python's `.length`, Java's `.size()`), or a method of a different type.\n\n## How to fix it\n\n- Check the type's documentation: Ctrl-F1 on the name, or Alt-F1 to search (for example `@List` for List's methods).\n- Strings: `s.byte_length()` and `len(s.codepoints())`, not `len(s)`.\n\n## Before (does not build)\n\n```mojo\ndef main():\n    var l = List[Int]()\n    print(l.length)\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    var l = List[Int]()\n    print(len(l))\n```\n"
comptime ERR_LIST_INIT = "<!-- match: no matching function in initialization -->\n# Constructor arguments do not match any `__init__`\n\nMojo says something like: `no matching function in initialization`\n\n## What it means\n\nThe type has no constructor accepting those arguments. A frequent case in Mojo 1.x is `List[Int](1, 2, 3)` — `List`'s variadic element constructor was removed in favor of list literals `[1, 2, 3]`, `List[Int](capacity=...)`, or `List[Int](length=..., fill=...)`.\n\n## How to fix it\n\n- For a `List` with initial elements, write a list literal: `var nums = [1, 2, 3]` (or `var nums: List[Int] = [1, 2, 3]`).\n- For your own structs, add `@fieldwise_init` or check the parameter types of `def __init__(out self, ...):` with **Ctrl-F1** / **F12**.\n\n## Before (does not build)\n\n```mojo\nfrom std.collections import List\n\ndef main():\n    var nums = List[Int](1, 2, 3)\n    print(len(nums))\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    var nums = [1, 2, 3]\n    print(len(nums))\n```\n"
comptime ERR_INVALID_CALL = "<!-- match: invalid call to -->\n# Arguments that do not fit\n\nMojo says something like: `invalid call to ...`\n\n## What it means\n\nThe function exists, but not with these arguments: too many, too few, or of the wrong types. The notes below the error point at the declaration Mojo tried.\n\n## How to fix it\n\n- Compare with the declaration (F12 goes to it; the parameter tip shows it while you type).\n- Convert arguments of the wrong type, or pass them by name if the order is unclear.\n\n## Before (does not build)\n\n```mojo\ndef area(w: Int, h: Int) -> Int:\n    return w * h\n\ndef main():\n    print(area(2, 3, 4))\n```\n\n## After (builds)\n\n```mojo\ndef area(w: Int, h: Int) -> Int:\n    return w * h\n\ndef main():\n    print(area(2, 3))\n```\n"
comptime ERR_UNKNOWN_MODULE = "<!-- match: unable to locate module -->\n# A module that cannot be found\n\nMojo says something like: `unable to locate module ...`\n\n## What it means\n\nThe module in an import is not in the standard library, the project or the include folders.\n\n## How to fix it\n\n- Standard library modules start with `std.`: `from std.collections import List`.\n- Your own modules: the folder must be on the include path (`-I src`; TurboMojo's `tools.include_paths`).\n\n## Coming from Python\n\nThis is a Python habit. The page *Coming from Python* (Help > Coming from Python, or\n**P** in this window) lists the other differences.\n\n## Before (does not build)\n\n```mojo\nfrom collections import List\n\ndef main():\n    var l = List[Int]()\n    print(len(l))\n```\n\n## After (builds)\n\n```mojo\nfrom std.collections import List\n\ndef main():\n    var l = List[Int]()\n    print(len(l))\n```\n"
comptime ERR_STRING_LENGTH = "<!-- match: is not supported because Mojo strings are UTF-8 -->\n# The length of a string\n\nMojo says something like: `is not supported because Mojo strings are UTF-8 ...`\n\n## What it means\n\n`len()` of a string is not allowed: Mojo strings are UTF-8, so \"length\" could mean bytes, code points or characters as you see them.\n\n## How to fix it\n\n- `s.byte_length()`: bytes (what slicing with `[byte=...]` uses).\n- `len(s.codepoints())`: Unicode code points.\n\n## Coming from Python\n\nThis is a Python habit. The page *Coming from Python* (Help > Coming from Python, or\n**P** in this window) lists the other differences.\n\n## Before (does not build)\n\n```mojo\ndef main():\n    var s = String(\"héllo\")\n    print(len(s))\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    var s = String(\"héllo\")\n    print(s.byte_length(), len(s.codepoints()))\n```\n"
comptime ERR_STRING_INDEX = "<!-- match: String does not support direct positional indexing -->\n# Indexing a UTF-8 `String` needs an explicit unit\n\nMojo says something like: `String does not support direct positional indexing like s[i] because Mojo strings are UTF-8 encoded ...`\n\n## What it means\n\nIn UTF-8 text, a single visible character can take one to four bytes, so `s[i]` is ambiguous between a byte, a Unicode code point, and a grapheme cluster. Mojo asks you to name which unit you want.\n\n## How to fix it\n\n- Use `s[byte=i]` (or `s[byte=a:b]`) for UTF-8 byte offsets (fast O(1) indexing, paired with `s.byte_length()`).\n- Iterate over `s.codepoint_slices()` or `s.codepoints()` when stepping through Unicode characters.\n\n## Coming from Python\n\nThis is a Python habit. The page *Coming from Python* (Help > Coming from Python, or\n**P** in this window) lists the other differences.\n\n## Before (does not build)\n\n```mojo\ndef main():\n    var s = String(\"mojo\")\n    print(s[0])\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    var s = String(\"mojo\")\n    print(s[byte=0])\n```\n"
comptime ERR_COMPTIME_ASSERT = "<!-- match: 'comptime assert' must be inside a function -->\n# `comptime assert` belongs inside a function body\n\nMojo says something like: `'comptime assert' must be inside a function; move this into a function body`\n\n## What it means\n\nUnlike `comptime N = 4`, a `comptime assert` statement is checked when a function or constructor is instantiated, so Mojo does not allow it at file or struct scope.\n\n## How to fix it\n\n- Move `comptime assert cond, \"message\"` inside `def __init__(...)`, `def main()`, or the function that relies on the invariant.\n\n## Before (does not build)\n\n```mojo\ncomptime N = 4\ncomptime assert N > 0, \"N must be positive\"\n\ndef main():\n    print(N)\n```\n\n## After (builds)\n\n```mojo\ncomptime N = 4\n\ndef main():\n    comptime assert N > 0, \"N must be positive\"\n    print(N)\n```\n"
comptime ERR_INDENTATION = "<!-- match: body must not be empty || expressions must not appear at file scope -->\n# Code outside a block\n\nMojo says something like: `body must not be empty ...` or `expressions must not appear at file scope ...`\n\n## What it means\n\nAfter a line ending in `:` (def, if, for, struct...) Mojo expects an indented block; the lines below are not indented, or there are none. A line at the left edge is then outside every function, where only declarations may be - code there is \"at file scope\".\n\n## How to fix it\n\n- Indent the block (Tab indents the selected lines).\n- An empty block needs `pass`.\n- At the top of a file, constants are declared with `comptime` (`alias` was removed): `comptime SIZE = 8`.\n\n## Before (does not build)\n\n```mojo\ndef main():\nprint(1)\n```\n\n## After (builds)\n\n```mojo\ndef main():\n    print(1)\n```\n"
comptime ERR_CLASS = "<!-- match: classes are not supported yet -->\n# No classes: a struct\n\nMojo says something like: `classes are not supported yet ...`\n\n## What it means\n\nMojo has no `class` (yet). Its types are `struct`s: their fields are declared with\n`var`, their constructor takes `out self`, and in place of inheritance a struct\nimplements traits.\n\n## How to fix it\n\n- Write `struct` for `class`, declare each field with `var` and its type.\n- The constructor is `def __init__(out self, ...)`; a method that changes the struct\n  takes `mut self`.\n\n## Coming from Python\n\nThis is a Python habit. The page *Coming from Python* (Help > Coming from Python, or\n**P** in this window) lists the other differences.\n\n## Before (does not build)\n\n```mojo\nclass Point:\n    var x: Int\n\n    def __init__(out self, x: Int):\n        self.x = x\n\n\ndef main():\n    var p = Point(3)\n    print(p.x)\n```\n\n## After (builds)\n\n```mojo\nstruct Point:\n    var x: Int\n\n    def __init__(out self, x: Int):\n        self.x = x\n\n\ndef main():\n    var p = Point(3)\n    print(p.x)\n```\n"


def err_page_key(i: Int) -> String:
    """The file name (without .md) of explanation i."""
    if i == 0:
        return "value-removed"
    elif i == 1:
        return "let-removed"
    elif i == 2:
        return "alias-removed"
    elif i == 3:
        return "unknown-name"
    elif i == 4:
        return "implicit-declaration"
    elif i == 5:
        return "fn-removed"
    elif i == 6:
        return "parameter-removed"
    elif i == 7:
        return "trait-conformance"
    elif i == 8:
        return "string-slice"
    elif i == 9:
        return "implicit-conversion"
    elif i == 10:
        return "implicit-copy"
    elif i == 11:
        return "uninitialized"
    elif i == 12:
        return "may-raise"
    elif i == 13:
        return "aliasing"
    elif i == 14:
        return "immutable"
    elif i == 15:
        return "init-out"
    elif i == 16:
        return "field-uninitialized"
    elif i == 17:
        return "self-param"
    elif i == 18:
        return "no-attribute"
    elif i == 19:
        return "list-init"
    elif i == 20:
        return "invalid-call"
    elif i == 21:
        return "unknown-module"
    elif i == 22:
        return "string-length"
    elif i == 23:
        return "string-index"
    elif i == 24:
        return "comptime-assert"
    elif i == 25:
        return "indentation"
    elif i == 26:
        return "class"
    return ""


def err_page_text(i: Int) -> String:
    """The text of explanation i."""
    if i == 0:
        return ERR_VALUE_REMOVED
    elif i == 1:
        return ERR_LET_REMOVED
    elif i == 2:
        return ERR_ALIAS_REMOVED
    elif i == 3:
        return ERR_UNKNOWN_NAME
    elif i == 4:
        return ERR_IMPLICIT_DECLARATION
    elif i == 5:
        return ERR_FN_REMOVED
    elif i == 6:
        return ERR_PARAMETER_REMOVED
    elif i == 7:
        return ERR_TRAIT_CONFORMANCE
    elif i == 8:
        return ERR_STRING_SLICE
    elif i == 9:
        return ERR_IMPLICIT_CONVERSION
    elif i == 10:
        return ERR_IMPLICIT_COPY
    elif i == 11:
        return ERR_UNINITIALIZED
    elif i == 12:
        return ERR_MAY_RAISE
    elif i == 13:
        return ERR_ALIASING
    elif i == 14:
        return ERR_IMMUTABLE
    elif i == 15:
        return ERR_INIT_OUT
    elif i == 16:
        return ERR_FIELD_UNINITIALIZED
    elif i == 17:
        return ERR_SELF_PARAM
    elif i == 18:
        return ERR_NO_ATTRIBUTE
    elif i == 19:
        return ERR_LIST_INIT
    elif i == 20:
        return ERR_INVALID_CALL
    elif i == 21:
        return ERR_UNKNOWN_MODULE
    elif i == 22:
        return ERR_STRING_LENGTH
    elif i == 23:
        return ERR_STRING_INDEX
    elif i == 24:
        return ERR_COMPTIME_ASSERT
    elif i == 25:
        return ERR_INDENTATION
    elif i == 26:
        return ERR_CLASS
    return ""
