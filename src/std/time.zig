const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");

const Data = revo.Data;
const VM = revo.VM;
const NativeResult = root.NativeResult;

pub fn register(vm: *VM) !void {
    try root.registerTableFunctions(vm, "time", &[_]root.FuncDef{
        .{ .name = "now", .f = root.define(&.{}, now_ms) },
        .{ .name = "now_ns", .f = root.define(&.{}, now_ns) },
        .{ .name = "monotonic", .f = root.define(&.{}, monotonic_ms) },
        .{ .name = "monotonic_ns", .f = root.define(&.{}, monotonic_ns) },
        .{ .name = "sleep", .f = root.define(&.{.number}, root.sleep) },
    });
}

fn now_ms(_: []const Data, vm: *VM) !NativeResult {
    const ts = std.Io.Clock.real.now(vm.runtime.io);
    return .{ .ok = Data.new.num(ts.toMilliseconds()) };
}

fn now_ns(_: []const Data, vm: *VM) !NativeResult {
    const ts = std.Io.Clock.real.now(vm.runtime.io);
    return .{ .ok = Data.new.num(ts.toNanoseconds()) };
}

fn monotonic_ms(_: []const Data, vm: *VM) !NativeResult {
    const ts = std.Io.Clock.awake.now(vm.runtime.io);
    return .{ .ok = Data.new.num(ts.toMilliseconds()) };
}

fn monotonic_ns(_: []const Data, vm: *VM) !NativeResult {
    const ts = std.Io.Clock.awake.now(vm.runtime.io);
    return .{ .ok = Data.new.num(ts.toNanoseconds()) };
}

test "time module works probably" {
    const testing = revo.lang.testing;

    try testing.top_true("time.now() > 0");
    try testing.top_true("time.monotonic() >= 0");
}
