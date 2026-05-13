---
title: embedding revo in c
---

# embedding revo in c

`revo.h` is the public C API for both extensions and embedding
the embedding side is small for now: create a vm, compile code, run it, or eval source directly

see `examples/c/basic.c` for a minimal working program

## build

build the c library and header with:

```bash
zig build lib
```

the static library and auto-generated header end up in:
- `zig-out/lib/liberevo.a`
- `zig-out/include/revo.h`

the header is automatically generated from all functions marked with `callconv("c")` and prefixed by `erevo_` and `revo_` in the codebase, so it's always in sync with the implementation

## create a vm

```c
#include "revo.h"

ErevoVM *vm = erevo_vm_create();
if (!vm) return 1;
```

`ErevoVM` is an opaque handle
destroy it with `erevo_vm_destroy()` when you're done

## compile, run, eval

```c
ErevoProgram *program = erevo_compile(vm, "main.rv", "1 + 2");
if (!program) {
  puts(erevo_vm_last_error(vm));
  return 1;
}

ErevoData result;
if (!erevo_run(vm, program, &result)) {
  puts(erevo_vm_last_error(vm));
}

if (!erevo_eval(vm, "main.rv", "1 + 2", &result)) {
  puts(erevo_vm_last_error(vm));
}

erevo_program_destroy(program);
erevo_vm_destroy(vm);
```

## string values

strings pong back to C as temporary c strings
if you want to return a string from a c extension, call `revo_intern()` on a valid c string pointer and store the returned id in `out_result`
the C side should not keep or free revo-owned ids
