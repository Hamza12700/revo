const std = @import("std");

const revo = @import("revo");
const Compiler = revo.lang.compiler.Compiler;
const Data = revo.Data;
const Instruction = revo.Instruction;
const ProgramCounter = revo.ProgramCounter;
const Operand = revo.Operand;
const Register = revo.opcode.Register;
const LocalSlot = revo.LocalSlot;

const ast = @import("../ast.zig");
const Node = ast.Node;
const emit = @import("emit.zig");
const toRegister = emit.toRegister;
const state = @import("state.zig");
const type_check = @import("type_check.zig");
const types_mod = @import("types.zig");

const validate_if_branches: bool = false;

const TypeHint = struct {
    name: []const u8,
    type_info: types_mod.TypeInfo,
};

pub const VarStorage = union(enum) {
    local: Operand,
    global: revo.AtomID,
};

pub fn compileLoop(self: *Compiler, body: *const Node) !void {
    const LoopScopeT = state.LoopScope(@TypeOf(self.*));
    var loop = try LoopScopeT.init(self);
    defer loop.deinit();

    const loop_start: ProgramCounter = @intCast(self.instructions.items.len);
    try self.compile(body, true);
    try emit.regRelease(self);
    try emit.emit(self, .jump, loop_start);
    // result visible to next binding
    self.active_registers = self.loop_result_regs.items[self.loop_result_regs.items.len - 1] + 1;
}

pub fn compileWhile(
    self: *Compiler,
    predicate: *const Node,
    body: *const Node,
) !void {
    const LoopScopeT = state.LoopScope(@TypeOf(self.*));
    var loop = try LoopScopeT.init(self);
    defer loop.deinit();

    const loop_start: ProgramCounter = @intCast(self.instructions.items.len);
    try self.compile(predicate, true);
    const exit_jump = try emit.jump(self, .jump_if_false);
    try self.compile(body, true);
    try emit.regRelease(self);
    try emit.emit(self, .jump, loop_start);

    emit.patchJump(self, exit_jump);
    // same as compileLoop
    self.active_registers = self.loop_result_regs.items[self.loop_result_regs.items.len - 1] + 1;
}

pub fn compileForRange(
    self: *Compiler,
    params: []const ast.FnParam,
    body: *const Node,
    start_expr: *const Node,
    step_expr: *const Node,
    end_expr: *const Node,
) !void {
    const LoopScopeT = state.LoopScope(@TypeOf(self.*));
    var loop = try LoopScopeT.init(self);
    defer loop.deinit();

    try self.compile(start_expr, true); // contiguous triple for range_init
    try self.compile(step_expr, true);
    try self.compile(end_expr, true);

    const base_reg = try toRegister(self.active_registers - 3);
    const range_init_instr: Instruction = .{
        .op = .range_init,
        .a = base_reg,
        .b = try toRegister(self.active_registers - 3),
        .bx = @intCast(self.active_registers - 2),
        .c = try toRegister(self.active_registers - 1),
    };
    try emit.appendRecorded(self, range_init_instr);

    const needs_index = params.len == 2 and !ast.isDiscardName(params[1].name);

    try compileRangeLoopBody(self, params, body, base_reg, needs_index);
    // collapse to result
    self.active_registers = self.loop_result_regs.items[self.loop_result_regs.items.len - 1] + 1;
}

pub fn compileRangeLoopBody(
    self: *Compiler,
    params: []const ast.FnParam,
    body: *const Node,
    state_reg: Register,
    needs_index: bool,
) !void {
    var value_slot: ?LocalSlot = null;
    var index_slot: ?LocalSlot = null;

    // declare before loop_check so range_next can fill them each iteration
    if (params.len >= 1 and !ast.isDiscardName(params[0].name)) {
        value_slot = try state.declareLocal(self, params[0].name, false);
        state.setLocalType(self, value_slot.?, "int");
        try state.setLocalTypeHint(self, params[0].name, .int);
    }
    if (params.len == 2 and !ast.isDiscardName(params[1].name)) {
        index_slot = try state.declareLocal(self, params[1].name, false);
        state.setLocalType(self, index_slot.?, "int");
        try state.setLocalTypeHint(self, params[1].name, .int);
    }

    const loop_check: ProgramCounter = @intCast(self.instructions.items.len);

    const value_reg = try toRegister(self.active_registers);
    // 0 is sentinel - ignored by range_next
    const index_reg = if (needs_index) try toRegister(self.active_registers + 1) else 0;
    const has_next_reg = try toRegister(self.active_registers + @as(usize, if (needs_index) 2 else 1));

    const range_next_instr: Instruction = .{
        .op = .range_next,
        .a = value_reg,
        .b = state_reg,
        .c = index_reg,
        .bx = @intCast(has_next_reg),
    };
    try emit.appendRecorded(self, range_next_instr);
    self.active_registers += if (needs_index) 3 else 2;

    const end_jump = try emit.jump(self, .jump_if_false);

    if (value_slot) |slot| {
        const temp_reg = try toRegister(self.active_registers);
        const move_val: Instruction = .{ .op = .move, .a = temp_reg, .b = value_reg };
        try emit.appendRecorded(self, move_val);
        self.active_registers += 1;
        state.markLocalInitialized(self, slot);
        try emit.emit(self, .bind_local, slot);
    }

    if (index_slot) |slot| {
        const temp_reg = try toRegister(self.active_registers);
        const move_idx: Instruction = .{ .op = .move, .a = temp_reg, .b = index_reg };
        try emit.appendRecorded(self, move_idx);
        self.active_registers += 1;
        state.markLocalInitialized(self, slot);
        try emit.emit(self, .bind_local, slot);
    }

    if (needs_index) try emit.regRelease(self);
    try emit.regRelease(self);

    const loop_state_end = try toRegister(state_reg + 3);
    reserveRegisters(self, loop_state_end); // pin range state so body can't clobber it

    try self.compile(body, true);

    // normalise into loop result slot so break and natural exit agree
    const body_result_reg: Register = @intCast(self.active_registers - 1);
    const loop_result_reg: Register = @intCast(self.loop_result_regs.items[self.loop_result_regs.items.len - 1]);
    if (body_result_reg != loop_result_reg) {
        const move_res: Instruction = .{ .op = .move, .a = loop_result_reg, .b = body_result_reg };
        try emit.appendRecorded(self, move_res);
    }
    try emit.regRelease(self);

    try emit.emit(self, .jump, loop_check);
    emit.patchJump(self, end_jump);

    // reverse order: has_next, index (if used), value, range state (3 regs)
    try emit.regRelease(self);
    if (needs_index) try emit.regRelease(self);
    try emit.regRelease(self);
    try emit.regRelease(self);
    try emit.regRelease(self);
}

pub fn compileFor(
    self: *Compiler,
    params: []const ast.FnParam,
    body: *const Node,
    iter: *const Node,
) !void {
    if (params.len == 0 or params.len > 2) {
        const msg = try std.fmt.allocPrint(
            self.alloc,
            "for expects one or two binding names, got {d}",
            .{params.len},
        );
        return self.fail(.UnsupportedSyntax, iter, msg);
    }

    if (iter.expr == .range_literal) {
        const range_info = iter.expr.range_literal;
        return compileForRange(self, params, body, range_info.start, range_info.step, range_info.end);
    }

    const LoopScopeT = state.LoopScope(@TypeOf(self.*));
    var loop = try LoopScopeT.init(self);
    defer loop.deinit();

    // pin
    try self.compile(iter, true);
    const iter_slot: LocalSlot = @intCast(self.active_registers - 1);
    const iter_storage: VarStorage = .{ .local = iter_slot };

    // idx <- 0
    try emit.emit(self, .load_small_int, 0);
    const idx_slot: LocalSlot = @intCast(self.active_registers - 1);
    const idx_storage: VarStorage = .{ .local = idx_slot };

    reserveRegisters(self, @intCast(iter_slot + 1));
    reserveRegisters(self, @intCast(idx_slot + 1));

    const needs_index = params.len == 2 and !ast.isDiscardName(params[1].name);
    var value_storage: ?VarStorage = null;
    var index_storage: ?VarStorage = null;
    if (!ast.isDiscardName(params[0].name)) {
        const value_slot = try state.declareLocal(self, params[0].name, false);
        value_storage = .{ .local = value_slot };
    }
    if (needs_index) {
        const index_slot = try state.declareLocal(self, params[1].name, false);
        index_storage = .{ .local = index_slot };
    }

    const loop_check: ProgramCounter = @intCast(self.instructions.items.len);

    // condition: idx < iter.len
    try emitStorageLoad(self, idx_storage);
    try emitStorageLoad(self, iter_storage);
    try emit.@"const"(self, Data.new.atom(try self.vm.internAtom("len")));
    try emit.emit(self, .call_field, (@as(Operand, 1) << 15) | 0);
    try emit.emit(self, .lt, 0);
    const end_jump = try emit.jump(self, .jump_if_false);

    // leaves 1 result on stack at active_registers - 1
    try emitForValueLoad(self, iter_storage, idx_storage);

    if (value_storage) |storage| {
        const value_slot: LocalSlot = @intCast(storage.local);
        state.markLocalInitialized(self, value_slot);
        try emit.emit(self, .bind_local, value_slot);
    } else {
        try emit.regRelease(self);
    }
    if (needs_index) {
        try emitStorageLoad(self, idx_storage);
        if (index_storage) |storage| {
            const index_slot: LocalSlot = @intCast(storage.local);
            state.markLocalInitialized(self, index_slot);
            try emit.emit(self, .bind_local, index_slot);
        } else {
            try emit.regRelease(self);
        }
    }

    state.reserveLocalSlots(self);

    try self.compile(body, true);

    // normalise result into loop result slot
    const body_result_reg: Register = @intCast(self.active_registers - 1);
    const loop_result_reg: Register = @intCast(self.loop_result_regs.items[self.loop_result_regs.items.len - 1]);
    if (body_result_reg != loop_result_reg) {
        const move_res: Instruction = .{ .op = .move, .a = loop_result_reg, .b = body_result_reg };
        try emit.appendRecorded(self, move_res);
    }
    try emit.regRelease(self);

    // idx += 1
    try emitStorageLoad(self, idx_storage);
    try emit.emit(self, .load_small_int, 1);
    try emit.emit(self, .add, 0);
    try emitStorageStore(self, idx_storage, false);

    try emit.emit(self, .jump, loop_check);

    emit.patchJump(self, end_jump);

    self.active_registers = self.loop_result_regs.items[self.loop_result_regs.items.len - 1] + 1;
}

pub fn emitStorageLoad(self: *Compiler, storage: VarStorage) !void {
    switch (storage) {
        .local => |slot| try emit.emit(self, .load_local, slot),
        .global => |sym| try emit.emit(self, .load_global, sym),
    }
}

pub fn emitStorageStore(self: *Compiler, storage: VarStorage, is_const: bool) !void {
    switch (storage) {
        .local => |slot| try emit.emit(self, .store_local, slot),
        .global => |sym| try emit.emit(self, if (is_const) .store_global_const else .store_global, sym),
    }
}

pub fn emitForValueLoad(
    self: *Compiler,
    iter_storage: VarStorage,
    idx_storage: VarStorage,
) !void {
    // type dispatch: tuple, string, table each have a different get opcode;
    // anything else calls `__iter` so user types can define iteration
    const base_depth = self.active_registers;
    const tuple_check = try emitForTypeCheck(self, iter_storage, "tuple");
    try emitStorageLoad(self, iter_storage);
    try emitStorageLoad(self, idx_storage);
    try emit.emit(self, .tuple_get, 0);
    const done = try emit.jump(self, .jump);

    self.active_registers = base_depth;
    emit.patchJump(self, tuple_check);
    const string_check = try emitForTypeCheck(self, iter_storage, "string");
    try emitStorageLoad(self, iter_storage);
    try emitStorageLoad(self, idx_storage);
    try emit.emit(self, .table_get, 0);
    const done2 = try emit.jump(self, .jump);

    self.active_registers = base_depth;
    emit.patchJump(self, string_check);
    const table_check = try emitForTypeCheck(self, iter_storage, "table");
    try emitStorageLoad(self, iter_storage);
    try emitStorageLoad(self, idx_storage);
    try emit.emit(self, .table_get, 0);
    const done3 = try emit.jump(self, .jump);

    self.active_registers = base_depth;
    emit.patchJump(self, table_check);
    try emitStorageLoad(self, iter_storage); // fallback: __iter(idx)
    try emit.@"const"(self, Data.new.atom(try self.vm.internAtom("__iter")));
    try emitStorageLoad(self, idx_storage);
    try emit.emit(self, .call_field, 1);

    emit.patchJump(self, done);
    emit.patchJump(self, done2);
    emit.patchJump(self, done3);
    self.active_registers = base_depth + 1;
}

pub fn emitForTypeCheck(
    self: *Compiler,
    iter_storage: VarStorage,
    type_name: []const u8,
) !usize {
    // emits `type(iter) == :type_name`, returns index of jump_if_false
    try emit.emit(self, .load_global, try self.vm.internAtom("type"));
    try emitStorageLoad(self, iter_storage);
    try emit.emit(self, .call, 1);
    const tname = try self.vm.internAtom(type_name);
    try emit.@"const"(self, Data.new.atom(tname));
    try emit.emit(self, .eq, 0);
    return emit.jump(self, .jump_if_false);
}

pub fn emitLoopRecurse(
    self: *Compiler,
    param_count: usize,
    loop_sym: revo.AtomID,
) !void {
    // `loop foo` tail-recurses, load args from result tuple, call, ret -- avoids stack growth
    const result_slot = self.slot_allocators.items[self.slot_allocators.items.len - 1];
    self.slot_allocators.items[self.slot_allocators.items.len - 1] += 1;
    if (self.max_registers < result_slot + 1) self.max_registers = result_slot + 1;

    if (param_count > 0) {
        try emit.emit(self, .bind_local, result_slot);
    } else {
        try emit.regRelease(self);
    }
    try emit.emit(self, .load_global, loop_sym);

    if (param_count == 1) {
        try emit.emit(self, .load_local, result_slot);
    } else if (param_count > 1) {
        for (0..param_count) |idx| { // unpack result tuple into args
            try emit.emit(self, .load_local, result_slot);
            try emit.emit(self, .tuple_get_const, idx);
        }
    }
    try emit.emit(self, .call, @intCast(param_count));
    try emit.emit(self, .ret, 1);
}

pub fn compileMatch(
    self: *Compiler,
    subject: *const Node,
    arms: []const ast.MatchArm,
) !void {
    if (state.currentFunctionState(self) == null)
        return self.fail(.UnsupportedSyntax, subject, "match requires function scope");

    const saved_next_slot = self.slot_allocators.items[self.slot_allocators.items.len - 1];
    const saved_active = self.active_registers;
    const saved_max = self.max_registers;

    try state.pushScope(self);
    errdefer state.popScope(self);
    errdefer {
        self.active_registers = saved_active;
        self.max_registers = saved_max;
        self.slot_allocators.items[self.slot_allocators.items.len - 1] = saved_next_slot;
    }

    // evaluated once, loaded per arm
    const subject_slot = try state.declareLocal(self, "__match_subject", false);
    try self.compile(subject, true);
    state.markLocalInitialized(self, subject_slot);
    try emit.emit(self, .bind_local, subject_slot);
    state.reserveLocalSlots(self);

    const arm_base_registers = self.active_registers;
    const subject_storage: VarStorage = .{ .local = subject_slot };

    var end_jumps = try std.ArrayList(usize).initCapacity(self.alloc, arms.len);
    defer end_jumps.deinit(self.alloc);

    for (arms) |arm| {
        self.active_registers = arm_base_registers;

        try state.pushScope(self);
        errdefer state.popScope(self);

        const matcher_expr: ?*const Node = switch (arm.matchers[0]) {
            .wildcard => null,
            .expr => |e| e,
        };

        const fail_jumps = try compilePatternChecks(self, subject_storage, matcher_expr);
        var fail_list = try std.ArrayList(usize).initCapacity(self.alloc, fail_jumps.len + 1);
        defer fail_list.deinit(self.alloc);
        try fail_list.appendSlice(self.alloc, fail_jumps);
        self.alloc.free(fail_jumps);

        if (matcher_expr) |me| {
            if (subject.expr == .ident) {
                if (patternTypeInfo(self, me)) |ti| {
                    try state.setLocalTypeHint(self, subject.expr.ident, ti);
                }
            }
            try bindMatchPattern(self, me, subject_storage);
        }

        if (arm.guard) |guard| {
            try self.compile(guard, true);
            const guard_jump = try emit.jump(self, .jump_if_false);
            try fail_list.append(self.alloc, guard_jump);
        }

        try self.compile(arm.then, true);

        // move arm result to arm_base_registers, all arms must leave stack at same depth
        const arm_result_reg: Register = @intCast(self.active_registers - 1);
        if (arm_result_reg != arm_base_registers) {
            const move_instr: Instruction = .{
                .op = .move,
                .a = try toRegister(arm_base_registers),
                .b = try toRegister(arm_result_reg),
            };
            try emit.appendRecorded(self, move_instr);
        }
        try emit.regRelease(self);
        self.active_registers = arm_base_registers + 1;

        const end_jump = try emit.jump(self, .jump);
        try end_jumps.append(self.alloc, end_jump);

        state.popScope(self);

        const next_arm = self.instructions.items.len;
        for (fail_list.items) |jump_idx| patchJumpToLabel(self, jump_idx, next_arm);
    }
    state.popScope(self);

    // reclaim subject slot
    self.slot_allocators.items[self.slot_allocators.items.len - 1] = saved_next_slot;

    self.active_registers = arm_base_registers;
    try emit.nil(self); // fallthrough when no arm matched
    for (end_jumps.items) |jump_idx| emit.patchJump(self, jump_idx);

    self.active_registers = arm_base_registers + 1;
}

pub fn patchJumpToLabel(self: *Compiler, jump_idx: usize, target: usize) void {
    emit.patchJumpToLabel(self, jump_idx, target);
}

pub fn reserveRegisters(self: *Compiler, min_register: Register) void {
    // bumps slot allocator and active/max, no reuse of live register
    const min_slot: LocalSlot = @intCast(min_register);
    if (self.slot_allocators.items.len > 0) {
        if (self.slot_allocators.items[self.slot_allocators.items.len - 1] < min_slot) {
            self.slot_allocators.items[self.slot_allocators.items.len - 1] = min_slot;
        }
    }
    if (self.active_registers < min_slot) self.active_registers = min_slot;
    if (self.max_registers < min_slot) self.max_registers = min_slot;
}

pub fn bindMatchPattern(
    self: *Compiler,
    matcher: *const Node,
    subject: VarStorage,
) !void {
    switch (matcher.expr) {
        .ident => |name| {
            if (ast.isDiscardName(name)) return;
            try emitStorageLoad(self, subject);
            const slot = try state.declareLocal(self, name, true);
            state.markLocalInitialized(self, slot);
            try emit.emit(self, .bind_local, slot);
            state.reserveLocalSlots(self);
        },
        .tuple_pattern => try bindMatchTuplePattern(self, matcher, subject),
        else => {},
    }
}

pub fn bindMatchTuplePattern(
    self: *Compiler,
    pattern: *const Node,
    source: VarStorage,
) !void {
    switch (pattern.expr) {
        .ident => |name| {
            if (ast.isDiscardName(name)) return;
            try emitStorageLoad(self, source);
            const slot = try state.declareLocal(self, name, true);
            state.markLocalInitialized(self, slot);
            try emit.emit(self, .bind_local, slot);
            state.reserveLocalSlots(self);
        },
        .tuple_pattern => |items| {
            for (items, 0..) |item, idx| {
                switch (item.expr) {
                    .ident => |name| {
                        if (ast.isDiscardName(name)) continue;
                        try emitStorageLoad(self, source);
                        try emit.emit(self, .tuple_get_const, idx);
                        const slot = try state.declareLocal(self, name, true);
                        state.markLocalInitialized(self, slot);
                        try emit.emit(self, .bind_local, slot);
                        state.reserveLocalSlots(self);
                    },
                    .tuple_pattern => {
                        try emitStorageLoad(self, source);
                        try emit.emit(self, .tuple_get_const, idx);
                        // temp for nested pattern
                        const nested_slot = try state.declareLocal(self, "__bind_tmp", false);
                        state.markLocalInitialized(self, nested_slot);
                        try emit.emit(self, .bind_local, nested_slot);
                        state.reserveLocalSlots(self);
                        try bindMatchTuplePattern(self, item, .{ .local = nested_slot });
                    },
                    else => {},
                }
            }
        },
        else => {},
    }
}

pub fn compilePatternChecks(
    self: *Compiler,
    subject: VarStorage,
    matcher: ?*const Node,
) ![]usize {
    var fail_jumps = try std.ArrayList(usize).initCapacity(self.alloc, 4);
    const expr = matcher orelse return fail_jumps.toOwnedSlice(self.alloc);

    switch (expr.expr) {
        .ident => {}, // always matches
        .tuple_pattern => |items| {
            // type check, then length, then each element
            try emit.emit(self, .load_global, try self.vm.internAtom("type"));
            try emitStorageLoad(self, subject);
            try emit.emit(self, .call, 1);
            try emit.@"const"(self, Data.new.atom(try self.vm.internAtom("tuple")));
            try emit.emit(self, .eq, 0);
            try fail_jumps.append(self.alloc, try emit.jump(self, .jump_if_false));

            try emit.emit(self, .load_global, try self.vm.internAtom("len"));
            try emitStorageLoad(self, subject);
            try emit.emit(self, .call, 1);
            try emit.@"const"(self, Data.new.num(items.len));
            try emit.emit(self, .eq, 0);
            try fail_jumps.append(self.alloc, try emit.jump(self, .jump_if_false));

            for (items, 0..) |item, idx| {
                switch (item.expr) {
                    .ident => |name| if (ast.isDiscardName(name)) continue,
                    else => {},
                }
                const depth_before = self.active_registers;
                const slot_before = self.slot_allocators.items[self.slot_allocators.items.len - 1];
                try emitStorageLoad(self, subject);
                try emit.emit(self, .tuple_get_const, idx);
                // avoids re-indexing in nested checks
                const nested_slot = try state.declareLocal(self, "__match_tmp", false);
                state.markLocalInitialized(self, nested_slot);
                try emit.emit(self, .bind_local, nested_slot);
                state.reserveLocalSlots(self);
                const nested_fails = try compilePatternChecks(self, .{ .local = nested_slot }, item);
                for (nested_fails) |jump_idx| try fail_jumps.append(self.alloc, jump_idx);
                self.alloc.free(nested_fails);
                self.active_registers = depth_before;
                self.slot_allocators.items[self.slot_allocators.items.len - 1] = slot_before;
            }
        },
        else => {
            // literal or expression; evaluate and compare
            try emitStorageLoad(self, subject);
            try self.compile(expr, true);
            try emit.emit(self, .eq, 0);
            try fail_jumps.append(self.alloc, try emit.jump(self, .jump_if_false));
        },
    }
    return fail_jumps.toOwnedSlice(self.alloc);
}

pub fn compileIf(
    self: *Compiler,
    condition: *const Node,
    then_expr: *const Node,
    else_expr: ?*Node,
) !void {
    if (state.currentFunctionState(self) == null)
        return self.fail(.UnsupportedSyntax, condition, "if requires function scope");

    const saved_next_slot = self.slot_allocators.items[self.slot_allocators.items.len - 1];
    const saved_active = self.active_registers;
    const saved_max = self.max_registers;
    errdefer {
        self.active_registers = saved_active;
        self.max_registers = saved_max;
        self.slot_allocators.items[self.slot_allocators.items.len - 1] = saved_next_slot;
    }

    try self.compile(condition, true);
    const else_jump = try emit.jump(self, .jump_if_false);
    const branch_base_registers = self.active_registers;

    try state.pushScope(self);
    errdefer state.popScope(self);
    if (conditionTypeHint(condition)) |hint| {
        try state.setLocalTypeHint(self, hint.name, hint.type_info);
    }
    try self.compile(then_expr, true);
    state.popScope(self);
    const then_registers = self.active_registers;
    const then_type = type_check.inferExprType(self, then_expr);
    const end_jump = try emit.jump(self, .jump);
    emit.patchJump(self, else_jump);
    self.active_registers = branch_base_registers; // reset before else so both branches start at same depth
    self.slot_allocators.items[self.slot_allocators.items.len - 1] = saved_next_slot;

    try state.pushScope(self);
    errdefer state.popScope(self);
    if (else_expr) |branch| {
        try self.compile(branch, true);
        const else_type = type_check.inferExprType(self, branch);
        try validateIfBranchTypes(self, then_type, else_type, then_expr, branch);
    } else try emit.nil(self);
    state.popScope(self);

    if (then_registers != self.active_registers) {
        // then-branch may differ from that nil
        while (self.active_registers < then_registers)
            try emit.nil(self);
        while (self.active_registers > then_registers)
            try emit.regRelease(self);
    }
    emit.patchJump(self, end_jump);
    self.slot_allocators.items[self.slot_allocators.items.len - 1] = saved_next_slot;
}

fn conditionTypeHint(condition: *const Node) ?TypeHint {
    return switch (condition.expr) {
        .call => |call| blk: {
            if (call.args.len != 1 or call.callee.expr != .ident or !std.mem.endsWith(u8, call.callee.expr.ident, "?")) break :blk null;
            if (call.args[0].expr != .ident) break :blk null;
            const type_info = predicateTypeInfo(call.callee.expr.ident) orelse break :blk null;
            break :blk .{ .name = call.args[0].expr.ident, .type_info = type_info };
        },
        .binary => |b| blk: {
            if (b.op != .eq) break :blk null;
            const left = typeCompareHint(b.left, b.right) orelse typeCompareHint(b.right, b.left) orelse break :blk null;
            break :blk left;
        },
        else => null,
    };
}

fn typeCompareHint(type_expr: *const Node, value_expr: *const Node) ?TypeHint {
    if (type_expr.expr != .call) return null;
    const call = type_expr.expr.call;
    if (call.args.len != 1 or call.callee.expr != .ident) return null;
    if (!std.mem.eql(u8, call.callee.expr.ident, "type")) return null;
    if (call.args[0].expr != .ident) return null;
    if (value_expr.expr != .hash) return null;
    const type_info = typeNameInfo(value_expr.expr.hash) orelse return null;
    return .{ .name = call.args[0].expr.ident, .type_info = type_info };
}

fn predicateTypeInfo(name: []const u8) ?types_mod.TypeInfo {
    if (std.mem.eql(u8, name, "number?")) return typeNameInfo("number");
    if (std.mem.eql(u8, name, "string?")) return typeNameInfo("string");
    if (std.mem.eql(u8, name, "bool?")) return typeNameInfo("bool");
    if (std.mem.eql(u8, name, "table?")) return typeNameInfo("table");
    return null;
}

fn typeNameInfo(name: []const u8) ?types_mod.TypeInfo {
    if (std.mem.eql(u8, name, "number")) return .{
        .@"union" = &.{
            .{ .name = "", .types = &.{.int} },
            .{ .name = "", .types = &.{.float} },
        },
    };
    if (std.mem.eql(u8, name, "string")) return .string;
    if (std.mem.eql(u8, name, "bool")) return .bool;
    if (std.mem.eql(u8, name, "table")) return .{ .struct_type = "table" };
    return null;
}

fn patternTypeInfo(self: *Compiler, pattern: *const Node) ?types_mod.TypeInfo {
    return switch (pattern.expr) {
        .number => |n| if (n.is_float) .float else .int,
        .string, .multiline_string => .string,
        .hash => |name| .{ .atom = name },
        .tuple_pattern => |items| blk: {
            var types = std.ArrayList(types_mod.TypeInfo).initCapacity(self.alloc, items.len) catch break :blk null;
            defer types.deinit(self.alloc);
            for (items) |item| {
                types.append(self.alloc, patternTypeInfo(self, item) orelse .any) catch break :blk null;
            }
            const tuple_items = types.toOwnedSlice(self.alloc) catch break :blk null;
            break :blk types_mod.TypeInfo{ .tuple = tuple_items };
        },
        else => null,
    };
}

fn validateIfBranchTypes(self: *Compiler, then_type: type_check.TypeInfo, else_type: type_check.TypeInfo, then_expr: *const Node, else_expr: *const Node) !void {
    if (comptime !validate_if_branches) return;
    _ = then_expr;
    if (then_type == .any or else_type == .any) return;
    if (then_type.eql(else_type)) return;
    if (types_mod.canCoerce(else_type, then_type)) return;
    if (types_mod.canCoerce(then_type, else_type)) return;
    return self.fail(.ParseError, else_expr, "if/else branches must have matching types");
}

pub fn compileAnd(self: *Compiler, left: *const Node, right: *const Node) !void {
    // short-circuit: false left skips right, returns left
    try self.compile(left, true);
    try emit.regDupe(self);
    const short = try emit.jump(self, .jump_if_false);
    try emit.regRelease(self);
    try self.compile(right, true);
    const end = try emit.jump(self, .jump);
    emit.patchJump(self, short);
    emit.patchJump(self, end);
}

pub fn compileOr(self: *Compiler, left: *const Node, right: *const Node) !void {
    // short-circuit: true left skips right, returns left
    try self.compile(left, true);
    try emit.regDupe(self);
    const short = try emit.jump(self, .jump_if_true);
    try emit.regRelease(self);
    try self.compile(right, true);
    const end = try emit.jump(self, .jump);
    emit.patchJump(self, short);
    emit.patchJump(self, end);
}

pub fn compileBreak(self: *Compiler, expr: *const Node, value: ?*const Node) !void {
    if (self.in_loop_depth == 0) {
        return self.fail(.UnsupportedSyntax, expr, "break is only valid inside loop");
    }
    if (self.loop_result_regs.items.len <= 0) return;

    if (value) |v| try self.compile(v, true) else try emit.nil(self);

    const r = self.active_registers - 1;
    const loop_res = self.loop_result_regs.items[self.loop_result_regs.items.len - 1];
    // round-trip: value must be in both the result slot and the stack top callers expect
    const move_to_res: Instruction = .{ .op = .move, .a = try toRegister(loop_res), .b = try toRegister(r) };
    try emit.appendRecorded(self, move_to_res);
    const move_back: Instruction = .{ .op = .move, .a = try toRegister(r), .b = try toRegister(loop_res) };
    try emit.appendRecorded(self, move_back);
    const jump_idx = try emit.jump(self, .jump);
    try self.break_jumps.append(self.alloc, jump_idx);
}
