"""A tiny demo program for TurboMojo."""
from std.collections import List


struct Counter(Copyable, Movable):
    var count: Int

    def __init__(out self):
        self.count = 0

    def bump(mut self, by: Int = 1):
        self.count += by


def fib(n: Int) -> Int:
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)


def main():
    var c = Counter()
    for i in range(10):
        c.bump(i)
    print("Hello from Mojo! count =", c.count)
    print("fib(20) =", fib(20))
