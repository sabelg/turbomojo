# Exercise 12 of 13: struct parameters and Writable
#
# Inside a parametric struct, parameters belong to `Self` (`Self.T`), and passing a struct
# to a `Writable` function requires `Writable` in the struct's trait list.
# When it is right, it prints:
#     box(99)
#
# Check it with Help > Exercise done? ({key}). Fix the first error, then F1 on the next!
# expect: box(99)


@fieldwise_init
struct Box[T: Copyable & Writable & Deinitable](Copyable):
    var item: T

    def write_to(self, mut writer: Some[Writer]):
        writer.write("box(", self.item, ")")


def show[U: Writable](x: U):
    print(x)


def main():
    var b = Box[Int](99)
    show(b)
