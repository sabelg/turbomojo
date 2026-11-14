<!-- match: use of unknown declaration 'value' -->
# `@value` was replaced by `@fieldwise_init`

Mojo says something like: `use of unknown declaration 'value'`

## What it means

The `@value` decorator from older Mojo versions was removed in Mojo 1.x. Structs now ask explicitly for a fieldwise constructor (`@fieldwise_init`) and for the traits they conform to (`Copyable`, `Movable`, `Writable`, `ImplicitlyCopyable`).

## How to fix it

- Replace `@value` with `@fieldwise_init`.
- List the traits the struct needs in parentheses: `struct Pair(Copyable, Movable):` (add `ImplicitlyCopyable` for small plain-value structs that may be copied without `.copy()`).

## Before (does not build)

```mojo
@value
struct Pair:
    var a: Int
    var b: Int

def main():
    var p = Pair(1, 2)
    print(p.a, p.b)
```

## After (builds)

```mojo
@fieldwise_init
struct Pair(Copyable, Movable):
    var a: Int
    var b: Int

def main():
    var p = Pair(1, 2)
    print(p.a, p.b)
```
