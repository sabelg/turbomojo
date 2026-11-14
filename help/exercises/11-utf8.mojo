# Exercise 11 of 13: UTF-8 string bytes and slices
#
# Mojo strings are UTF-8, so indexing and length ask you whether you mean bytes or code points.
# When it is right, it prints:
#     first = M bytes = 5
#
# Check it with Help > Exercise done? ({key}). F1 on each error line explains how UTF-8 strings work.
# expect: first = M bytes = 5


def main():
    var s = String("Mojo!")
    print("first =", s[0], "bytes =", len(s))
