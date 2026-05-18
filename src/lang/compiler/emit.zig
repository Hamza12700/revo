const std = @import("std");

const revo = @import("revo");
const Data = revo.Data;
const Compiler = revo.lang.compiler.Compiler;
const Instruction = revo.Instruction;
const Opcode = revo.opcode.Opcode;
const Operand = revo.Operand;
const Register = revo.opcode.Register;

const Node = @import("../ast.zig").Node;
const state = @import("state.zig");

pub fn toRegister(n: usize) !Register {
    std.debug.assert(n <= std.math.maxInt(Register));
    return @intCast(n);
}

pub fn @"const"(self: *Compiler, value: Data) !void {
    if (value == .number and value.number >= 0 and value.number <= 65535 and @trunc(value.number) == value.number) {
        return smi(self, @intFromFloat(value.number));
    }
    const idx = try self.vm.addConstant(value);
    const dst = try state.pushRegister(self);
    const instr: Instruction = .{
        .op = .load_const,
        .a = dst,
        .bx = idx,
    };
    try self.instructions.append(self.alloc, instr);
    try self.spans.append(self.alloc, self.active_span);
}

pub fn loadConst(self: *Compiler, idx: revo.ConstantID) !void {
    const dst = try state.pushRegister(self);
    const instr: Instruction = .{
        .op = .load_const,
        .a = dst,
        .bx = idx,
    };
    try self.instructions.append(self.alloc, instr);
    try self.spans.append(self.alloc, self.active_span);
}

pub fn nil(self: *Compiler) !void {
    const dst = try state.pushRegister(self);
    const instr: Instruction = .{
        .op = .load_nil,
        .a = dst,
    };
    try self.instructions.append(self.alloc, instr);
    try self.spans.append(self.alloc, self.active_span);
}

pub fn smi(self: *Compiler, val: usize) !void {
    const dst = try state.pushRegister(self);
    const instr: Instruction = .{
        .op = .load_small_int,
        .a = dst,
        .bx = val,
    };
    try self.instructions.append(self.alloc, instr);
    try self.spans.append(self.alloc, self.active_span);
}

pub fn regDupe(self: *Compiler) !void {
    std.debug.assert(self.active_registers != 0);
    const dst = try toRegister(self.active_registers);
    const src = try toRegister(self.active_registers - 1);
    const instr: Instruction = .{
        .op = .move,
        .a = dst,
        .b = src,
    };
    try self.instructions.append(self.alloc, instr);
    try self.spans.append(self.alloc, self.active_span);
    self.active_registers += 1;
    if (self.active_registers > self.max_registers)
        self.max_registers = self.active_registers;
}

pub fn regRelease(self: *Compiler) !void {
    std.debug.assert(self.active_registers != 0);
    state.popRegister(self);
}

pub fn getStackEffect(op: Opcode) struct { pop: usize, push: usize } {
    return switch (op) {
        .add, .sub, .mul, .div, .mod, .eq, .neq, .lt, .gt, .lte, .gte, .@"and", .@"or" => .{ .pop = 2, .push = 1 },
        .negate, .not => .{ .pop = 1, .push = 1 },
        .jump_if_false, .jump_if_true, .jump_if_not_nil_and_not_err, .jump_if_err => .{ .pop = 1, .push = 0 },
        .store_global, .store_global_const, .store_local, .store_upval, .bind_local => .{ .pop = 1, .push = 0 },
        .load_global, .load_local, .load_upval, .closure, .table_new, .load_nil, .load_small_int, .load_const => .{ .pop = 0, .push = 1 },
        .table_set => .{ .pop = 3, .push = 0 },
        .table_get, .tuple_get => .{ .pop = 2, .push = 1 },
        .table_set_atom => .{ .pop = 2, .push = 0 },
        .table_get_atom, .tuple_get_const => .{ .pop = 1, .push = 1 },
        .join, .ret, .halt => .{ .pop = 1, .push = 0 },
        .yield, .jump => .{ .pop = 0, .push = 0 },
        .unwrap_result => .{ .pop = 0, .push = 0 },
        .call, .call_field, .spawn, .tuple_new, .range_init, .range_next, .range_for, .move => .{ .pop = 0, .push = 0 },
    };
}

pub fn emit(self: *Compiler, op: Opcode, operand: Operand) !void {
    var instr: Instruction = .{ .op = .halt };
    var depth = self.active_registers;

    switch (op) {
        .add, .sub, .mul, .div, .mod, .eq, .neq, .lt, .gt, .lte, .gte, .@"and", .@"or" => {
            std.debug.assert(depth >= 2);
            instr = .{ .op = op, .a = try toRegister(depth - 2), .b = try toRegister(depth - 2), .c = try toRegister(depth - 1) };
            depth -= 1;
        },
        .negate, .not => {
            std.debug.assert(depth > 0);
            instr = .{ .op = op, .a = try toRegister(depth - 1), .b = try toRegister(depth - 1) };
        },
        .halt => {
            instr = .{ .op = .halt, .a = if (depth == 0) 0 else try toRegister(depth - 1) };
        },
        .jump => {
            instr = .{ .op = .jump, .bx = operand };
        },
        .jump_if_false, .jump_if_true, .jump_if_not_nil_and_not_err, .jump_if_err => {
            std.debug.assert(depth > 0);
            instr = .{ .op = op, .a = try toRegister(depth - 1), .bx = operand };
            depth -= 1;
        },
        .store_global, .store_global_const => {
            std.debug.assert(depth > 0);
            instr = .{ .op = op, .a = try toRegister(depth - 1), .bx = operand };
            depth -= 1;
        },
        .store_local, .bind_local => {
            std.debug.assert(depth > 0);
            instr = .{ .op = op, .a = try toRegister(operand), .b = try toRegister(depth - 1) };
            depth -= 1;
        },
        .store_upval => {
            std.debug.assert(depth > 0);
            instr = .{ .op = op, .a = try toRegister(depth - 1), .bx = operand };
            depth -= 1;
        },
        .load_global => {
            instr = .{ .op = .load_global, .a = try toRegister(depth), .bx = operand };
            depth += 1;
        },
        .load_local => {
            instr = .{ .op = .load_local, .a = try toRegister(depth), .b = try toRegister(operand) };
            depth += 1;
        },
        .load_upval => {
            instr = .{ .op = .load_upval, .a = try toRegister(depth), .bx = operand };
            depth += 1;
        },
        .closure => {
            instr = .{ .op = .closure, .a = try toRegister(depth), .bx = operand };
            depth += 1;
        },
        .load_const => {
            instr = .{ .op = .load_const, .a = try toRegister(depth), .bx = operand };
            depth += 1;
        },
        .load_nil => {
            instr = .{ .op = .load_nil, .a = try toRegister(depth) };
            depth += 1;
        },
        .load_small_int => {
            instr = .{ .op = .load_small_int, .a = try toRegister(depth), .bx = operand };
            depth += 1;
        },
        .tuple_new => {
            std.debug.assert(depth >= operand);
            const first = depth - operand;
            instr = .{ .op = .tuple_new, .a = try toRegister(first), .b = try toRegister(first), .bx = operand };
            depth = first + 1;
        },
        .tuple_get => {
            std.debug.assert(depth >= 2);
            instr = .{ .op = .tuple_get, .a = try toRegister(depth - 2), .b = try toRegister(depth - 2), .c = try toRegister(depth - 1) };
            depth -= 1;
        },
        .table_new => {
            instr = .{ .op = .table_new, .a = try toRegister(depth) };
            depth += 1;
        },
        .table_set => {
            std.debug.assert(depth >= 3);
            instr = .{ .op = .table_set, .a = try toRegister(depth - 3), .b = try toRegister(depth - 2), .c = try toRegister(depth - 1) };
            depth -= 2;
        },
        .table_get => {
            std.debug.assert(depth >= 2);
            instr = .{ .op = .table_get, .a = try toRegister(depth - 2), .b = try toRegister(depth - 2), .c = try toRegister(depth - 1) };
            depth -= 1;
        },
        .table_set_atom => {
            std.debug.assert(depth >= 2);
            instr = .{ .op = .table_set_atom, .a = try toRegister(depth - 2), .c = try toRegister(depth - 1), .bx = operand };
            depth -= 1;
        },
        .table_get_atom => {
            std.debug.assert(depth > 0);
            instr = .{ .op = .table_get_atom, .a = try toRegister(depth - 1), .b = try toRegister(depth - 1), .bx = operand };
        },
        .tuple_get_const => {
            std.debug.assert(depth > 0);
            instr = .{ .op = .tuple_get_const, .a = try toRegister(depth - 1), .b = try toRegister(depth - 1), .bx = operand };
        },
        .call => {
            std.debug.assert(depth >= operand + 1);
            const base = depth - operand - 1;
            instr = .{ .op = .call, .a = try toRegister(base), .b = try toRegister(operand), .c = try toRegister(base) };
            depth = base + 1;
        },
        .call_field => {
            const explicit_argc = operand & ~@as(Operand, 1 << 15);
            const needed = explicit_argc + 2;
            std.debug.assert(depth >= needed);
            const base = depth - needed;
            instr = .{
                .op = .call_field,
                .a = try toRegister(base),
                .b = try toRegister(operand),
                .c = try toRegister(base),
            };
            depth = base + 1;
        },
        .ret => {
            instr = .{ .op = .ret, .a = if (depth == 0) 0 else try toRegister(depth - 1) };
        },
        .spawn => {
            std.debug.assert(depth >= operand + 1);
            const base = depth - operand - 1;
            instr = .{ .op = .spawn, .a = try toRegister(base), .b = try toRegister(operand), .c = try toRegister(base) };
            depth = base + 1;
        },
        .join => {
            std.debug.assert(depth > 0);
            instr = .{ .op = .join, .a = try toRegister(depth - 1) };
        },
        .yield => {
            instr = .{ .op = .yield };
        },
        .move => unreachable,
        .range_init => {
            std.debug.assert(depth >= 3);
            instr = .{ .op = .range_init, .a = try toRegister(depth - 3), .b = try toRegister(depth - 3), .c = try toRegister(depth - 1), .bx = @intCast(depth - 2) };
            depth -= 3;
        },
        .range_next => {
            std.debug.assert(depth >= 3);
            instr = .{ .op = .range_next, .a = try toRegister(depth), .b = try toRegister(depth - 3), .c = try toRegister(depth + 1), .bx = @intCast(depth + 2) };
            depth += 3;
        },
        .range_for => {
            std.debug.assert(depth >= 3);
            instr = .{ .op = .range_for, .a = try toRegister(depth - 3), .b = try toRegister(depth - 2), .c = try toRegister(depth - 1), .bx = operand };
        },
        .unwrap_result => {
            // if TOS is (:err, ...) and bx=0, return early
            // if TOS is (:ok, x), extract x; otherwise no-op
            std.debug.assert(depth > 0);
            instr = .{ .op = .unwrap_result, .a = try toRegister(depth - 1), .bx = operand };
        },
    }

    try self.instructions.append(self.alloc, instr);
    try self.spans.append(self.alloc, self.active_span);

    self.active_registers = depth;
    if (depth > self.max_registers) self.max_registers = depth;
}

pub fn jump(self: *Compiler, op: Opcode) !usize {
    const index = self.instructions.items.len;
    try emit(self, op, 0);
    return index;
}

pub fn patchJump(self: *Compiler, index: usize) void {
    self.instructions.items[index].bx = @intCast(self.instructions.items.len);
}

pub fn fail(
    self: *Compiler,
    kind: anytype,
    expr: *const Node,
    message: []const u8,
) error{LoweringFailed} {
    self.failure = .{ .kind = kind, .span = expr.span, .message = message };
    return error.LoweringFailed;
}
