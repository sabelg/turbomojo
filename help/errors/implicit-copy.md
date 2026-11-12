<!-- match: cannot be implicitly copied -->
# Copying must be asked for

Mojo says something like: `cannot be implicitly copied ...`

## What it means

Some types (List, String's larger cousins, your own structs) are not copied behind your back: `var b = a` would copy the whole list, so Mojo wants you to say what you mean.

## How to fix it

- `a.copy()` makes a copy and keeps `a`.
- `a^` moves `a` into the new place; `a` cannot be used afterwards.
- A struct can be made copyable with `(Copyable, Movable)` and copied with `.copy()`.

## Before (does not build)

```mojo
def main():
    var a = List[Int]()
    a.append(1)
    var b = a
    print(len(b), len(a))
```

## After (builds)

```mojo
def main():
    var a = List[Int]()
    a.append(1)
    var b = a.copy()
    print(len(b), len(a))
```
