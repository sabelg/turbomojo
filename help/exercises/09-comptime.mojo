# Exercise 9 of 13: compile-time constants and loops
#
# Older Mojo used `alias` and `@parameter` for compile-time work; Mojo 1.x uses `comptime`.
# When it is right, it prints:
#     squares = 14
#
# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains
# the message.
# expect: squares = 14


def main():
    alias LANES = 4
    var total = 0
    @parameter
    for i in range(LANES):
        total += i * i
    print("squares =", total)
