# Exercise 1 of 8: a new name needs var
#
# Mojo does not create a variable the first time you assign to it.
# When it is right, it prints:
#     count = 3
#
# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains
# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.
# expect: count = 3


def main():
    var count = 0
    for i in range(3):
        count += 1
    print("count =", count)
