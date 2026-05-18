---
title: importing c functions
---
# c ffi

despite being written in zig, revo lets you call c functions from within your revo code
this is what revo uses for extensions and perf-heavy bits

you compile your c code into a shared library (`.so`, `.dylib`, `.dll`) and load it at runtime
in this tutorial, yourw gonna write c functions that match the revo ffi signature, compile them to a shared object, and register them for use in revo code

you can use the resulting library in two ways:

- `const c = import("libprint.so")`, then call `c.echo()` or whatever you've exported
- `c_use("regex.so")`, which registers the exports as globals

globals are usually not the best default, but they can be useful for small builtins.

### important

this is not lua
the only side effects are the ones defined in `revo.h`
every c function gets a variadic argument list and a single `out_result` slot, which becomes the return value

that means state usually lives in the c library and gets passed around as handles
`void *` is not a real revo type, so only use the raw integer fields for ids, pointers, or other opaque handles
anything other than `revo_number` is just a tagged handle and should be treated that way

they all follow this signature:

```c
void echo(void *vm, size_t argc, RevoData *argv, RevoData *out_result);
```

# your first C module!

## header file

include `revo.h` in your C code.
it lives at the repository root and is installed to `zig-out/include/`.

after running `zig build lib`, the header is available at `zig-out/include/revo.h` and the auto-generated header is always in sync with exported functions
### examples

here are the terse core examples from `examples/ffi/all.c`:

```c
#include "revo.h"
#include <string.h>

/// > echo(s) -> string
R_SIG(echo) {
  if (argc < 1 || argv[0].tag != revo_string) {
    *out_result = revo_nil();
    return;
  }
  *out_result = argv[0];
}

/// > strlen(s) -> number
R_SIG(strlen_fn) {
  if (argc < 1 || argv[0].tag != revo_string) {
    *out_result = (RevoData){.tag = revo_number, .value = 0};
    return;
  }
  const char *str = (const char *)(uintptr_t)argv[0].value;
  double len = strlen(str);
  *out_result = (RevoData){.tag = revo_number, .value = *(uint64_t *)&len};
}

/// > add(a, b) -> number
R_SIG(add) {
  if (argc < 2) {
    *out_result = (RevoData){.tag = revo_number, .value = 0};
    return;
  }
  double a = argv[0].tag == revo_number ? *(double *)&argv[0].value : 0;
  double b = argv[1].tag == revo_number ? *(double *)&argv[1].value : 0;
  double result = a + b;
  *out_result = (RevoData){.tag = revo_number, .value = *(uint64_t *)&result};
}

R_EXPORT({"echo", echo}, {"strlen_fn", strlen_fn}, {"add", add})
```

call from revo:

```ruby
const c = import("examples.so")
print(c.echo("hello")) # hello
print(c.strlen_fn("revo")) # 4
print(c.add(5, 3)) # 8
```

`const c` is the convention for modules whose purpose is operating on that specific library
`c_use()` should be used for revo code that does not matter in the grand scheme of things

### compile

a small makefile, tested mainly on arm64-mac and linux, is this and should have you set up forever

```Makefile
LDFLAGS := -shared -Wall -Wextra -O2
UNAME := $(shell uname -s)
ifeq ($(UNAME), Darwin)
	LDFLAGS += -undefined dynamic_lookup -target arm64-apple-macos11
endif

all: printf_wrapper.so examples.so

%.so: %.c
	clang $(LDFLAGS) -o $@ $^

clean:
	rm -f *.so *.dylib
```

nothing prevents you from just compiling it with gcc, too

## data conversion

### passing data to c

when you call a c function from revo, all arguments are converted to `RevoData` structs:

| revo type          | c tag           | c value |
|--------------------|-----------------|---------|
| `42` (number)      | `revo_number`   | bitcast of `f64` |
| `"hello"` (string) | `revo_string`   | pointer to string data |
| `:atom` (atom)     | `revo_atom`     | atom id |
| `fn()` (function)  | `revo_function` | function id |
| `{}` (table)       | `revo_table`    | table id |
| `(1, 2)` (tuple)   | `revo_tuple`    | tuple id |

### extracting values in c

```c
double num = *(double *)&argv[0].value;
const char *str = (const char *)(uintptr_t)argv[0].value;
uint64_t id = argv[0].value;
```

### returning values from c

set `*out_result` to return a value

```c
// return a number
double result = 3.14;
*out_result = (RevoData){.tag = revo_number, .value = *(uint64_t *)&result};

// return nil (most common)
*out_result = revo_nil();

// return a stable atom
*out_result = (RevoData){.tag = revo_atom, .value = ra_true};
```

### returning strings from c

strings must be interned into revo's string pool
use `revo_intern()`:

```c
// intern a string result
const char *result = "hello";
uint64_t id = revo_intern(vm, (uint64_t)(uintptr_t)result, 5);
*out_result = R_STRING(id);
```

or return an existing interned string passed as an argument:

```c
if (argv[0].tag == revo_string) {
  *out_result = argv[0];
}
```

## best practices

### validate arguments!

for now, functions are variadic.
this will become optional with some friendly macros when the api settles, but for now, just check everything manually

```c
if (argv[i].tag != revo_number) {
  // handle type error
  return;
}
```

### always set out_result!

even if you return nil, always set the output parameter.
if the function can fail, returning an error atom or tuple is usually easiest

```c
if (out_result)
  *out_result = revo_nil();
```

### use pic!

`clang -fPIC`
if you're running into some boundary issue, not using pic is often the reason.

position independent code makes functions relocatable in memory. there are many unknown unknowns to this, so it's better to be aware

### handle null carefully!

be defensive about pointers.
anything you're given will be valid for the runtime of your function, but may be invalid later on if you keep it
don't store revo values (ids/handles) for later use outside the FFI call
if you need to store state:

- make a table in revo and pass it as context
- return ids and don't cache raw pointers
