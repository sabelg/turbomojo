<!-- match: invalid call to -->
# Arguments that do not fit

Mojo says something like: `invalid call to ...`

## What it means

The function exists, but not with these arguments: too many, too few, or of the wrong types. The notes below the error point at the declaration Mojo tried.

## How to fix it

- Compare with the declaration (F12 goes to it; the parameter tip shows it while you type).
- Convert arguments of the wrong type, or pass them by name if the order is unclear.

## Before (does not build)

```mojo
def area(w: Int, h: Int) -> Int:
    return w * h

def main():
    print(area(2, 3, 4))
```

## After (builds)

```mojo
def area(w: Int, h: Int) -> Int:
    return w * h

def main():
    print(area(2, 3))
```
