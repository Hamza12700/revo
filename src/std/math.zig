// zig fmt: off
const MathOps = struct {
    pub fn abs(x: f64) f64 { return @abs(x); }
    pub fn floor(x: f64) f64 { return @floor(x); }
    pub fn ceil(x: f64) f64 { return @ceil(x); }
    pub fn sqrt(x: f64) f64 { return @sqrt(x); }
    pub fn pow(base: f64, exponent: f64) f64 { return std.math.pow(f64, base, exponent); }
    pub fn sin(x: f64) f64 { return @sin(x); }
    pub fn cos(x: f64) f64 { return @cos(x); }
    pub fn tan(x: f64) f64 { return @tan(x); }
    pub fn log(x: f64) f64 { return @log(x); }
    pub fn exp(x: f64) f64 { return @exp(x); }
};

const Pred = struct {
    pub fn nonNegative(x: f64) bool { return x >= 0; }
    pub fn positive(x: f64) bool { return x > 0; }
    pub fn less(a: f64, b: f64) bool { return a < b; }
    pub fn greater(a: f64, b: f64) bool { return a > b; }
};
// zig fmt: on

//
// generators
//
fn makeUnary(comptime op: fn (f64) f64) root.NativeFn {
    return struct {
        fn apply(args: []const Data, _: *VM) !NativeResult {
            return .{ .ok = Data.new.num(op(toF64(args[0]))) };
        }
    }.apply;
}

fn makeUnaryChecked(
    comptime op: fn (f64) f64,
    comptime check: fn (f64) bool,
    comptime expected: []const u8,
) root.NativeFn {
    return struct {
        fn apply(args: []const Data, _: *VM) !NativeResult {
            const n = toF64(args[0]);
            if (!check(n))
                return .errType(0, expected, dataToString(args[0]));
            return .{ .ok = Data.new.num(op(n)) };
        }
    }.apply;
}

fn makeBinary(comptime op: fn (f64, f64) f64) root.NativeFn {
    return struct {
        fn apply(args: []const Data, _: *VM) !NativeResult {
            return .{ .ok = Data.new.num(op(toF64(args[0]), toF64(args[1]))) };
        }
    }.apply;
}

fn makeVariadic(comptime cmp: fn (f64, f64) bool) root.NativeFn {
    return struct {
        /// returns min or max of all arguments
        fn apply(args: []const Data, _: *VM) !NativeResult {
            var res = toF64(args[0]);
            for (args[1..]) |arg| {
                const val = toF64(arg);
                if (cmp(val, res)) res = val;
            }
            return .{ .ok = Data.new.num(res) };
        }
    }.apply;
}

pub const specs: []const api.FnSpec = &.{
    .{
        .name = "abs",
        .placements = &.{api.mod("math")},
        .params = &.{
            .{ "x", "number" },
        },
        .ret = "number",
        .doc = "absolute value",
        .f = root.define(&.{.number}, makeUnary(MathOps.abs)),
    },
    .{
        .name = "floor",
        .placements = &.{api.mod("math")},
        .params = &.{
            .{ "x", "number" },
        },
        .ret = "number",
        .doc = "floor of x",
        .f = root.define(&.{.number}, makeUnary(MathOps.floor)),
    },
    .{
        .name = "ceil",
        .placements = &.{api.mod("math")},
        .params = &.{
            .{ "x", "number" },
        },
        .ret = "number",
        .doc = "ceiling of x",
        .f = root.define(&.{.number}, makeUnary(MathOps.ceil)),
    },
    .{
        .name = "sqrt",
        .placements = &.{api.mod("math")},
        .params = &.{
            .{ "x", "number" },
        },
        .ret = "number",
        .doc = "square root, errors if x is negative",
        .f = root.define(&.{.number}, makeUnaryChecked(MathOps.sqrt, Pred.nonNegative, "non-negative number")),
    },
    .{
        .name = "pow",
        .placements = &.{api.mod("math")},
        .params = &.{
            .{ "base", "number" },
            .{ "exponent", "number" },
        },
        .ret = "number",
        .doc = "base raised to exponent",
        .f = root.define(&.{ .number, .number }, makeBinary(MathOps.pow)),
    },
    .{
        .name = "min",
        .placements = &.{api.mod("math")},
        .params = &.{
            .{ "args", "number..." },
        },
        .ret = "number",
        .doc = "min of all arguments",
        .variadic = true,
        .f = root.defineVariadic(&.{.number}, makeVariadic(Pred.less)),
    },
    .{
        .name = "max",
        .placements = &.{api.mod("math")},
        .params = &.{
            .{ "args", "number..." },
        },
        .ret = "number",
        .doc = "max of all arguments",
        .variadic = true,
        .f = root.defineVariadic(&.{.number}, makeVariadic(Pred.greater)),
    },
    .{
        .name = "sin",
        .placements = &.{api.mod("math")},
        .params = &.{
            .{ "x", "number" },
        },
        .ret = "number",
        .doc = "sine of x (x in radians)",
        .f = root.define(&.{.number}, makeUnary(MathOps.sin)),
    },
    .{
        .name = "cos",
        .placements = &.{api.mod("math")},
        .params = &.{
            .{ "x", "number" },
        },
        .ret = "number",
        .doc = "cosine of x (x in radians)",
        .f = root.define(&.{.number}, makeUnary(MathOps.cos)),
    },
    .{
        .name = "tan",
        .placements = &.{api.mod("math")},
        .params = &.{
            .{ "x", "number" },
        },
        .ret = "number",
        .doc = "tangent of x (x in radians)",
        .f = root.define(&.{.number}, makeUnary(MathOps.tan)),
    },
    .{
        .name = "log",
        .placements = &.{api.mod("math")},
        .params = &.{
            .{ "x", "number" },
        },
        .ret = "number",
        .doc = "natural logarithm, panics if x <= 0",
        .f = root.define(&.{.number}, makeUnaryChecked(MathOps.log, Pred.positive, "positive number")),
    },
    .{
        .name = "exp",
        .placements = &.{api.mod("math")},
        .params = &.{
            .{ "x", "number" },
        },
        .ret = "number",
        .doc = "e raised to x",
        .f = root.define(&.{.number}, makeUnary(MathOps.exp)),
    },
};

test "math library" {
    try testing.top_number("math.abs(-5)", 5);
    try testing.top_number("math.abs(5)", 5);
    try testing.top_number("math.floor(3.7)", 3);
    try testing.top_number("math.ceil(3.2)", 4);
    try testing.top_number("math.sqrt(4)", 2);
    try testing.top_number("math.pow(2, 3)", 8);
    try testing.top_number("math.min(1, 2, 3)", 1);
    try testing.top_number("math.max(1, 2, 3)", 3);
}

// .number is guaranteed by type sig
inline fn toF64(d: Data) f64 {
    return d.asNum().?;
}

const std = @import("std");

const revo = @import("../root.zig");
const testing = revo.lang.testing;
const Data = revo.Data;
const VM = revo.VM;
const api = @import("api.zig");
const root = @import("root.zig");
const NativeResult = root.NativeResult;
const dataToString = root.dataToString;
