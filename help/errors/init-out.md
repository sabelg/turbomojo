<!-- match: __init__ method must return Self type with 'out' -->
# `__init__` takes `out self`

Mojo says something like: `__init__ method must return Self type with 'out' ...`

## What it means

A constructor makes a new value: its `self` is written to, not read, so it is declared `out self`.

## How to fix it

- Write `def __init__(out self):`; every constructor takes `out self`.

## Coming from Python

This is a Python habit. The page *Coming from Python* (Help > Coming from Python, or
**P** in this window) lists the other differences.

## Before (does not build)

```mojo
struct Point:
    var x: Int
    def __init__(self):
        self.x = 0

def main():
    var p = Point()
    print(p.x)
```

## After (builds)

```mojo
struct Point:
    var x: Int
    def __init__(out self):
        self.x = 0

def main():
    var p = Point()
    print(p.x)
```
