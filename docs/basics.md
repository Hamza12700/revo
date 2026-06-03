# basics

**revo in 1 minute**
```ruby
#
# bindings
#
let a = 10 # mutable local
const b = 20 # immutable local
global c = 30 # module-global

#
# types
#
let n = 42
let s = "hello"
let atom = :ok
let bools = (:true, :false, :nil)
let tup = (:ok, 42)
let (tag, val) = tup # destructuring
let tbl = {x = 1, y = 2}

#
# type annotations are enforced by the compiler
# they make your code faster and incorrect code doesn't compile
#
let s: string = "hello"
# this would crash!
# let s: num = "hello"
fn hi()

#
# functions
#
fn add(x, y) x + y # single-expression shorthand
const double = fn(x) x * 2 # anonymous fn bound to const

fn multi(a, b) do # multi-line with do...end
    if a < 0 do
        return 0
    end
    a + b
end

# closures capture outer vars by reference
fn make_counter() do
    let x = 0
    const inc = fn() do
        x = x + 1
        x
    end
    inc
end
let c = make_counter()
print(c()) # 1
print(c()) # 2

@doc"""
this checks whether a is bigger than b

this is also a doc comment!
you can parse revo docs via `revo --doc ./file.rv`

errors
"""
fn is_more(a: num, b: num) -> bool do
    a > b
end

#
# structs
#
struct Point {
    x: number,
    y: number = 0,
    fn hi(self) print(self)
}
let p = Point{x = 10, y = 20}
p:hi() # the colon syntax puts the
       # left-hand-side thing as the first argument

#
# pipes
#
fn double(x) x * 2
21 |> double # 42

"asdf"
  |> _:upper()
  |> _:sub(1, 2)
  |> print # "SD"

#
# control flow
#
let score = 85

# if/else is an expression
const grade = if score >= 70 do
    "pass"
end do
    "fail"
end

"""
> but if-else chains are ugly!
yes, you should match :true instead
this is like elixir's `cond`
"""

const grade = match :true
  | is_a(user) do
      "pass"
  end
  | are_friends(user6, user7) do
      "asdf"
  end


# match with guards and wildcards
match score
  | v when v >= 90 => "A"
  | v when v >= 70 => "B"
  | v              => "C"

# while
let i = 0
while i < 5 do
    i = i + 1
end

# for range (inclusive start, exclusive end)
let sum = 0
for i in 0..5 do
    sum = sum + i
end

# loop with break
let x = 0
const found = loop do
    if x >= 10 do
        break(x)
    end
    x = x + 1
end

#
# error handling; results are (:ok, val) / (:err, :Kind)
#
const n = tonumber("42")? # unwrap or return/panic
const fallback = tonumber("nope") orelse 0

# result helpers
ok?!((:ok, 42)) # :true
err?!((:err, :Bad)) # :true
(:ok, 42):unwrap() # 42

#
# fibers
#
const h = spawn add(20, 22)
join(h) # 42

#
# comptime
#
const LIMIT = comp (1024 * 1024)

#
# macros
#
macro unless! `(%cond:expr %body:expr)` `if %cond :nil else %body`
unless!(:false, 42) # 42

```

# # bindings

variables are declared with `let`, `const`, or `global`:

```ruby
let a = 10 # mutable, scoped to block
const b = 20 # immutable, scoped to block
global c = 30 # visible across the whole module
```

`let` and `const` are block-scoped. a `let` can be reassigned with `=`.
`const` is a fixed binding -- assigning to it is a compile error.

`global` makes the name visible across the whole module, including in test
blocks and nested scopes. it's useful for shared configuration.

all three are expressions. `let` and `const` return the bound value:

```ruby
let y = let z = 5 # both y and z are 5
```

you can bind multiple names at once with tuple destructuring:

```ruby
const (x, y) = (10, 20)
const (tag, val) = match result
    | (:ok, v) => (:ok, v)
    | (:err, _) => (:err, 0)
```

destructuring works with nested tuples too:

```ruby
const ((a, b), (c, d)) = ((1, 2), (3, 4))
```

the discard `_` ignores a position:

```ruby
const (_, name, _) = (1, "hello", :ok)
```

# # numbers

numbers are doubles internally, but integer arithmetic is exact up to
2^53:

```ruby
1 + 2 * 3 # 7
10 / 2 # 5
-(3 + 4) # -7
1 < 2 # :true
1 == 1 # :true
1 != 2 # :true
"a" < "b" # :true (lexicographic)
```

`and`/`or` return the value that decided the result, not a boolean:

```ruby
1 and 2 # 2
0 or 9 # 9
0 and 999 # 0 (short-circuit)
1 or 999 # 1 (short-circuit)
not :false # :true
```

only `:false`, `0`, and `:nil` are falsey. everything else -- including
`""`, `{}`, and `()` -- is truthy. this means `and`/`or` work naturally
for defaults and guards.

assignment operators exist and return the rhs:

```ruby
let a = 41
a += 1 # 42
a -= 1; a *= 2; a /= 2

let y = (x = 42) # y is 42
```

operator precedence from loosest to tightest:

| level | operators | associativity |
|---|---|---|
| comp block    | `comp` | |
| assign        | `=`, `+=`, `-=`, `*=`, `/=`, `%=` | right |
| logic         | `or`, `and`, `not` | left |
| pipe          | `\|>` | left |
| comparison    | `<`, `>`, `<=`, `>=`, `==`, `!=` | left |
| range         | `..` | |
| term          | `+`, `-` | left |
| factor        | `*`, `/`, `%` | left |
| unary         | `-`, `not` | right |
| propagate     | `?` | postfix |
| suffix        | `.`, `[]`, `()`, `:()`, `\|` | left |

# # strings

double-quoted strings process escape sequences (`\n`, `\t`, `\\`, etc).
single-quoted strings are completely literal:

```ruby
"hello\nworld" # newline in the middle
'hello\nworld' # literal backslash-n
```

strings have built-in methods via the `:` syntax:

```ruby
"hello":upper() # "HELLO"
"hello":lower() # "hello"
"  hi  ":trim() # "hi"
"hello":sub(1, 3) # "ell" (0-indexed start, length)
"a,b,c":split(",") # {"a", "b", "c"}
"hello":find("ll") # 2
"hello":replace("l", "r") # "herro"
"hello":starts_with?("he") # :true
"hello":ends_with?("lo") # :true
"hello":contains?("ell") # :true
"hello":index_of("ell") # 1
"hello":reverse() # "olleh"
"hello":ascii() # 104 (code point of first char)
"abc":with(1, "X") # "aXc"
"hello":len() # 5
```

concatenation and repetition:

```ruby
"hello" + " world" # "hello world"
"ha" * 3 # "hahaha"
```

# # atoms

atoms are the language's enum and symbol type. they start with `:`:

```ruby
:ok
:error
:not_found
```

`:false`, `0`, and `:nil` are the only falsey values. everything else
(including `""`, `{}`, and `()`) is truthy.

atoms shine when paired with tuples for tagged results -- instead of
exceptions, revo uses `(:ok, value)` and `(:err, :Kind)`:

```ruby
ok?!((:ok, 42)) # :true
err?!((:err, :Bad)) # :true
(:ok, 42):unwrap() # 42
(:err, :bad)? # panics at toplevel
(:err, :bad) orelse 0
```

type predicate functions use atoms and the `?` suffix convention:

```ruby
number?(42) # :true
string?("hi") # :true
atom?(:ok) # :true
table?({}) # :true
tuple?((1, 2)) # :true
function?(fn(x) x) # :true
type?(:ok) # :true  (checks if value is a type)
struct?({}) # :true if table was created by a struct
```

# # tuples

tuples are immutable fixed-length sequences. safer than tables when you
know the shape:

```ruby
const t = (1, 2, 3)
t[0] # 1

# destructuring
const (x, y) = (10, 20)

# functions return tuples naturally
fn vec_mul(a, b, f)
    (a * f, b * f)

const (vx, vy) = vec_mul(4, 6, 2)
print(vx + vy) # 20

# ignore values with _
const (_, name, _) = (1, "hello", :ok)
```

tuple methods:

```ruby
(1, 2, 3):len() # 3
(:ok, 42):unwrap() # 42 (panics on :err)
(:err, :bad):unwrap_err() # :bad (panics on :ok)

# concatenation and repetition
(1, 2) + (3, 4) # (1, 2, 3, 4)
(1, 2) * 3 # (1, 2, 1, 2, 1, 2)
```

# # tables

tables are the core data structure -- a hybrid of array and hashmap:

```ruby
let arr = {1, 5, 3} # array part
let tbl = {k = "v", x = 10} # hash part
tbl.x = "y" # sugar for tbl["x"] = "y"

let a = {
    inner = 8, # keys are atoms
    ["inner_str"] = 10, # [] for any key type
    mutate = fn(self) self.inner *= 2,
}
print(a.inner)
print(a["inner_str"])
a:mutate() # sugar for a.mutate(a)
```

tables are always passed by reference. shallow copy with `:copy()`:

```ruby
const t2 = a:copy()
```

table methods:

```ruby
{1, 2, 3}:len() # 3
{1, 2, 3}:insert(0, 0) # {0, 1, 2, 3}
{1, 2, 3}:push(4, 5) # {1, 2, 3, 4, 5}
{1, 2, 3}:remove(1) # removes element at index 1
{1, 2, 3}:first() # 1
{1, 2, 3}:last() # 3
{3, 1, 2}:sort() # {1, 2, 3}
{3, 1, 2}:reverse() # {2, 1, 3}
{1, 2, 3}:concat(",") # "1,2,3"
{a = 1}:keys() # {"a"}
{a = 1}:has?("a") # :true
{1, 2, 3}:contains?(2) # :true
{1, 2, 3}:copy() # shallow copy
{a = 1}:merge({b = 2}) # {a = 1, b = 2}
{1, 2, 3}:as_tuple() # (1, 2, 3)
{1, 2, 2, 3}:unique() # {1, 2, 3}
```

# # # structs

a `struct` declaration creates a type-checked constructor:

```ruby
struct Point {
    x: number,
    y: number = 0, # default value
    fn mag(self) self.x * self.x + self.y * self.y,
    fn add(self, other) Point{x = self.x + other.x, y = self.y + other.y},
}

const p1 = Point{x = 3, y = 4}
const p2 = Point{x = 1, y = 2}
print(p1.x, p1:mag(), p1:add(p2).x)
```

struct fields are validated at construction time. methods defined inside
the struct body are stored on the instances, not on a shared prototype.

# # functions

functions are first-class. the `fn` keyword defines one:

```ruby
fn add(a, b) a + b # single-expression shorthand
const hi = fn(a, b) a + b # same thing, anonymous

# multi-line with do...end
fn add(a, b) do
    if a < 0 do
        return 0
    end
    a + b
end
```

`return` exits the function immediately with a value:

```ruby
fn maybe_double(x) do
    if x > 100 return x
    x * 2
end
```

closures capture outer variables by reference:

```ruby
fn make_counter() do
    let x = 0
    const inc = fn() do
        x = x + 1
        x
    end
    inc
end

const c = make_counter()
print(c()) # 1
print(c()) # 2
```

method-definition syntax attaches a function to a table or struct:

```ruby
fn obj.field(params) body
# same as:
obj.field = fn(params) body
```

the colon-sugar variant for implicit self:

```ruby
fn obj:method(params) body
# same as:
obj.method = fn(self, params) body
# (the name 'self' is implicit)
```

named parameters are supported, too!

```ruby
fn add(x: num, y: num) x + y
add(x = 5, y = 3)
add(y = 3, x = 5) # reordered
```

# # control flow

# # # if/else

`if` runs & returns the chosen branch

```ruby
const grade = if score >= 70 do
    "pass"
end else do
    "fail"
end

# single-expression branches (no do...end needed outside a pipe)
const a = if 1 == 1 5 else 42
```

# # # while

```ruby
let i = 0
while i < 5 do
    i = i + 1
end
```

the body is compiled first, so the while expression returns the body's
value on the first iteration where the condition is false (else-value
semantics):

```ruby
let x = while false do 42 end # x = 42
```

# # # loop

`loop` creates an infinite loop. `break` exits it with a value:

```ruby
const result = loop do
    if x >= 10 do
        break(x)
    end
    x = x + 1
end
```

# # # for range

`0..5` produces the sequence 0, 1, 2, 3, 4 (inclusive start, exclusive
end). `0..2..10` steps by 2: 0, 2, 4, 6, 8:

```ruby
let sum = 0
for i in 0..5 do
    sum = sum + i
end
print(sum) # 10
```

# # # for in

`for x in obj` iterates using `obj:len()` and `obj[idx]` access. tuples,
strings, and tables each have built-in access patterns. user types can
define iteration by providing `:len()` and `__iter(self, idx)`:

```ruby
# for in with index binding
for val, i in {10, 20, 30} do
    print(i, val)
end
```

# # match

`match` is pattern matching as an expression:

```ruby
const r = match x
    | 1 => "one"
    | 2 => "two"
    | _ => "other"

# guards with when
const tier = match score
    | v when v >= 90 => "A"
    | v when v >= 70 => "B"
    | v              => "C"

# destructuring result tuples
match safe_div(10, 0)
    | (:ok, v)  => print(v)
    | (:err, e) => print(fmt("error: %v", e))
```

arms can be single expressions or `do...end` blocks:

```ruby
match x
    | (:ok, v) => do
        process(v)
        v * 2
    end
    | (:err, _) => 0
```

# # pipes

the pipe `|>` passes the left-hand side as the first argument to the
right-hand side:

```ruby
fn double(x) x * 2
fn and_both(x, a, b) x + a + b

21 |> double # 42
5 |> and_both(1, 2) # 8 (becomes and_both(5, 1, 2))
"hello" |> print

# chaining
20 |> double |> fn(x) x + 2 # 42
```

the placeholder `_` marks where the piped value goes:

```ruby
# method call on piped value
"asdf"
    |> _:upper()
    |> _:sub(1, 2)
    |> print # "SD"

# in an expression
"asdf" |> "aaa" + _:upper() # "aaaASDF"

# as a specific arg position
fn fmt(s, v) s + v
"asdf" |> fmt("got: ", _) # "got: asdf"

# multiple placeholders
fn add(a, b) a + b
5 |> add(_, _) # 10
```

pipe into match:

```ruby
x |> match
    | v when v > 0 => "positive"
    | _            => "non-positive"
```

pipes pair well with `?` and `orelse`:

```ruby
const n = tonumber("41") orelse 0
n |> fn(x) x + 1
```

# # iteration

`map`, `filter`, `reduce`, `each`, `find`, `all?`, and `any?` work on
strings, tuples, and tables:

```ruby
map((1, 2, 3), fn(x) x * 2) # (2, 4, 6)
filter("hello", fn(c) c != "l") # "heo"
reduce((1,2,3,4), fn(acc, x) acc + x, 0) # 10
each({a=1, b=2}, fn(v) print(v)) # side effects, returns :ok
find((1,2,3,4), fn(x) x > 2) # 3
all?((1,2,3), fn(x) x > 0) # :true
any?((1,2,3), fn(x) x > 2) # :true
```

these are also available as methods:

```ruby
(1, 2, 3):map(fn(x) x * 2)
```

# # error handling

revo does not have exceptions. functions that can fail return
`(:ok, value)` or `(:err, :ErrorName)`:

```ruby
fn safe_div(a, b) do
    if b == 0 (:err, :DivByZero)
    else (:ok, a / b)
end

match safe_div(10, 0)
    | (:ok, v)  => print(v)
    | (:err, :DivByZero) => print("divide by zero")
```

# # # ? operator

`?` unwraps a result tuple. if it's `(:ok, val)`, the expression
evaluates to `val`. if it's `(:err, ...)`, the function returns
immediately with that error. at toplevel it panics:

```ruby
fn parse_int(s) tonumber(s)?

fn load_config(path) do
    const f = fs.open(path)? # unwrap or return error
    const raw = f:read() orelse "<none>"
    parse_json(raw)
end
```

# # # orelse

`orelse` provides a fallback when the left side is `nil` or
`(:err, ...)`:

```ruby
const name = read_file("name.txt") orelse "unknown"
const x = (:err, :not_found) orelse 0 # x = 0
const y = nil orelse 0 # y = 0
const z = (:ok, 42) orelse 0 # z = 42
```

`orelse` also works as a general nil-coalescing operator for any value.

# # # result helpers

```ruby
(:ok, 42):unwrap() # 42 (panics if :err)
(:err, :bad):unwrap_err() # :bad (panics if :ok)
ok?!((:ok, 42)) # :true
err?!((:err, :Bad)) # :true
```

# # tests

`test` blocks define tests that only run with the `--test` flag:

```ruby
fn add(a, b) a + b

test "addition" do
    expect(add(20, 22) == 42)?
    expect(add(20, 22) != 22)?
end

# skip a test
test/skip "not ready yet" do
    expect(add(2, 3) == 5)?
end

# suite groups related tests
suite "math" do
    fn mul(a, b) a * b
    
    test "add" do expect(add(1, 1) == 2)? end
    test "mul" do expect(mul(3, 4) == 12)? end
end
```

tests see the same module scope as the rest of the file.
`expect(cond)?` returns `(:ok, val)` on truthy, `(:err, :ExpectFailed)`
on falsy -- the `?` propagates the error out of the test.

```ruby
expect_eq(add(2, 3), 5)? # built-in helper
```

## fibers
make your non-blocking code look blocking. just slap a `spawn` before it

`spawn` creates a new fiber,
`yield` gives the wheel over to the next fiber
`join` blocks until it completes:

```ruby
const f1 = spawn fn() reduce((1,2,3), fn(a,b) a + b, 0)
const f2 = spawn fn() "async res"

print(join(f1)) # 6
print(join(f2)) # "async res"

# join(nil) is a no-op for detached fibers
```
channels coordinate fibers. `chan(n)` creates a buffered channel with
capacity `n`. `chan(0)` is unbuffered (sender blocks until receiver is
ready):

```ruby
# unbuffered
const ch = chan(0)
const s = spawn fn(c) send(c, 42) (ch)
recv(ch) # 42
join(s)

# buffered
const bch = chan(2)
send(bch, 10)
send(bch, 32)
recv(bch) + recv(bch) # 42
```

`yield` suspends the current fiber. `sleep(ms)`aaand io parks it:

```ruby
do yield end
sleep(100)
```

fiber states: running, suspended, parked (waiting on a timer or
channel), and done. the main fiber runs first; the run queue is fifo

## stdlib
check it out at [./std](./std)

## imports

`import` loads a module file and caches it; the same path always
returns the same value:

```ruby
#
# counter.rv
#
let count = 0
{count = count} # this becomes the module value

#
# main.rv
#
const a = import "counter"
a.count = 41
const b = import "counter"
print(b.count) # 41 (same cached table)
```

module-level `let` and `const` are private to the module. only the
returned value is visible to the importer

## comptime

`comp` evaluates an expression at compile time and bakes the result
straight into the bytecode:

```ruby
const LIMIT = comp (1024 * 1024)
print(comp ("prefix_" + "suffix")) # prefix_suffix
print(comp (1 < 2)) # :true
```

## macros

macros are compile-time code transformers using pattern matching:

```ruby
# syntax: macro name `pattern` `template`
# %e:expr   - capture any expression
# %n:ident  - capture an identifier
# %s:str    - capture a string literal

macro unless! `(%cond:expr %body:expr)` `if %cond :nil else %body`
unless!(:false, 42) # 42

# repetition groups
# %REST(...)* - zero or more
# %REST(...)+ - one or more

macro sum_all! `(%first:expr %REST(%item:expr)*)` `%first %REST(+ %item)`
sum_all!(10, 15, 17) # 42
```

preloaded macros:

```ruby
unless!(:false, 42) # 42
all_true!(1, :true, "t", 1) # :true
```

### proc macros

`proc` defines a compile-time function that receives the raw AST node.
it can generate arbitrary code at compile time:

```ruby
proc symbol_table(...)
# receives ast nodes, emits code
```

## metatables

metatables customize table behavior. set one with `set_metatable(val, mt)`
or `val:set_meta(mt)`:

```ruby
const mt = {
    __tostring = fn(self) "MyObj",
    __display  = fn(self) "MyObj",       # used by fmt %v, falls back to __tostring
    __index    = fn(self, key) 0,        # called when a field is missing
    __newindex = fn(self, key, val) nil, # intercept assignment
}
const t = set_metatable({}, mt)

t.missing # 0 (via __index)
t.x = 5 # intercepted by __newindex
print(t) # uses __tostring
```

plain table fields always resolve before `__index` is called.
metatable methods (like `get_x`) resolve before `__index` too, which is
how `obj:method()` works:

```ruby
const mt = {get_x = fn(self) self.x}
const t = set_metatable({x = 12}, mt)
t:get_x() # 12
```

user types can define `__iter(self, idx)` for iteration with `for x in obj`:

```ruby
const Range = set_metatable({}, {
    len = fn(self) self.end - self.start + 1,
    __iter = fn(self, idx) self.start + idx,
})
for x in Range{start = 1, end = 5}
    print(x) # 1, 2, 3, 4, 5
```

# highly idiomatic code
```nim

@doc"""
safely do $a/b$

# math notation should be typst
` ``typst
a/b forall b != 0 \
":DivisionByZero" "if" b == 0 \
":SomethingElse" "if" b == 0
` ``

>> safe_div(4, 2)
   (:ok, 2)
>> safe_div(4, 0)
   (:err, :DivisionByZero)

* errors:
- :DivisionByZero
  on passing 0 as b
"""
fn safe_div(a: num, b: num) -> (:ok, num) | (:err, :DivisionByZero | :SomethingElse)
    match b
    | 0 => (:err, :DivisionByZero)
    | 1337 => (:err, :SomethingElse)
    | x => a / x

#
# a complex function (nyi)
# this is supposed to be the most complex the type system can get
#   as well as the most unreadable that idiomatic code can get, when written right
#
# !!!!!this doesn't work yet, because
#   generics, doctests and `of` in match do not exist yet
# 
type CheckResults<A, B> = table<{idx: num, wanted: A, got: B}
type CheckTest<A, B>    = {in: A, out: B} | fn(A) -> bool
@doc"""
checks if all `condition`s are satisfied for `domain`
* returns
- :ok
  on all conditions passing
- table<{idx: num, wanted: any, got: any}>
  on at least one condition not passing

>> let tests = { 
 >   {in: 1, out: -1}, 
 >   fn(f) f(12) == 21,
 >   {in: 0, out: 999} 
 > }
 > check(fn(c) (c * 2) - 3, tests)
   { {idx: 2, wanted: 999, got: -3} }
"""
fn check<F: fn(A, B) -> any>(
    target_fn: F, 
    conditions: table<CheckTest<A, B>>
) -> :ok | CheckResults<A, B>>
do
    let fails: CheckResults = {}
    
    for cond, idx in conditions
        match cond
        | x of function => do
            if not cond(target_fn)
               fails = fails + { {idx = idx, wanted = :true, got = :false} }
        end
        | x of CheckTest<A, B> => do
            if target_fn(cond.in) != cond.out
              fails = fails + { {idx = idx, wanted = cond.out, got = actual} }
        end
    
    return if length(fails) == 0
        :ok
    else fails
end
```
