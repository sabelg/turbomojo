# Exercise 5 of 8: a struct's constructor
#
# A constructor writes a new value.
# When it is right, it prints:
#     x = 4
#
# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains
# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.
# expect: x = 4


struct Point:
    var x: Int

    def __init__(self, x: Int):
        self.x = x


def main():
    var p = Point(4)
    print("x =", p.x)
