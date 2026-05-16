const std = @import("std");
const testing = std.testing;

const revo = @import("revo");
const Data = revo.Data;

const VM = @import("VM.zig").VM;
const Scheduler = revo.vm.Scheduler;
const vt = @import("testing.zig");

fn trigger_gc(vm: *VM) void {
    vm.gc_pending = true;
    vm.maybeCollectGarbage();
}

fn return_one(_: []const Data, _: *VM) revo.functions.NativeError!Data {
    return Data.new.num(1);
}

fn fakeIoReady(_: *VM, _: *Scheduler.WaitEntry, _: i16) anyerror!Scheduler.IoDispatchResult {
    return .{};
}

test "vm join returns dead fiber result" {
    var vm = try VM.init(vt.runtime());
    defer vm.deinit();

    const child = try VM.Fiber.init(vm.runtime.alloc, 1, &.{});
    try vm.sched.fibers.append(vm.runtime.alloc, child);
    vm.sched.fibers.items[1].state = .dead;
    vm.sched.fibers.items[1].result = Data.new.num(42);

    const handle = try vm.addConstant(Data.new.num(1));
    const program = [_]revo.Instruction{
        .{ .op = .load_const, .a = 0, .bx = handle },
        .{ .op = .join, .a = 0 },
        .{ .op = .halt, .a = 0 },
    };
    vm.mainFiber().program = &program;
    _ = try vm.runReport();

    const out = vm.mainResult();
    try testing.expectEqual(@as(f64, 42), out.number);
}

test "vm join parks current fiber when target alive" {
    return error.SkipZigTest;
    // var vm = try VM.init(vt.runtime());
    // defer vm.deinit();
    //
    // const child = try VM.Fiber.init(vm.runtime.alloc, 1, &.{});
    // try vm.sched.fibers.append(vm.runtime.alloc, child);
    // vm.sched.fibers.items[1].state = .ready;
    //
    // const handle = try vm.addConstant(Data.new.num(1));
    // const program = [_]revo.Instruction{
    //     .{ .op = .load_const, .a = 0, .bx = handle },
    //     .{ .op = .join, .a = 0 },
    //     .{ .op = .halt, .a = 0 },
    // };
    // vm.mainFiber().program = &program;
    // _ = try vm.runReport();
    //
    // try testing.expectEqual(@as(VM.Fiber.State, .waiting), vm.currentFiber().state);
    // try testing.expectEqual(@as(bool, false), vm.currentFiber().running);
    // try testing.expectEqual(@as(usize, 1), vm.sched.fibers.items[1].waiters.items.len);
    // try testing.expectEqual(@as(usize, 0), vm.sched.fibers.items[1].waiters.items[0]);
}

test "vm spawn passes n args to child and join returns result" {
    var vm = try VM.init(vt.runtime());
    defer vm.deinit();

    const proto_id = try vm.functions.createPrototype(.{
        .addr = 6,
        .arity = 2,
        .name = "sum2",
        .upvalue_specs = &.{},
        .const_locals = &.{},
        .const_local_bits = &.{},
    });
    const fn_id = try vm.functions.createClosure(proto_id, &.{});
    const c_fn = try vm.addConstant(.{ .function = fn_id });
    const c_two = try vm.addConstant(Data.new.num(2));
    const c_three = try vm.addConstant(Data.new.num(3));

    const program = [_]revo.Instruction{
        .{ .op = .load_const, .a = 0, .bx = c_fn },
        .{ .op = .load_const, .a = 1, .bx = c_two },
        .{ .op = .load_const, .a = 2, .bx = c_three },
        .{ .op = .spawn, .a = 0, .b = 2, .c = 0 },
        .{ .op = .join, .a = 0 },
        .{ .op = .halt, .a = 0 },
        .{ .op = .load_local, .a = 2, .b = 0 },
        .{ .op = .load_local, .a = 3, .b = 1 },
        .{ .op = .add, .a = 2, .b = 2, .c = 3 },
        .{ .op = .ret, .a = 2 },
    };

    vm.mainFiber().program = &program;
    const result = try vm.runReport();
    try testing.expect(result == .ok);

    const out = vm.mainResult();
    try testing.expectEqual(@as(f64, 5), out.number);
}

test "vm channel handoff wakes blocked receiver" {
    var vm = try VM.init(vt.runtime());
    defer vm.deinit();

    const ch = try vm.sched.channelCreate(vm.runtime.alloc, &vm.tables, 0);

    const recv = try VM.Fiber.init(vm.runtime.alloc, 1, &.{});
    try vm.sched.fibers.append(vm.runtime.alloc, recv);
    vm.sched.current_fiber = 1;
    _ = try vm.sched.channelRecv(vm.runtime.alloc, ch);
    try testing.expectEqual(@as(VM.Fiber.State, .waiting), vm.currentFiber().state);

    vm.sched.current_fiber = 0;
    try vm.sched.channelSend(vm.runtime.alloc, ch, Data.new.num(99));

    try testing.expectEqual(@as(VM.Fiber.State, .ready), vm.sched.fibers.items[1].state);
    try testing.expectEqual(@as(f64, 99), vm.sched.fibers.items[1].slots.items[0].number);
}

test "scheduler generic park wake resumes parked fiber" {
    var vm = try VM.init(vt.runtime());
    defer vm.deinit();

    const child = try VM.Fiber.init(vm.runtime.alloc, 1, &.{});
    try vm.sched.fibers.append(vm.runtime.alloc, child);
    try vm.sched.fibers.items[1].slots.resize(vm.runtime.alloc, 1);
    vm.sched.fibers.items[1].slots.items[0] = revo.core_atoms.data(.missing);

    vm.sched.current_fiber = 1;
    try vm.sched.parkCurrentForIo(
        vm.runtime.alloc,
        7,
        .read,
        0,
        fakeIoReady,
        null,
    );

    try testing.expectEqual(@as(VM.Fiber.State, .waiting), vm.sched.fibers.items[1].state);
    try testing.expect(vm.sched.fibers.items[1].wait == .io);
    const io_wait = switch (vm.sched.fibers.items[1].wait) {
        .io => |wait| wait,
        else => unreachable,
    };
    try testing.expectEqual(@as(u64, 7), io_wait.wait_id);
    try testing.expectEqual(@as(usize, 1), vm.sched.io_waiters.items.len);
    try testing.expectEqual(@as(u64, 7), vm.sched.io_waiters.items[0].wait_id);

    try vm.sched.wakeFiber(vm.runtime.alloc, 1, Data.new.num(13));

    try testing.expectEqual(@as(VM.Fiber.State, .ready), vm.sched.fibers.items[1].state);
    try testing.expectEqual(@as(f64, 13), vm.sched.fibers.items[1].slots.items[1].number);
}

test "vm channel buffered send then recv" {
    var vm = try VM.init(vt.runtime());
    defer vm.deinit();

    const ch = try vm.sched.channelCreate(vm.runtime.alloc, &vm.tables, 1);
    try vm.sched.channelSend(vm.runtime.alloc, ch, Data.new.num(7));

    const before = vm.currentFiber().slots.items.len;
    if (try vm.sched.channelRecv(vm.runtime.alloc, ch)) |value| {
        try vm.push(value);
    }
    try testing.expectEqual(before + 1, vm.currentFiber().slots.items.len);
    try testing.expectEqual(@as(f64, 7), vm.currentFiber().slots.items[vm.currentFiber().slots.items.len - 1].number);
}

test "vm gc reuses freed table ids" {
    var vm = try VM.init(vt.runtime());
    defer vm.deinit();

    const first_id = try vm.tables.create();
    trigger_gc(&vm);

    try testing.expectError(error.InvalidTable, vm.tables.get(first_id));

    const reused_id = try vm.tables.create();
    try testing.expectEqual(first_id, reused_id);
}

test "vm gc keeps rooted tables and their children alive" {
    var vm = try VM.init(vt.runtime());
    defer vm.deinit();

    const parent_id = try vm.tables.create();
    const child_id = try vm.tables.create();

    {
        const parent = try vm.tables.get(parent_id);
        try parent.putRaw(try vm.ownDataString("child"), .{ .table = child_id });
    }

    try vm.push(.{ .table = parent_id });
    defer _ = vm.pop() catch {};

    trigger_gc(&vm);

    const parent = try vm.tables.get(parent_id);
    const child = parent.getRaw(try vm.ownDataString("child")) orelse unreachable;
    try testing.expect(std.meta.activeTag(child) == .table);
    try testing.expectEqual(child_id, child.table);
    _ = try vm.tables.get(child_id);
}

test "vm gc collects self-referential tables once unrooted" {
    var vm = try revo.VM.init(vt.runtime());
    defer vm.deinit();

    const cycle_id = try vm.tables.create();
    {
        const cycle = try vm.tables.get(cycle_id);
        try cycle.putRaw(try vm.ownDataString("self"), .{ .table = cycle_id });
    }

    try vm.push(.{ .table = cycle_id });
    trigger_gc(&vm);

    {
        const cycle = try vm.tables.get(cycle_id);
        const self_ref = cycle.getRaw(try vm.ownDataString("self")) orelse unreachable;
        try testing.expect(std.meta.activeTag(self_ref) == .table);
        try testing.expectEqual(cycle_id, self_ref.table);
    }

    _ = try vm.pop();
    trigger_gc(&vm);

    try testing.expectError(error.InvalidTable, vm.tables.get(cycle_id));
}

test "vm gc keeps globals rooted tables alive" {
    var vm = try revo.VM.init(vt.runtime());
    defer vm.deinit();

    const table_id = try vm.tables.create();
    try vm.setGlobal("alive", .{ .table = table_id });

    trigger_gc(&vm);

    _ = try vm.tables.get(table_id);
}

// test "vm gc reclaims unrooted tables tuples and functions" {
//     var vm = try revo.VM.init(vt.runtime());
//     defer vm.deinit();
//
//     const dead_table_id = try vm.tables.create();
//     const tuple_id = try vm.tuples.create(&.{ Data.new.num(1), Data.new.num(2) });
//     const fn_id = try vm.functions.create(.{ .native = return_one });
//
//     trigger_gc(&vm);
//
//     try testing.expectError(error.InvalidTable, vm.tables.get(dead_table_id));
//     try testing.expectError(error.FunctionDNE, vm.functions.get(fn_id));
//     try testing.expectError(error.InvalidTuple, vm.tuples.get(tuple_id));
// }

test "vm gc reuses freed function ids" {
    var vm = try VM.init(vt.runtime());
    defer vm.deinit();

    const proto_id = try vm.functions.createPrototype(.{
        .addr = 0,
        .arity = 0,
        .name = "f",
        .upvalue_specs = &.{},
        .const_locals = &.{},
        .const_local_bits = &.{},
    });
    const fn_id = try vm.functions.createClosure(proto_id, &.{});
    trigger_gc(&vm);

    try testing.expectError(error.FunctionDNE, vm.functions.get(fn_id));
    const reused = try vm.functions.createClosure(proto_id, &.{});
    try testing.expectEqual(fn_id, reused);
}

test "vm gc keeps rooted closures and captured tables alive" {
    var vm = try VM.init(vt.runtime());
    defer vm.deinit();

    const table_id = try vm.tables.create();
    try (try vm.tables.get(table_id)).putRaw(try vm.ownDataString("x"), Data.new.num(1));

    const proto_id = try vm.functions.createPrototype(.{
        .addr = 0,
        .arity = 0,
        .name = "capture",
        .upvalue_specs = &.{},
        .const_locals = &.{},
        .const_local_bits = &.{},
    });
    const upvalue_id = try vm.functions.createUpvalue(.{
        .open_index = null,
        .closed = .{ .table = table_id },
    });
    const closure_id = try vm.functions.createClosure(proto_id, &.{upvalue_id});
    try vm.push(.{ .function = closure_id });
    defer _ = vm.pop() catch {};

    trigger_gc(&vm);

    _ = try vm.functions.get(closure_id);
    _ = try vm.tables.get(table_id);
}

test "vm gc reuses freed tuple ids" {
    var vm = try VM.init(vt.runtime());
    defer vm.deinit();

    const first_id = try vm.tuples.create(&.{Data.new.num(1)});
    trigger_gc(&vm);

    try testing.expectError(error.InvalidTuple, vm.tuples.get(first_id));

    const reused_id = try vm.tuples.create(&.{Data.new.num(2)});
    try testing.expectEqual(first_id, reused_id);
}

test "vm gc keeps rooted tuples and nested tuples alive" {
    var vm = try VM.init(vt.runtime());
    defer vm.deinit();

    const child_id = try vm.tuples.create(&.{ Data.new.num(2), Data.new.num(3) });
    const parent_id = try vm.tuples.create(&.{ Data.new.num(1), .{ .tuple = child_id } });

    try vm.push(.{ .tuple = parent_id });
    defer _ = vm.pop() catch {};

    trigger_gc(&vm);

    const parent = try vm.tuples.get(parent_id);
    const child = try vm.tuples.get(child_id);
    try testing.expectEqual(@as(usize, 2), parent.items.len);
    try testing.expectEqual(@as(usize, 2), child.items.len);
    try testing.expectEqual(child_id, parent.items[1].tuple);
}

test "vm gc collects unreachable tuples" {
    var vm = try VM.init(vt.runtime());
    defer vm.deinit();

    const tuple_id = try vm.tuples.create(&.{Data.new.num(9)});
    trigger_gc(&vm);

    try testing.expectError(error.InvalidTuple, vm.tuples.get(tuple_id));
}

test "vm gc reuses freed string storage" {
    var vm = try VM.init(vt.runtime());
    defer vm.deinit();

    const first = try vm.ownString("alpha");
    try testing.expect(vm.strings.contains(first));

    vm.gc_pending = true;
    vm.maybeCollectGarbage();

    try testing.expect(!vm.strings.contains(first));

    const second = try vm.ownString("beta");
    try testing.expectEqualStrings("beta", vm.stringValue(second));
}

test "vm gc keeps rooted strings alive" {
    var vm = try VM.init(vt.runtime());
    defer vm.deinit();

    const s = try vm.ownString("keep-me");
    try vm.push(try vm.ownDataString(vm.stringValue(s)));
    defer _ = vm.pop() catch {};

    trigger_gc(&vm);

    try testing.expect(vm.strings.contains(s));
}

test "vm gc stress test allocates many objects" {
    var vm = try VM.init(vt.runtime());
    defer vm.deinit();

    var table_ids = try std.ArrayList(revo.memory.TableID).initCapacity(vt.runtime().alloc, 200);
    defer table_ids.deinit(vt.runtime().alloc);

    var tuple_ids = try std.ArrayList(revo.memory.TupleID).initCapacity(vt.runtime().alloc, 200);
    defer tuple_ids.deinit(vt.runtime().alloc);

    var string_ids = try std.ArrayList(revo.memory.StringID).initCapacity(vt.runtime().alloc, 200);
    defer string_ids.deinit(vt.runtime().alloc);

    const iterations = 200;

    for (0..iterations) |i| {
        const tid = try vm.tables.create();
        try table_ids.append(vt.runtime().alloc, tid);

        const ttbl = try vm.tables.get(tid);
        try ttbl.putRaw(try vm.ownDataString("index"), Data.new.num(i));

        const tpl_id = try vm.tuples.create(&.{ Data.new.num(i), Data.new.num(i * 2) });
        try tuple_ids.append(vt.runtime().alloc, tpl_id);

        const sid = try vm.ownString("stress-string");
        try string_ids.append(vt.runtime().alloc, sid);
    }

    try vm.push(try vm.ownDataString("root"));
    try vm.push(.{ .table = table_ids.items[0] });
    try vm.push(.{ .tuple = tuple_ids.items[0] });
    try vm.push(try vm.ownDataString(vm.stringValue(string_ids.items[0])));
    defer {
        _ = vm.pop() catch {};
        _ = vm.pop() catch {};
        _ = vm.pop() catch {};
        _ = vm.pop() catch {};
    }

    trigger_gc(&vm);

    _ = try vm.tables.get(table_ids.items[0]);
    _ = try vm.tuples.get(tuple_ids.items[0]);
    try testing.expect(vm.strings.contains(string_ids.items[0]));
}
