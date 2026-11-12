# Exercise 8 of 8: it builds, but is it right?
#
# This one builds and runs - and prints the wrong sum. Find out why.
# When it is right, it prints:
#     sum = 15
#
# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains
# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.
# expect: sum = 15


def main():
    var total = 0
    for i in range(1, 6):
        total += i
    print("sum =", total)
