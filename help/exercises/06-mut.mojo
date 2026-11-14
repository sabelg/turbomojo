# Exercise 6 of 13: changing self
#
# A method that changes its struct must say so.
# When it is right, it prints:
#     count = 2
#
# Check it with Help > Exercise done? ({key}). F1 on a line with an error explains
# the message. Lost? Ctrl-Z undoes; Help > Exercises > Reset gives the original back.
# expect: count = 2


struct Counter:
    var count: Int

    def __init__(out self):
        self.count = 0

    def bump(self):
        self.count += 1


def main():
    var c = Counter()
    c.bump()
    c.bump()
    print("count =", c.count)
