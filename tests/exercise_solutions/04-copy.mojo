# Exercise 4 of 13: copying is asked for
#
# Lists are not copied behind your back. Keep both lists.
# When it is right, it prints:
#     3 3
#
# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains
# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.
# expect: 3 3


def main():
    var a = List[Int]()
    a.append(1)
    a.append(2)
    a.append(3)
    var b = a.copy()
    print(len(a), len(b))
