# types

the compiler infers them, tracks them, and uses them to pick fast paths
they will fall back to `any` when they can't be inferred

```ruby
let factor: int = 2
fn double(n: int) -> int do
  n * factor
end

# inferred as int
let count = 0
count = count + 1 

# inferred as float
let ratio = 3.14 / 2.0

# struct with fixed offsets
# much faster than a table!
struct User {
    age: number = 0,
    height: number = 7,
}

let user: User = User{}

user.age = 21
user.height = 1

print(user)
```

## core types

`TypeInfo` in `types.zig` is the single source of truth. it tags values at compile time so the emitter can pick hot paths without runtime checks

```zig
pub const TypeInfo = union(enum) {
    void, bool, int, float, string, atom: []const u8,
    tuple: []const TypeInfo, struct_type: []const u8,
    function: *const FunctionSignature, any,
};
```

## struct layouts

typed structs skip hash lookups entirely. `struct_layout.zig` calculates fixed offsets during `compileStruct`. `bool` takes 1 byte, `int` and `float` take 8, pointers take 16. the `StructLayouter` registry stores these so `resolveTypedStructFieldOffset` maps `user.name` to a constant index at emit time

```zig
// struct_layout.zig
const field_size = sizeOfType(def.field_type);
offset = alignPointer(offset, @min(alignment, field_size));
try fields.append(self.alloc, .{ .name = try self.alloc.dupe(u8, def.name), .offset = off, .size = field_size });
```
