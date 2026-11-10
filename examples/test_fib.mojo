"""Example tests: Run > Test executes this file's TestSuite."""
from std.testing import assert_equal, TestSuite


def fib(n: Int) -> Int:
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)


def test_fib_small() raises:
    assert_equal(fib(10), 55)


def test_fib_base() raises:
    assert_equal(fib(1), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
