<!-- match: aliasing values passed mutably -->
# Two arguments that are the same thing

Mojo says something like: `aliasing values passed mutably ...`

## What it means

You pass something to a method that may change it (`mut self`) and, in the same call, a part of it to read. Mojo forbids this: the method could change what it is reading.

## How to fix it

- Copy the part to a local first: `var t = b.s` then `b.put(t)` (for List and other non-copyable values: `b.s.copy()`).

## Before (does not build)

```mojo
struct Box:
    var s: String
    def __init__(out self):
        self.s = "a"
    def put(mut self, t: String):
        self.s = t

def main():
    var b = Box()
    b.put(b.s)
```

## After (builds)

```mojo
struct Box:
    var s: String
    def __init__(out self):
        self.s = "a"
    def put(mut self, t: String):
        self.s = t

def main():
    var b = Box()
    var t = b.s
    b.put(t)
    print(b.s)
```
