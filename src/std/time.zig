pub const specs: []const api.FnSpec = &.{
    .{
        .name = "now",
        .placements = &.{api.mod("time")},
        .params = &.{},
        .ret = "number",
        .doc = "returns current wall-clock time in milliseconds",
        .f = root.define(&.{}, now_ms),
    },
    .{
        .name = "now_ns",
        .placements = &.{api.mod("time")},
        .params = &.{},
        .ret = "number",
        .doc = "returns current wall-clock time in nanoseconds",
        .f = root.define(&.{}, now_ns),
    },
    .{
        .name = "monotonic",
        .placements = &.{api.mod("time")},
        .params = &.{},
        .ret = "number",
        .doc = "returns monotonic clock in milliseconds",
        .f = root.define(&.{}, monotonic_ms),
    },
    .{
        .name = "monotonic_ns",
        .placements = &.{api.mod("time")},
        .params = &.{},
        .ret = "number",
        .doc = "returns monotonic clock in nanoseconds",
        .f = root.define(&.{}, monotonic_ns),
    },
    .{
        .name = "sleep",
        .placements = &.{api.mod("time")},
        .params = &.{
            .{ "ms", "number" },
        },
        .ret = "parked",
        .doc = "parks current fiber for given milliseconds",
        .f = root.define(&.{.number}, root.sleep),
    },
};

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

const std = @import("std");

const revo = @import("../root.zig");
const Data = revo.Data;
const VM = revo.VM;
const api = @import("api.zig");
const root = @import("root.zig");
const NativeResult = root.NativeResult;
