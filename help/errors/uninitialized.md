<!-- match: use of uninitialized value -->
# A value used before it has one

Mojo says something like: `use of uninitialized value ...`

## What it means

The variable was declared but never given a value on this path - or it was moved away with `^` and is empty now.

## How to fix it

- Give it a value where it is declared: `var x: Int = 0`.
- Make sure every branch of an `if` sets it.
- After `b = a^`, use `b`, not `a` (or copy with `a.copy()` instead of moving).

## Before (does not build)

```mojo
def main():
    var x: Int
    print(x)
```

## After (builds)

```mojo
def main():
    var x: Int = 0
    print(x)
```
