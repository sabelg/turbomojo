<!-- match: is uninitialized at the implicit return -->
# A field the constructor does not set

Mojo says something like: `is uninitialized at the implicit return ...`

## What it means

Every field of a struct must have a value when `__init__` ends; this one is never set.

## How to fix it

- Set every field in `__init__`: `self.n = 0`.
- Or give the constructor an argument for it: `def __init__(out self, n: Int): self.n = n`.

## Before (does not build)

```mojo
struct Point:
    var x: Int
    var y: Int
    def __init__(out self):
        self.x = 0

def main():
    var p = Point()
    print(p.x)
```

## After (builds)

```mojo
struct Point:
    var x: Int
    var y: Int
    def __init__(out self):
        self.x = 0
        self.y = 0

def main():
    var p = Point()
    print(p.x, p.y)
```
