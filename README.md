<div align="center">
<h1>revo</h1>

![written in Zig](https://img.shields.io/badge/written%20in-Zig-orange)
![version 0.0.1a](https://img.shields.io/badge/version-0.0.1a-navy)

[homepage & docs](https://gills.pages.dev/revo)
| [github](https://github.com/if-not-nil/revo)
| [learn](https://gills.pages.dev/revo/basics)
| [chat & discuss](https://discord.com/invite/XzGWh7TX59)

</div>

**revo** is an expressive, dynamically-typed language that is made to balance semantic freedom and readability

check out the [homepage](https://gills.pages.dev/revo),
the [basics guide](https://gills.pages.dev/revo/basics/),
and the [blog](https://gills.pages.dev/revo/blog/apples/)

# sections

- [why revo?](#why-revo)
- [installation](#installing)
  - [on posix systems](#on-posix-systems)
  - [on windows](#on-windows-powershell)
- [cli reference](#cli-reference)
  - [development](#development)
  - [credits](#credits)
- [license](#license)

# why revo?

revo creates an ergonimic programming experience with:

## pattern matching and result types

```ruby
fn safe_div(a, b)
  if b == 0 (:err, :DivByZero)
  else (:ok, a / b)

match safe_div(10, 2)
  | (:ok, v)  print(v)     # 5
  | (:err, e) print(e)
```

## fibers

```ruby
const h = spawn add(20, 22)
join(h)  # 42
```

## testing that doesn't hurt

```ruby
fn add(a, b) a + b
fn mul(a, b) a * b

suite "ops" do
  test "addition" do
    expect(add(20, 22) == 42)?
    expect(add(20, 22) != 22)?
  end

  test "multiplication" do
    expect(mul(20, 22) == 440)?
    expect(mul(20, 22) != 42)?
  end
```

## painless embedding

```c
#include "revo.h"

ErevoVM *vm = erevo_vm_create();
if (!vm) return 1;

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

you'll enjoy revo so much that you'll want to **actually continue** a project!
so please consider [installing revo](#installing) and giving it a try.

# installing

you will need [zig `0.16.0`](https://ziglang.org/download) to build revo

## on posix systems

```bash
git clone https://github.com/if-not-nil/revo && cd revo
zig build -Doptimize=ReleaseFast
cp ./zig-out/bin/revo ~/.local/bin/revo

# verify installation
revo --version
```

## on windows (powershell)

```bash
git clone https://github.com/if-not-nil/revo && cd revo
zig build -Doptimize=ReleaseFast -Drepl=none

mkdir "C:/tools/revo/bin"
copy ./zig-out/bin/revo C:/tools/revo/bin

# now add it to PATH by doing:
# 1. press Win+S
# 2. type "env" and then press enter. it should take you to the System Properties > Advanced tab
# 3. click "Environment Variables" and then "Path" in the "System variables"
# 4. press "new" and type "C:\tools\revo\bin", then press enter
# 5. press OK for all of the tabs you've opened
# after that, you have to open a new CMD/Powershell window for PATH changes to take effect

# verify installation
revo --version
```

binary releases are not yet available

# usage

```bash
usage: revo [options] [script [args...]]

options:
  -e code          run code
  -i               enter interactive mode after executing
  -d               output the last value the program evaluated
  -b               compile script to bytecode (.rvo)
  -o path          output path for -b (default: input with .rvo extension)
  --test           run test blocks
  --bench[n]       run with performance counters ([n] iterations, 1 if not specified)
  --dis            show bytecode disassembly instead of running
  -h, --help       show this help message
  --version        show version

examples:
  revo                           start interactive REPL
  revo script.rv                 run script
  revo -e "1 + 2"                run inline code
  revo -e "1 + 2" -i             run inline code and enter REPL
  revo -b script.rv              compile script to bytecode
  revo -b -o output.rvo script   compile script with custom output path
  revo --bench script.rv         run with performance counters
  revo --dis script.rv           show bytecode disassembly
```

## development

### building

```bash
zig build # debug build
zig build run # debug run (repl implementation is hardcoded to a very simple one)
zig build -Doptimize=ReleaseFast # release build
zig build -Drepl=none # custom repl backend (bestline, readline, libedit, none)
# build C library + auto-generated header
# check zig-out/include/, zig-out/lib/
zig build lib 
```

the default repl backend is the vendored bestline, linked statically. read [build.zig](./build.zig)

**note:** the C library and header are only built with `zig build lib`.
the auto-generated header is always in sync with exported functions, marked with `callconv("c")`

### running tests

```bash
zig build test --summary all -Dtest_filter="some test name filter"
```

### contributing

recommending to a friend is always greatly appreciated. any contributions are welcome!

see [CONTRIBUTING.md](./CONTRIBUTING.md) for more details

## credits

- [bestline](https://github.com/jart/bestline) by Justine Tunney - MIT

**optional repl backends, not vendored but linked dynamically**
- [libedit](https://thrysoee.dk/editline/) - BSD
- [GNU readline](https://tiswww.case.edu/php/chet/readline/rltop.html) - GPLv3

# license

revo is licensed under [MIT.](https://mit-license.org/) see the [LICENSE.txt](./LICENSE.txt) file for details
