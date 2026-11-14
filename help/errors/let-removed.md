<!-- match: use of unknown declaration 'let' -->
# `let` was removed: declare variables with `var`

Mojo says something like: `use of unknown declaration 'let'`

## What it means

`let` from early Mojo versions was removed. Every local variable is declared with `var` (the compiler tracks whether a variable is mutated and optimizes immutable bindings automatically).

## How to fix it

- Replace `let x = ...` with `var x = ...`.
- For compile-time constants, use `comptime X = ...`.

## Before (does not build)

```mojo
def main():
    let x = 5
    print(x)
```

## After (builds)

```mojo
def main():
    var x = 5
    print(x)
```
