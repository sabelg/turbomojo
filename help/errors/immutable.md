<!-- match: expression must be mutable -->
# Changing something that may not be changed

Mojo says something like: `expression must be mutable ...`

## What it means

The value you assign to or change in place is read-only here - most often `self` in a method declared without `mut`, or an argument (arguments are read-only by default).

## How to fix it

- Declare the method `def bump(mut self):` to change fields.
- For an argument the function may change, write `mut x: Int`; to have your own copy, `var x: Int`.

## Before (does not build)

```mojo
struct Counter:
    var n: Int
    def __init__(out self):
        self.n = 0
    def bump(self):
        self.n += 1

def main():
    var c = Counter()
    c.bump()
```

## After (builds)

```mojo
struct Counter:
    var n: Int
    def __init__(out self):
        self.n = 0
    def bump(mut self):
        self.n += 1

def main():
    var c = Counter()
    c.bump()
    print(c.n)
```
