# Exercise 3 of 13: text is not a number
#
# Fix the first error, build again: a second one is waiting behind it. Reading
# each new message is part of the exercise.
# When it is right, it prints:
#     twice = 42
#
# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains
# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.
# expect: twice = 42


def main() raises:
    var n: Int = Int("21")
    print("twice =", n * 2)
