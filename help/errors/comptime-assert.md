<!-- match: 'comptime assert' must be inside a function -->
# `comptime assert` belongs inside a function body

Mojo says something like: `'comptime assert' must be inside a function; move this into a function body`

## What it means

Unlike `comptime N = 4`, a `comptime assert` statement is checked when a function or constructor is instantiated, so Mojo does not allow it at file or struct scope.

## How to fix it

- Move `comptime assert cond, "message"` inside `def __init__(...)`, `def main()`, or the function that relies on the invariant.

## Before (does not build)

```mojo
comptime N = 4
comptime assert N > 0, "N must be positive"

def main():
    print(N)
```

## After (builds)

```mojo
comptime N = 4

def main():
    comptime assert N > 0, "N must be positive"
    print(N)
```
