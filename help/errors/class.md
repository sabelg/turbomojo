<!-- match: classes are not supported yet -->
# No classes: a struct

Mojo says something like: `classes are not supported yet ...`

## What it means

Mojo has no `class` (yet). Its types are `struct`s: their fields are declared with
`var`, their constructor takes `out self`, and in place of inheritance a struct
implements traits.

## How to fix it

- Write `struct` for `class`, declare each field with `var` and its type.
- The constructor is `def __init__(out self, ...)`; a method that changes the struct
  takes `mut self`.

## Coming from Python

This is a Python habit. The page *Coming from Python* (Help > Coming from Python, or
**P** in this window) lists the other differences.

## Before (does not build)

```mojo
class Point:
    var x: Int

    def __init__(out self, x: Int):
        self.x = x


def main():
    var p = Point(3)
    print(p.x)
```

## After (builds)

```mojo
struct Point:
    var x: Int

    def __init__(out self, x: Int):
        self.x = x


def main():
    var p = Point(3)
    print(p.x)
```
