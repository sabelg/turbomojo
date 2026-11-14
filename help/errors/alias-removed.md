<!-- match: use of unknown declaration 'alias' -->
# `alias` was replaced by `comptime`

Mojo says something like: `use of unknown declaration 'alias'`

## What it means

`alias` from older Mojo versions was removed in Mojo 1.x. Compile-time constants and type aliases now use `comptime`.

## How to fix it

- Replace `alias N = ...` with `comptime N = ...`.
- Compile-time branches, loops and assertions also use `comptime`: `comptime if ...`, `comptime for ...`, `comptime assert ...`.

## Before (does not build)

```mojo
def main():
    alias N = 4
    print(N)
```

## After (builds)

```mojo
def main():
    comptime N = 4
    print(N)
```
