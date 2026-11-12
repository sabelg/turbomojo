"""The exercises of Help > Exercises, made from help/exercises/ by
scripts/gen_exercises.py - do not edit here."""

comptime EX_COUNT = 8

comptime EX_01_VAR = "# Exercise 1 of 8: a new name needs var\n#\n# Mojo does not create a variable the first time you assign to it.\n# When it is right, it prints:\n#     count = 3\n#\n# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains\n# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.\n# expect: count = 3\n\n\ndef main():\n    count = 0\n    for i in range(3):\n        count += 1\n    print(\"count =\", count)\n"
comptime EX_02_DEF = "# Exercise 2 of 8: functions are def\n#\n# This was written for an older Mojo. Make it build with Mojo 1.x.\n# When it is right, it prints:\n#     Hello, Mojo!\n#\n# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains\n# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.\n# expect: Hello, Mojo!\n\n\nfn greet(name: String) -> String:\n    return \"Hello, \" + name + \"!\"\n\n\ndef main():\n    print(greet(\"Mojo\"))\n"
comptime EX_03_TYPES = "# Exercise 3 of 8: text is not a number\n#\n# Fix the first error, build again: a second one is waiting behind it. Reading\n# each new message is part of the exercise.\n# When it is right, it prints:\n#     twice = 42\n#\n# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains\n# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.\n# expect: twice = 42\n\n\ndef main():\n    var n: Int = \"21\"\n    print(\"twice =\", n * 2)\n"
comptime EX_04_COPY = "# Exercise 4 of 8: copying is asked for\n#\n# Lists are not copied behind your back. Keep both lists.\n# When it is right, it prints:\n#     3 3\n#\n# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains\n# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.\n# expect: 3 3\n\n\ndef main():\n    var a = List[Int]()\n    a.append(1)\n    a.append(2)\n    a.append(3)\n    var b = a\n    print(len(a), len(b))\n"
comptime EX_05_STRUCT = "# Exercise 5 of 8: a struct's constructor\n#\n# A constructor writes a new value.\n# When it is right, it prints:\n#     x = 4\n#\n# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains\n# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.\n# expect: x = 4\n\n\nstruct Point:\n    var x: Int\n\n    def __init__(self, x: Int):\n        self.x = x\n\n\ndef main():\n    var p = Point(4)\n    print(\"x =\", p.x)\n"
comptime EX_06_MUT = "# Exercise 6 of 8: changing self\n#\n# A method that changes its struct must say so.\n# When it is right, it prints:\n#     count = 2\n#\n# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains\n# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.\n# expect: count = 2\n\n\nstruct Counter:\n    var count: Int\n\n    def __init__(out self):\n        self.count = 0\n\n    def bump(self):\n        self.count += 1\n\n\ndef main():\n    var c = Counter()\n    c.bump()\n    c.bump()\n    print(\"count =\", c.count)\n"
comptime EX_07_IMPORT = "# Exercise 7 of 8: standard library imports\n#\n# The import names a module the way older Mojo did.\n# When it is right, it prints:\n#     first = 10\n#\n# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains\n# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.\n# expect: first = 10\n\n\nfrom collections import Dict\n\n\ndef main() raises:\n    var d = Dict[String, Int]()\n    d[\"first\"] = 10\n    print(\"first =\", d[\"first\"])\n"
comptime EX_08_LOGIC = "# Exercise 8 of 8: it builds, but is it right?\n#\n# This one builds and runs - and prints the wrong sum. Find out why.\n# When it is right, it prints:\n#     sum = 15\n#\n# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains\n# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.\n# expect: sum = 15\n\n\ndef main():\n    var total = 0\n    for i in range(1, 5):\n        total += i\n    print(\"sum =\", total)\n"


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
    return ""
