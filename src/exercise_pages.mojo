"""The exercises of Help > Exercises, made from help/exercises/ by
scripts/gen_exercises.py - do not edit here."""

comptime EX_COUNT = 13

comptime EX_01_VAR = "# Exercise 1 of 13: a new name needs var\n#\n# Mojo does not create a variable the first time you assign to it.\n# When it is right, it prints:\n#     count = 3\n#\n# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains\n# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.\n# expect: count = 3\n\n\ndef main():\n    count = 0\n    for i in range(3):\n        count += 1\n    print(\"count =\", count)\n"
comptime EX_02_DEF = "# Exercise 2 of 13: functions are def\n#\n# This was written for an older Mojo. Make it build with Mojo 1.x.\n# When it is right, it prints:\n#     Hello, Mojo!\n#\n# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains\n# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.\n# expect: Hello, Mojo!\n\n\nfn greet(name: String) -> String:\n    return \"Hello, \" + name + \"!\"\n\n\ndef main():\n    print(greet(\"Mojo\"))\n"
comptime EX_03_TYPES = "# Exercise 3 of 13: text is not a number\n#\n# Fix the first error, build again: a second one is waiting behind it. Reading\n# each new message is part of the exercise.\n# When it is right, it prints:\n#     twice = 42\n#\n# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains\n# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.\n# expect: twice = 42\n\n\ndef main():\n    var n: Int = \"21\"\n    print(\"twice =\", n * 2)\n"
comptime EX_04_COPY = "# Exercise 4 of 13: copying is asked for\n#\n# Lists are not copied behind your back. Keep both lists.\n# When it is right, it prints:\n#     3 3\n#\n# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains\n# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.\n# expect: 3 3\n\n\ndef main():\n    var a = List[Int]()\n    a.append(1)\n    a.append(2)\n    a.append(3)\n    var b = a\n    print(len(a), len(b))\n"
comptime EX_05_STRUCT = "# Exercise 5 of 13: a struct's constructor\n#\n# A constructor writes a new value.\n# When it is right, it prints:\n#     x = 4\n#\n# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains\n# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.\n# expect: x = 4\n\n\nstruct Point:\n    var x: Int\n\n    def __init__(self, x: Int):\n        self.x = x\n\n\ndef main():\n    var p = Point(4)\n    print(\"x =\", p.x)\n"
comptime EX_06_MUT = "# Exercise 6 of 13: changing self\n#\n# A method that changes its struct must say so.\n# When it is right, it prints:\n#     count = 2\n#\n# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains\n# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.\n# expect: count = 2\n\n\nstruct Counter:\n    var count: Int\n\n    def __init__(out self):\n        self.count = 0\n\n    def bump(self):\n        self.count += 1\n\n\ndef main():\n    var c = Counter()\n    c.bump()\n    c.bump()\n    print(\"count =\", c.count)\n"
comptime EX_07_IMPORT = "# Exercise 7 of 13: standard library imports\n#\n# The import names a module the way older Mojo did.\n# When it is right, it prints:\n#     first = 10\n#\n# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains\n# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.\n# expect: first = 10\n\n\nfrom collections import Dict\n\n\ndef main() raises:\n    var d = Dict[String, Int]()\n    d[\"first\"] = 10\n    print(\"first =\", d[\"first\"])\n"
comptime EX_08_LOGIC = "# Exercise 8 of 13: it builds, but is it right?\n#\n# This one builds and runs - and prints the wrong sum. Find out why.\n# When it is right, it prints:\n#     sum = 15\n#\n# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains\n# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.\n# expect: sum = 15\n\n\ndef main():\n    var total = 0\n    for i in range(1, 5):\n        total += i\n    print(\"sum =\", total)\n"
comptime EX_09_COMPTIME = "# Exercise 9 of 13: compile-time constants and loops\n#\n# Older Mojo used `alias` and `@parameter` for compile-time work; Mojo 1.x uses `comptime`.\n# When it is right, it prints:\n#     squares = 14\n#\n# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains\n# the message.\n# expect: squares = 14\n\n\ndef main():\n    alias LANES = 4\n    var total = 0\n    @parameter\n    for i in range(LANES):\n        total += i * i\n    print(\"squares =\", total)\n"
comptime EX_10_FIELDWISE = "# Exercise 10 of 13: fieldwise structs and traits\n#\n# `@value` was replaced by `@fieldwise_init` and explicit trait conformance in parentheses.\n# When it is right, it prints:\n#     vec = 3 4\n#\n# Check it with Help > Exercise done? ({key}). F1 on the decorator explains what replaced it.\n# expect: vec = 3 4\n\n\n@value\nstruct Vec2:\n    var x: Int\n    var y: Int\n\n\ndef main():\n    var a = Vec2(3, 4)\n    var b = a.copy()\n    print(\"vec =\", b.x, b.y)\n"
comptime EX_11_UTF8 = "# Exercise 11 of 13: UTF-8 string bytes and slices\n#\n# Mojo strings are UTF-8, so indexing and length ask you whether you mean bytes or code points.\n# When it is right, it prints:\n#     first = M bytes = 5\n#\n# Check it with Help > Exercise done? ({key}). F1 on each error line explains how UTF-8 strings work.\n# expect: first = M bytes = 5\n\n\ndef main():\n    var s = String(\"Mojo!\")\n    print(\"first =\", s[0], \"bytes =\", len(s))\n"
comptime EX_12_TRAITS = "# Exercise 12 of 13: struct parameters and Writable\n#\n# Inside a parametric struct, parameters belong to `Self` (`Self.T`), and passing a struct\n# to a `Writable` function requires `Writable` in the struct's trait list.\n# When it is right, it prints:\n#     box(99)\n#\n# Check it with Help > Exercise done? ({key}). Fix the first error, then F1 on the next!\n# expect: box(99)\n\n\n@fieldwise_init\nstruct Box[T: Copyable & Writable & Deinitable](Copyable):\n    var item: T\n\n    def write_to(self, mut writer: Some[Writer]):\n        writer.write(\"box(\", self.item, \")\")\n\n\ndef show[U: Writable](x: U):\n    print(x)\n\n\ndef main():\n    var b = Box[Int](99)\n    show(b)\n"
comptime EX_13_SIMD = "# Exercise 13 of 13: SIMD vectors\n#\n# `SIMD[DType.int32, 4]` adds four lanes at once, then reduces them with `reduce_add()`.\n# Look up `SIMD` with Ctrl-F1 or Alt-F1 (`@SIMD`) to see its reduction methods!\n# When it is right, it prints:\n#     total = 110\n#\n# Check it with Help > Exercise done? ({key}).\n# expect: total = 110\n\n\ndef main():\n    var a = SIMD[DType.int32, 4](1, 2, 3, 4)\n    var b = SIMD[DType.int32, 4](10, 20, 30, 40)\n    print(\"total =\", (a + b).total())\n"


def ex_key(i: Int) -> String:
    if i == 0:
        return "01-var"
    elif i == 1:
        return "02-def"
    elif i == 2:
        return "03-types"
    elif i == 3:
        return "04-copy"
    elif i == 4:
        return "05-struct"
    elif i == 5:
        return "06-mut"
    elif i == 6:
        return "07-import"
    elif i == 7:
        return "08-logic"
    elif i == 8:
        return "09-comptime"
    elif i == 9:
        return "10-fieldwise"
    elif i == 10:
        return "11-utf8"
    elif i == 11:
        return "12-traits"
    elif i == 12:
        return "13-simd"
    return ""


def ex_text(i: Int) -> String:
    if i == 0:
        return EX_01_VAR
    elif i == 1:
        return EX_02_DEF
    elif i == 2:
        return EX_03_TYPES
    elif i == 3:
        return EX_04_COPY
    elif i == 4:
        return EX_05_STRUCT
    elif i == 5:
        return EX_06_MUT
    elif i == 6:
        return EX_07_IMPORT
    elif i == 7:
        return EX_08_LOGIC
    elif i == 8:
        return EX_09_COMPTIME
    elif i == 9:
        return EX_10_FIELDWISE
    elif i == 10:
        return EX_11_UTF8
    elif i == 11:
        return EX_12_TRAITS
    elif i == 12:
        return EX_13_SIMD
    return ""
