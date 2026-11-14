# Exercise 10 of 13: fieldwise structs and traits
#
# `@value` was replaced by `@fieldwise_init` and explicit trait conformance in parentheses.
# When it is right, it prints:
#     vec = 3 4
#
# Check it with Help > Exercise done? ({key}). F1 on the decorator explains what replaced it.
# expect: vec = 3 4


@value
struct Vec2:
    var x: Int
    var y: Int


def main():
    var a = Vec2(3, 4)
    var b = a.copy()
    print("vec =", b.x, b.y)
