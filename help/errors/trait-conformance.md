<!-- match: does not conform to trait -->
# A type does not implement the required trait

Mojo says something like: `... argument type '...' does not conform to trait '...'`

## What it means

A generic function or container requires a trait (`Copyable`, `Movable`, `Writable`, `Equatable`, `Hashable`), and the struct passed to it has not declared (or implemented) that trait.

## How to fix it

- Add the trait to the struct header: `struct Tag(Copyable, Movable, Writable):`.
- For `Copyable`, `Movable`, `Equatable`, `Hashable`, and `Writable`, Mojo 1.2 can synthesize the trait methods automatically when every field conforms to that trait; otherwise implement the required method (for example `def write_to(self, mut writer: Some[Writer]):` for `Writable`).

## Before (does not build)

```mojo
@fieldwise_init
struct Tag(Copyable, Movable):
    var id: Int

def show[T: Writable](x: T):
    print(x)

def main():
    var t = Tag(7)
    show(t)
```

## After (builds)

```mojo
@fieldwise_init
struct Tag(Copyable, Movable, Writable):
    var id: Int

def show[T: Writable](x: T):
    print(x)

def main():
    var t = Tag(7)
    show(t)
```
