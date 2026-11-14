# Exercise 13 of 13: SIMD vectors
#
# `SIMD[DType.int32, 4]` adds four lanes at once, then reduces them with `reduce_add()`.
# Look up `SIMD` with Ctrl-F1 or Alt-F1 (`@SIMD`) to see its reduction methods!
# When it is right, it prints:
#     total = 110
#
# Check it with Help > Exercise done? ({key}).
# expect: total = 110


def main():
    var a = SIMD[DType.int32, 4](1, 2, 3, 4)
    var b = SIMD[DType.int32, 4](10, 20, 30, 40)
    print("total =", (a + b).total())
