const std = @import("std");
const revo = @import("revo");
const ast = @import("../ast.zig");

pub const UnionVariant = struct {
    name: []const u8,
    types: []const TypeInfo,
};

pub const TypeInfo = union(enum) {
    // TODO: remove
    void,
    bool,
    // TODO: maybe unify here maybe split at vm
    int,
    float,
    string,
    atom: []const u8,
    tuple: []const TypeInfo,
    @"union": []const UnionVariant,
    struct_type: []const u8,
    function: *const FunctionSignature,
    any,

    pub fn eql(self: TypeInfo, other: TypeInfo) bool {
        return switch (self) {
            .void => other == .void,
            .bool => other == .bool,
            .int => other == .int,
            .float => other == .float,
            .string => other == .string,
            .atom => |a| if (other == .atom) std.mem.eql(u8, atomPayload(a), atomPayload(other.atom)) else false,
            .struct_type => |s| if (other == .struct_type) std.mem.eql(u8, s, other.struct_type) else false,
            .tuple => |ts| if (other == .tuple) blk: {
                if (ts.len != other.tuple.len) break :blk false;
                for (ts, other.tuple) |a, b| if (!eql(a, b)) break :blk false;
                break :blk true;
            } else false,
            .@"union" => |us| if (other == .@"union") blk: {
                if (us.len != other.@"union".len) break :blk false;
                for (us, other.@"union") |a, b| {
                    if (!std.mem.eql(u8, a.name, b.name)) break :blk false;
                    if (a.types.len != b.types.len) break :blk false;
                    for (a.types, b.types) |at, bt| if (!eql(at, bt)) break :blk false;
                }
                break :blk true;
            } else false,
            .function => |f| if (other == .function) f == other.function else false,
            .any => true,
        };
    }
};

pub fn atomPayload(name: []const u8) []const u8 {
    return if (name.len > 0 and name[0] == ':') name[1..] else name;
}

pub const FunctionSignature = struct { params: []const TypeInfo, return_type: TypeInfo };

pub fn typeName(T: TypeInfo) []const u8 {
    return switch (T) {
        .struct_type => |s| s,
        .atom => |a| a,
        else => @tagName(T),
    };
}

pub fn isNumeric(T: TypeInfo) bool {
    return T == .int or T == .float;
}

pub fn canCoerce(from: TypeInfo, to: TypeInfo) bool {
    if (from.eql(to) or to == .any or from == .any) return true;
    if (to == .@"union") {
        // fast-path for atom literals vs atom-only variants
        if (from == .atom) {
            for (to.@"union") |variant| {
                if (variant.name.len == 0 and variant.types.len == 1 and variant.types[0] == .atom) {
                    if (std.mem.eql(u8, atomPayload(variant.types[0].atom), atomPayload(from.atom))) return true;
                }
                if (variant.name.len != 0 and variant.types.len == 0) {
                    if (std.mem.eql(u8, atomPayload(variant.name), atomPayload(from.atom))) return true;
                }
            }
        }
        for (to.@"union") |variant| {
            if (unionVariantAccepts(variant, from)) return true;
        }
    }
    if (from == .@"union") {
        if (from.@"union".len == 0) return false;
        for (from.@"union") |variant| {
            if (!targetAcceptsVariant(variant, to)) return false;
        }
        return true;
    }
    return from == .int and to == .float;
}

fn unionVariantAccepts(variant: UnionVariant, value: TypeInfo) bool {
    if (variant.name.len != 0) {
        // named (tagged) variant
        if (variant.types.len == 0) {
            // atom-only variant accepts plain atoms with matching payload
            return value == .atom and std.mem.eql(u8, atomPayload(value.atom), atomPayload(variant.name));
        }
        if (value != .tuple) return false;
        if (value.tuple.len != variant.types.len + 1) return false;
        if (value.tuple[0] != .atom) return false;
        if (!std.mem.eql(u8, atomPayload(value.tuple[0].atom), atomPayload(variant.name))) return false;
        for (variant.types, 0..) |expected, i| {
            if (!canCoerce(value.tuple[i + 1], expected)) return false;
        }
        return true;
    }

    if (variant.types.len == 1) return canCoerce(value, variant.types[0]);
    if (value != .tuple) return false;
    if (value.tuple.len != variant.types.len) return false;
    for (variant.types, value.tuple) |expected, actual| {
        if (!canCoerce(actual, expected)) return false;
    }
    return true;
}

fn targetAcceptsVariant(variant: UnionVariant, target: TypeInfo) bool {
    if (variant.name.len != 0) {
        // named variant
        if (variant.types.len == 0) {
            // atom-only variant is acceptable by plain atom target
            return target == .atom and std.mem.eql(u8, atomPayload(target.atom), atomPayload(variant.name));
        }
        if (target != .tuple) return false;
        if (target.tuple.len != variant.types.len + 1) return false;
        if (target.tuple[0] != .atom) return false;
        if (!std.mem.eql(u8, atomPayload(target.tuple[0].atom), atomPayload(variant.name))) return false;
        for (variant.types, 0..) |source, i| {
            if (!canCoerce(source, target.tuple[i + 1])) return false;
        }
        return true;
    }

    if (variant.types.len == 1) return canCoerce(variant.types[0], target);
    if (target != .tuple) return false;
    if (target.tuple.len != variant.types.len) return false;
    for (variant.types, target.tuple) |source, expected| {
        if (!canCoerce(source, expected)) return false;
    }
    return true;
}

pub fn inferBinaryOp(op: ast.BinOp, l: TypeInfo, r: TypeInfo) TypeInfo {
    return switch (op) {
        .@"union" => .any,
        .add, .sub, .mul, .div, .mod => blk: {
            if (l == .int and r == .int) break :blk .int;
            if (isNumeric(l) and isNumeric(r)) break :blk .float;
            break :blk .any;
        },
        .eq, .neq, .lt, .gt, .lte, .gte => .bool,
    };
}

pub fn inferUnaryOp(op: ast.UnOp, T: TypeInfo) TypeInfo {
    return switch (op) {
        .negate => if (isNumeric(T)) T else .any,
        .not => .bool,
        .spawn, .join, .yield => .any,
    };
}

test "types: TypeInfo equality" {
    const int_type: revo.lang.compiler.types.TypeInfo = .int;
    const any_type: revo.lang.compiler.types.TypeInfo = .any;

    try std.testing.expect(int_type.eql(.int));
    try std.testing.expect(!int_type.eql(.float));
    try std.testing.expect(any_type.eql(.any));
}

test "types: numeric type check" {
    const types = revo.lang.compiler.types;
    try std.testing.expect(types.isNumeric(.int));
    try std.testing.expect(types.isNumeric(.float));
    try std.testing.expect(!types.isNumeric(.string));
    try std.testing.expect(!types.isNumeric(.any));
}

test "types: type coercion" {
    const types = revo.lang.compiler.types;
    try std.testing.expect(types.canCoerce(.int, .int));
    try std.testing.expect(types.canCoerce(.int, .float));
    try std.testing.expect(!types.canCoerce(.float, .int)); // float doesn't coerce to int
    try std.testing.expect(types.canCoerce(.int, .any)); // anything to any
    try std.testing.expect(types.canCoerce(.any, .int)); // any to anything (optimistic)
}

test "types: binary op inference - arithmetic" {
    const types = revo.lang.compiler.types;
    const add_int_int = types.inferBinaryOp(.add, .int, .int);
    try std.testing.expect(add_int_int.eql(.int));

    const add_float_float = types.inferBinaryOp(.add, .float, .float);
    try std.testing.expect(add_float_float.eql(.float));

    const add_int_float = types.inferBinaryOp(.add, .int, .float);
    try std.testing.expect(add_int_float.eql(.float));
}

test "types: binary op inference - comparison" {
    const types = revo.lang.compiler.types;
    const cmp = types.inferBinaryOp(.eq, .int, .int);
    try std.testing.expect(cmp.eql(.bool));

    const cmp2 = types.inferBinaryOp(.lt, .float, .float);
    try std.testing.expect(cmp2.eql(.bool));
}

test "types: unary op inference" {
    const types = revo.lang.compiler.types;
    const negate_int = types.inferUnaryOp(.negate, .int);
    try std.testing.expect(negate_int.eql(.int));

    const not_bool = types.inferUnaryOp(.not, .bool);
    try std.testing.expect(not_bool.eql(.bool));
}

//
// type system
//
const lang = revo.lang;
const t = lang.testing;
const VM = revo.VM;

test "typed binding int accepts int literal" {
    try t.top_number(
        \\ let x: int = 42
        \\ x
    , 42);
}

test "typed binding float accepts float literal" {
    try t.top_number(
        \\ let x: float = 3.14
        \\ x
    , 3.14);
}

test "typed binding int accepts int literal coerced to float" {
    try t.top_number(
        \\ let x: float = 10
        \\ x
    , 10.0);
}

test "typed binding rejects string for int" {
    try t.expectCompileError(
        \\ let x: int = "hello"
    , .ParseError);
}

test "typed binding rejects float for int" {
    try t.expectCompileError(
        \\ let x: int = 3.14
    , .ParseError);
}

test "typed binding rejects int for string" {
    try t.expectCompileError(
        \\ let x: string = 42
    , .ParseError);
}

test "typed function params accept correct types" {
    try t.top_number(
        \\ const add = fn(a: int, b: int) a + b
        \\ add(3, 4)
    , 7);
}

test "typed function rejects wrong arg type" {
    try t.expectCompileError(
        \\ const add = fn(a: int, b: int) a + b
        \\ add(3, "wrong")
    , .ParseError);
}

test "typed function rejects first arg wrong type" {
    try t.expectCompileError(
        \\ const add = fn(a: int, b: int) a + b
        \\ add("wrong", 4)
    , .ParseError);
}

test "atom union alias accepts literal and alias value in calls" {
    try t.top_atom(
        \\ type A = :one | :two
        \\ fn pick(how: A) -> any do
        \\   how
        \\ end
        \\ let pred: A = :one
        \\ pick(pred)
    , "one");

    try t.top_atom(
        \\ type A = :one | :two
        \\ fn pick(how: A) -> any do
        \\   how
        \\ end
        \\ let pred: A = :one
        \\ pick(:two)
    , "two");
}

test "typed struct field access" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ struct User {
        \\     name: string = "",
        \\     age: number = 0,
        \\ }
        \\ let u: User = User { name = "alice", age = 30 }
        \\ u.age
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_get = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .struct_get_offset) saw_get = true;
    }
    try std.testing.expect(saw_get);
}

test "typed struct field assignment rejects wrong type" {
    try t.expectCompileError(
        \\ struct User {
        \\     name: string = "",
        \\     age: int = 0,
        \\ }
        \\ let u: User = User { name = "alice", age = 30 }
        \\ u.name = 42
    , .ParseError);
}

test "typed struct field assignment accepts correct type" {
    try t.top_number(
        \\ struct User {
        \\     name: string = "",
        \\     age: number = 0,
        \\ }
        \\ let u: User = User { name = "alice", age = 30 }
        \\ u.age = 42
        \\ u.age
    , 42);
}

test "binary int + int emits add_int" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: int = 5
        \\ let b: int = 3
        \\ a + b
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_int = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_int) saw_add_int = true;
    }
    try std.testing.expect(saw_add_int);
}

test "binary float + float emits add_int" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: float = 1.5
        \\ let b: float = 2.5
        \\ a + b
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_int = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_int) saw_add_int = true;
    }
    try std.testing.expect(saw_add_int);
}

test "negate int emits negate_int" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let x: int = 5
        \\ let y = -x
        \\ y
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_neg_int = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .negate_int) saw_neg_int = true;
    }
    try std.testing.expect(saw_neg_int);
}

test "comparison int == int emits eq_int" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: int = 5
        \\ let b: int = 5
        \\ a == b
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_eq_int = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .eq_int) saw_eq_int = true;
    }
    try std.testing.expect(saw_eq_int);
}

test "untyped code still works" {
    try t.top_number("1 + 2 * 3", 7);
    try t.top_number(
        \\ let x = 10
        \\ x + 5
    , 15);
    try t.top_string(
        \\ let s = "hello"
        \\ s
    , "hello");
}

test "mixed int and float falls back to generic add" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: int = 5
        \\ let b: float = 2.5
        \\ a + b
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_generic_add = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add) saw_generic_add = true;
    }
    try std.testing.expect(saw_generic_add);
}

test "nested function with typed params" {
    try t.top_number(
        \\ const outer = fn(x: int) do
        \\     const inner = fn(y: int) y * 2
        \\     inner(x) + 1
        \\ end
        \\ outer(5)
    , 11);
}

test "function call with multiple typed params" {
    try t.top_number(
        \\ const calc = fn(a: int, b: float, c: int) do
        \\     a + b + c
        \\ end
        \\ calc(1, 2.5, 3)
    , 6.5);
}

test "return type validation accepts correct type" {
    try t.top_number(
        \\ const get_num = fn() -> int do
        \\     return 42
        \\ end
        \\ get_num()
    , 42);
}

test "atoms<->any relationship" {
    try t.top_number(
        \\ const get_num = fn() -> int do
        \\     return 42
        \\ end
        \\ get_num()
    , 42);
}
