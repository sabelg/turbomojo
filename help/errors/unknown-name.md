<!-- match: use of unknown declaration -->
# Unknown name

Mojo says something like: `use of unknown declaration ...`

## What it means

Mojo found a name it has no definition for: a variable, function or type that is not declared in this file, not imported, or spelled differently.

## How to fix it

- Check the spelling (Mojo names are case-sensitive).
- Declare a variable with `var` before using it.
- Import what comes from elsewhere: `from std.collections import List` (Mojo 1.x imports need the `std.` prefix).

## Before (does not build)

```mojo
def main():
    print(totl)
```

## After (builds)

```mojo
def main():
    var total = 3
    print(total)
```
