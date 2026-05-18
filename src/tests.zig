const std = @import("std");
const testing = std.testing;

const revo = @import("revo");
const Data = revo.Data;
const Instruction = revo.Instruction;
const vt = @import("vm").testing;

test {
    _ = std.testing.refAllDecls(revo.std_lib);
    _ = std.testing.refAllDecls(revo.lang);
    _ = std.testing.refAllDecls(revo.VM);
}

test "vm compare orders values by type and content" {
    var vm = try revo.VM.init(vt.runtime());
    defer vm.deinit();

    try testing.expectEqual(std.math.Order.gt, vm.compare(Data.new.nil(), Data.new.num(0)));
    const a = try vm.ownDataString("a");
    const abc = try vm.ownDataString("abc");
    const abd = try vm.ownDataString("abd");
    try testing.expectEqual(std.math.Order.gt, vm.compare(Data.new.num(1), a));
    try testing.expectEqual(std.math.Order.eq, vm.compare(abc, abc));
    try testing.expectEqual(std.math.Order.lt, vm.compare(abc, abd));
}

fn always_true(_: []const Data, _: *revo.VM) !revo.std_lib.NativeResult {
    return .{ .ok = Data.new.boolean(true) };
}

fn always_false(_: []const Data, _: *revo.VM) !revo.std_lib.NativeResult {
    return .{ .ok = Data.new.boolean(false) };
}

test "vm table comparison uses eq metamethod" {
    var vm = try revo.VM.init(vt.runtime());
    defer vm.deinit();

    const eq_fn = try vm.functions.create(
        .{ .native = revo.std_lib.define(&.{ .any, .any }, always_true) },
    );
    const mt_id = try vm.tables.create();
    const mt = try vm.tables.get(mt_id);
    try mt.putRaw(.{ .atom = try vm.internAtom("__eq") }, .{ .function = eq_fn });

    const left_id = try vm.tables.create();
    const right_id = try vm.tables.create();
    try vm.setMetatable(.{ .table = left_id }, mt_id);

    const left = try vm.addConstant(.{ .table = left_id });
    const right = try vm.addConstant(.{ .table = right_id });
    const program = [_]Instruction{
        .{ .op = .load_const, .a = 0, .bx = left },
        .{ .op = .load_const, .a = 1, .bx = right },
        .{ .op = .eq, .a = 0, .b = 0, .c = 1 },
        .{ .op = .halt, .a = 0 },
    };

    vm.mainFiber().program = &program;
    try vt.run(&vm);

    try testing.expectEqual(revo.core_atoms.atom_id(.true), (try vm.pop()).atom);
}

test "vm non-table type metatable applies to comparisons" {
    var vm = try revo.VM.init(vt.runtime());
    defer vm.deinit();

    const eq_fn = try vm.functions.create(.{ .native = revo.std_lib.define(&.{ .any, .any }, always_true) });
    const mt_id = try vm.tables.create();
    const mt = try vm.tables.get(mt_id);
    try mt.putRaw(.{ .atom = revo.core_atoms.atom_id(.__eq) }, .{ .function = eq_fn });
    try vm.setMetatable(Data.new.num(0), mt_id);

    const one = try vm.addConstant(Data.new.num(1));
    const two = try vm.addConstant(Data.new.num(2));
    const program = [_]Instruction{
        .{ .op = .load_const, .a = 0, .bx = one },
        .{ .op = .load_const, .a = 1, .bx = two },
        .{ .op = .eq, .a = 0, .b = 0, .c = 1 },
        .{ .op = .halt, .a = 0 },
    };

    vm.mainFiber().program = &program;
    try vt.run(&vm);

    try testing.expectEqual(revo.core_atoms.atom_id(.true), (try vm.pop()).atom);
}

test "vm neq can derive from eq metamethod" {
    var vm = try revo.VM.init(vt.runtime());
    defer vm.deinit();

    const eq_fn = try vm.functions.create(.{ .native = revo.std_lib.define(&.{ .any, .any }, always_false) });
    const mt_id = try vm.tables.create();
    const mt = try vm.tables.get(mt_id);
    try mt.putRaw(try vm.ownDataString("__eq"), .{ .function = eq_fn });
    try vm.setMetatable(Data.new.num(0), mt_id);

    const one = try vm.addConstant(Data.new.num(1));
    const two = try vm.addConstant(Data.new.num(2));
    const program = [_]Instruction{
        .{ .op = .load_const, .a = 0, .bx = one },
        .{ .op = .load_const, .a = 1, .bx = two },
        .{ .op = .neq, .a = 0, .b = 0, .c = 1 },
        .{ .op = .halt, .a = 0 },
    };

    vm.mainFiber().program = &program;
    try vt.run(&vm);

    try testing.expectEqual(revo.core_atoms.atom_id(.true), (try vm.pop()).atom);
}
