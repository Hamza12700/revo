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

pub const VarStorage = union(enum) {
    local: Operand,
    global: revo.AtomID,
};

const UnderscoreCheckVisitor = struct {
    found: bool = false,

    pub fn visit(self: *UnderscoreCheckVisitor, node: *const Node) void {
        if (self.found) return;
        switch (node.expr) {
            .ident => |name| {
                if (std.mem.eql(u8, name, "_")) self.found = true;
            },
            else => ast.walkAST(UnderscoreCheckVisitor, self, node),
        }
    }
};

pub fn hasUnderscore(node: *const Node) bool {
    var visitor = UnderscoreCheckVisitor{};
    ast.walkAST(UnderscoreCheckVisitor, &visitor, node);
    return visitor.found;
}

pub fn compilePipe(self: *Compiler, left: *const Node, right: *const Node) !void {
    switch (right.expr) {
        .ident => {
            try self.compile(right, true);
            try self.compile(left, true);
            try emit.emit(self, .call, 1);
        },
        .match_expr => |match| {
            try compileMatch(self, left, match.arms);
        },
        .fn_expr => |fn_expr| {
            try self.compileFn(fn_expr.params, fn_expr.body, "<fn>", null);
            try self.compile(left, true);
            try emit.emit(self, .call, 1);
        },
        .call => {
            const call = &right.expr.call;
            const has_underscore = hasUnderscore(right);
            if (has_underscore) {
                try state.pushScope(self);
                errdefer state.popScope(self);
                const slot = try state.declareLocal(self, "_", false);
                try self.compile(left, true);
                state.markLocalInitialized(self, slot);
                try emit.emit(self, .bind_local, slot);
                state.reserveLocalSlots(self);
                try self.compile(right, true);
                state.popScope(self);
            } else {
                switch (call.callee.expr) {
                    .field => |field| {
                        try self.compile(field.object, true);
                        try emit.@"const"(self, Data{ .atom = try self.vm.internAtom(field.name) });
                        try self.compile(left, true);
                        for (call.args) |arg| try self.compile(arg, true);
                        const argc = (call.args.len + 1) | (@as(usize, @intFromBool(call.implicit_self)) << 15);
                        try emit.emit(self, .call_field, @intCast(argc));
                    },
                    .index => |index| {
                        try self.compile(index.object, true);
                        try self.compile(index.key, true);
                        try self.compile(left, true);
                        for (call.args) |arg| try self.compile(arg, true);
                        const argc = (call.args.len + 1) | (@as(usize, @intFromBool(call.implicit_self)) << 15);
                        try emit.emit(self, .call_field, @intCast(argc));
                    },
                    else => {
                        try self.compile(call.callee, true);
                        try self.compile(left, true);
                        for (call.args) |arg| try self.compile(arg, true);
                        try emit.emit(self, .call, @intCast(call.args.len + 1));
                    },
                }
            }
        },
        else => {
            try state.pushScope(self);
            errdefer state.popScope(self);
            const slot = try state.declareLocal(self, "_", false);
            try self.compile(left, true);
            state.markLocalInitialized(self, slot);
            try emit.emit(self, .bind_local, slot);
            state.reserveLocalSlots(self);
            try self.compile(right, true);
            state.popScope(self);
        },
    }
}

pub fn compileLoop(self: *Compiler, body: *const Node) !void {
    const LoopScopeT = state.LoopScope(@TypeOf(self.*));
    var loop = try LoopScopeT.init(self);
    defer loop.deinit();

    const loop_start: ProgramCounter = @intCast(self.instructions.items.len);
    try self.compile(body, true);
    try emit.regRelease(self);
    try emit.emit(self, .jump, loop_start);
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

    // patch exit_jump to here (predicate is false, exit loop)
    // this is also where breaks should jump
    emit.patchJump(self, exit_jump);
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

    try self.compile(start_expr, true);
    try self.compile(step_expr, true);
    try self.compile(end_expr, true);

    // state layout in consecutive registers starting at base:
    // R[base]   = current (start initially)
    // R[base+1] = step
    // R[base+2] = limit
    const base_reg = try toRegister(self.active_registers - 3);
    const range_init_instr: Instruction = .{
        .op = .range_init,
        .a = base_reg, // output: start of loop state
        .b = try toRegister(self.active_registers - 3), // input: start
        .bx = @intCast(self.active_registers - 2), // input: step (register index via bx)
        .c = try toRegister(self.active_registers - 1), // input: end
    };
    try self.instructions.append(self.alloc, range_init_instr);
    try self.spans.append(self.alloc, self.active_span);

    const needs_index = params.len == 2 and !ast.isDiscardName(params[1].name);

    try compileRangeLoopBody(self, params, body, base_reg, needs_index);
    // after loop body is done, only loop_result is left on stack
    self.active_registers = self.loop_result_regs.items[self.loop_result_regs.items.len - 1] + 1;
}

pub fn compileRangeLoopBody(
    self: *Compiler,
    params: []const ast.FnParam,
    body: *const Node,
    state_reg: Register, // base register holding loop state (current, step, limit)
    needs_index: bool,
) !void {
    const loop_check: ProgramCounter = @intCast(self.instructions.items.len);

    // output registers for range_next
    const value_reg = try toRegister(self.active_registers); // new register for value
    const index_reg = if (needs_index) try toRegister(self.active_registers + 1) else 0; // new for index
    const has_next_reg = try toRegister(self.active_registers + @as(usize, if (needs_index) 2 else 1)); // new for has_next

    const range_next_instr: Instruction = .{
        .op = .range_next,
        .a = value_reg, // output: value
        .b = state_reg, // input: loop state base (current, step, limit)
        .c = index_reg, // output: index (or 0 if not needed)
        .bx = @intCast(has_next_reg), // output: has_next
    };
    try self.instructions.append(self.alloc, range_next_instr);
    try self.spans.append(self.alloc, self.active_span);
    self.active_registers += if (needs_index) 3 else 2; // +value, +index (if needed), +has_next

    // maybe exit when if !has_next (@ top of stack)
    const end_jump = try emit.jump(self, .jump_if_false);
    // jump already consumes has_next from stack

    // bind first param (val) to the value register
    if (params.len >= 1 and !ast.isDiscardName(params[0].name)) {
        const temp_reg = try toRegister(self.active_registers);

        // duplicate value to top of stack before storing binding
        const move_val: Instruction = .{
            .op = .move,
            .a = temp_reg,
            .b = value_reg,
        };
        try self.instructions.append(self.alloc, move_val);
        try self.spans.append(self.alloc, self.active_span);
        self.active_registers += 1;

        // store to global (consumes top)
        try emit.emit(self, .store_global, try self.vm.internAtom(params[0].name));
    }

    // bind second param (idx) to the index register
    if (params.len == 2 and !ast.isDiscardName(params[1].name)) {
        const temp_reg = try toRegister(self.active_registers);

        const move_idx: Instruction = .{
            .op = .move,
            .a = temp_reg,
            .b = index_reg,
        };
        try self.instructions.append(self.alloc, move_idx);
        try self.spans.append(self.alloc, self.active_span);
        self.active_registers += 1;

        try emit.emit(self, .store_global, try self.vm.internAtom(params[1].name));
    }

    // drop value and index
    if (needs_index) try emit.regRelease(self); // idx
    try emit.regRelease(self); // val

    // body clobbers them if you dont reserve
    const loop_state_end = try toRegister(state_reg + 3);
    reserveRegisters(self, loop_state_end);

    try self.compile(body, true);

    // move body result to loop result
    const body_result_reg: Register = @intCast(self.active_registers - 1);
    const loop_result_reg: Register = @intCast(self.loop_result_regs.items[self.loop_result_regs.items.len - 1]);
    if (body_result_reg != loop_result_reg) {
        const move_res: Instruction = .{
            .op = .move,
            .a = loop_result_reg,
            .b = body_result_reg,
        };
        try self.instructions.append(self.alloc, move_res);
        try self.spans.append(self.alloc, self.active_span);
    }
    try emit.regRelease(self); // pop body result, loop_result remains

    // back to loop check
    try emit.emit(self, .jump, loop_check);

    emit.patchJump(self, end_jump);

    // clean up loop state registers and leftover value/index
    // stack at this point: loop_result, current, step, limit, value, [index]
    try emit.regRelease(self); // value
    if (needs_index) try emit.regRelease(self); // index
    try emit.regRelease(self); // limit
    try emit.regRelease(self); // step
    try emit.regRelease(self); // current
    // stack: loop_result
}

pub fn compileFor(
    self: *Compiler,
    params: []const ast.FnParam,
    body: *const Node,
    iter: *const Node,
) !void {
    if (params.len == 0 or params.len > 2) {
        return self.fail(.UnsupportedSyntax, iter, "for expects one or two binding names");
    }

    // theres a happy path
    if (iter.expr == .range_literal) {
        const range_info = iter.expr.range_literal;
        return compileForRange(
            self,
            params,
            body,
            range_info.start,
            range_info.step,
            range_info.end,
        );
    }

    const LoopScopeT = state.LoopScope(@TypeOf(self.*));
    var loop = try LoopScopeT.init(self);
    defer loop.deinit();

    // all code is now inside __main (synthetic top-level function), so always use locals
    const iter_slot: Operand = @intCast(self.slot_allocators.items[self.slot_allocators.items.len - 1]);
    self.slot_allocators.items[self.slot_allocators.items.len - 1] += 1;
    const iter_storage: VarStorage = .{ .local = iter_slot };

    const idx_slot: Operand = @intCast(self.slot_allocators.items[self.slot_allocators.items.len - 1]);
    self.slot_allocators.items[self.slot_allocators.items.len - 1] += 1;
    const idx_storage: VarStorage = .{ .local = idx_slot };

    // compile iter expression into iter storage
    try self.compile(iter, true);
    try emitStorageStore(self, iter_storage, false);

    // init idx to 0
    try emit.@"const"(self, Data.new.num(0));
    try emitStorageStore(self, idx_storage, false);

    const loop_check: ProgramCounter = @intCast(self.instructions.items.len);

    // check idx < len(iter)
    try emitStorageLoad(self, idx_storage);
    try emit.emit(self, .load_global, try self.vm.internAtom("len"));
    try emitStorageLoad(self, iter_storage);
    try emit.emit(self, .call, 1);
    try emit.emit(self, .lt, 0);
    const end_jump = try emit.jump(self, .jump_if_false);

    // load iter value w tuple/table/__iter dispatch
    try emitForValueLoad(self, iter_storage, idx_storage);
    if (!ast.isDiscardName(params[0].name)) {
        try emit.regDupe(self);
        try emit.emit(self, .store_global, try self.vm.internAtom(params[0].name));
    }
    try emit.regRelease(self);

    if (params.len == 2) {
        try emitStorageLoad(self, idx_storage);
        if (!ast.isDiscardName(params[1].name)) {
            try emit.regDupe(self);
            try emit.emit(self, .store_global, try self.vm.internAtom(params[1].name));
        }
        try emit.regRelease(self);
    }

    if (iter_storage == .local) {
        reserveRegisters(self, @intCast(iter_storage.local + 1));
    }
    if (idx_storage == .local) {
        reserveRegisters(self, @intCast(idx_storage.local + 1));
    }

    try self.compile(body, true);

    // mv body result to loop result
    const body_result_reg: Register = @intCast(self.active_registers - 1);
    const loop_result_reg: Register = @intCast(self.loop_result_regs.items[self.loop_result_regs.items.len - 1]);
    if (body_result_reg != loop_result_reg) {
        const move_res: Instruction = .{
            .op = .move,
            .a = loop_result_reg,
            .b = body_result_reg,
        };
        try self.instructions.append(self.alloc, move_res);
        try self.spans.append(self.alloc, self.active_span);
    }
    try emit.regRelease(self); // pop body result, loop_result left

    // idx = idx + 1
    try emitStorageLoad(self, idx_storage);
    try emit.@"const"(self, Data.new.num(1));
    try emit.emit(self, .add, 0);
    try emitStorageStore(self, idx_storage, false);
    try emit.emit(self, .jump, loop_check);

    // patch end_jump to here (loop exit)
    emit.patchJump(self, end_jump);
}

pub fn emitStorageLoad(
    self: *Compiler,
    storage: VarStorage,
) !void {
    switch (storage) {
        .local => |slot| try emit.emit(self, .load_local, slot),
        .global => |sym| try emit.emit(self, .load_global, sym),
    }
}

pub fn emitStorageStore(
    self: *Compiler,
    storage: VarStorage,
    is_const: bool,
) !void {
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
    try emitStorageLoad(self, iter_storage);
    try emit.@"const"(self, Data{ .atom = try self.vm.internAtom("__iter") });
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
        for (0..param_count) |idx| {
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

    // to restore after match
    // TODO: this also means you cant define globals from within matches
    //       i am genuinely surprised this doesnt break defining globals from arms
    //
    const saved_next_slot = self.slot_allocators.items[self.slot_allocators.items.len - 1];
    const saved_active = self.active_registers;
    const saved_max = self.max_registers;

    // single scope for whole match's subject
    try state.pushScope(self);
    errdefer state.popScope(self);
    errdefer {
        self.active_registers = saved_active;
        self.max_registers = saved_max;
        self.slot_allocators.items[self.slot_allocators.items.len - 1] = saved_next_slot;
    }

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

        // each arm gets its own lex scope for pattern variables
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

        if (matcher_expr) |me| try bindMatchPattern(self, me, subject_storage);

        if (arm.guard) |guard| {
            try self.compile(guard, true);
            const guard_jump = try emit.jump(self, .jump_if_false);
            try fail_list.append(self.alloc, guard_jump);
        }

        try self.compile(arm.then, true);

        // move arm result to canonical result location
        const arm_result_reg: Register = @intCast(self.active_registers - 1);
        if (arm_result_reg != arm_base_registers) {
            const move_instr: Instruction = .{
                .op = .move,
                .a = try toRegister(arm_base_registers),
                .b = try toRegister(arm_result_reg),
            };
            try self.instructions.append(self.alloc, move_instr);
            try self.spans.append(self.alloc, self.active_span);
        }
        try emit.regRelease(self); // pop arm result
        self.active_registers = arm_base_registers + 1; // result is now at arm_base_registers

        const end_jump = try emit.jump(self, .jump);
        try end_jumps.append(self.alloc, end_jump);

        // needs to happen before patching jumps so that pattern vars go out of scope
        state.popScope(self);

        const next_arm = self.instructions.items.len;
        for (fail_list.items) |jump_idx| {
            patchJumpToLabel(self, jump_idx, next_arm);
        }
    }
    state.popScope(self);

    // so that neighbouring code gets fresh slot numbers
    self.slot_allocators.items[self.slot_allocators.items.len - 1] = saved_next_slot;

    // default case & success patches
    self.active_registers = arm_base_registers;
    try emit.nil(self);
    for (end_jumps.items) |jump_idx| {
        emit.patchJump(self, jump_idx);
    }

    self.active_registers = arm_base_registers + 1;
}

pub fn patchJumpToLabel(self: *Compiler, jump_idx: usize, target: usize) void {
    self.instructions.items[jump_idx].bx = @intCast(target);
}

pub fn reserveRegisters(self: *Compiler, min_register: Register) void {
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
        .ident => {}, // wildcard in matcher position
        .tuple_pattern => |items| {
            // check tuple type
            try emit.emit(self, .load_global, try self.vm.internAtom("type"));
            try emitStorageLoad(self, subject);
            try emit.emit(self, .call, 1);
            try emit.@"const"(self, Data.new.atom(try self.vm.internAtom("tuple")));
            try emit.emit(self, .eq, 0);
            try fail_jumps.append(self.alloc, try emit.jump(self, .jump_if_false));

            // check exact tuple length
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
                try emitStorageLoad(self, subject);
                try emit.emit(self, .tuple_get_const, idx);
                const nested_slot = try state.declareLocal(self, "__match_tmp", false);
                state.markLocalInitialized(self, nested_slot);
                try emit.emit(self, .bind_local, nested_slot);
                state.reserveLocalSlots(self);
                const nested_fails = try compilePatternChecks(self, .{ .local = nested_slot }, item);
                for (nested_fails) |jump_idx| try fail_jumps.append(self.alloc, jump_idx);
                self.alloc.free(nested_fails);
                self.active_registers = depth_before;
            }
        },
        else => {
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
    try self.compile(then_expr, true);
    state.popScope(self);
    const then_registers = self.active_registers;
    const end_jump = try emit.jump(self, .jump);
    emit.patchJump(self, else_jump);
    self.active_registers = branch_base_registers;
    self.slot_allocators.items[self.slot_allocators.items.len - 1] = saved_next_slot;

    try state.pushScope(self);
    errdefer state.popScope(self);
    if (else_expr) |branch| try self.compile(branch, true) else try emit.nil(self);
    state.popScope(self);
    std.debug.assert(then_registers == self.active_registers);
    emit.patchJump(self, end_jump);
    self.slot_allocators.items[self.slot_allocators.items.len - 1] = saved_next_slot;
}

pub fn compileAnd(
    self: *Compiler,
    left: *const Node,
    right: *const Node,
) !void {
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
    const move_to_res: Instruction = .{ .op = .move, .a = try toRegister(loop_res), .b = try toRegister(r) };

    try self.instructions.append(self.alloc, move_to_res);
    try self.spans.append(self.alloc, self.active_span);
    const move_back: Instruction = .{ .op = .move, .a = try toRegister(r), .b = try toRegister(loop_res) };
    try self.instructions.append(self.alloc, move_back);
    try self.spans.append(self.alloc, self.active_span);
    const jump_idx = try emit.jump(self, .jump);
    try self.break_jumps.append(self.alloc, jump_idx);
}
