# Exercise 7 of 8: standard library imports
#
# The import names a module the way older Mojo did.
# When it is right, it prints:
#     first = 10
#
# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains
# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.
# expect: first = 10


from std.collections import Dict


def main() raises:
    var d = Dict[String, Int]()
    d["first"] = 10
    print("first =", d["first"])
