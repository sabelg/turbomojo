<!-- match: unqualified access to struct parameter -->
# Struct parameters are written `Self.T` inside the struct

Mojo says something like: `unqualified access to struct parameter 'T'; use 'Self.T' instead`

## What it means

Inside a parametric `struct Box[T: ...]:`, the parameter `T` belongs to `Self`. Writing bare `T` in fields, method signatures, or method bodies is rejected so struct parameters are never confused with outer types or method parameters.

## How to fix it

- Prefix every struct parameter inside the struct body with `Self.`: `Self.T`, `Self.N`, `Self.origin`.

## Before (does not build)

```mojo
@fieldwise_init
struct Box[T: Copyable & Deinitable](Copyable):
    var item: T

def main():
    var b = Box[Int](42)
    print(b.item)
```

## After (builds)

```mojo
@fieldwise_init
struct Box[T: Copyable & Deinitable](Copyable):
    var item: Self.T

def main():
    var b = Box[Int](42)
    print(b.item)
```
