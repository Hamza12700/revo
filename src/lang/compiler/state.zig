const std = @import("std");

const revo = @import("revo");
const Compiler = revo.lang.compiler.Compiler;
const LocalSlot = revo.LocalSlot;
const Register = revo.opcode.Register;
const UpvalueSpec = revo.functions.UpvalueSpec;

const ast = @import("../ast.zig");
const Expr = ast.Expr;
const Node = ast.Node;

pub const LocalValueKind = enum {
    unknown,
    tuple_literal,
};

pub const LocalVar = struct {
    name: []const u8,
    slot: LocalSlot,
    mutable: bool,
    initialized: bool,
    kind: LocalValueKind = .unknown,
};

pub const FunctionState = struct {
    locals: std.ArrayList(LocalVar),
    all_locals: std.ArrayList(LocalVar),
    upvalues: std.ArrayList(UpvalueSpec),
    scope_starts: std.ArrayList(usize),

    pub fn init(alloc: std.mem.Allocator) !FunctionState {
        return .{
            .locals = try std.ArrayList(LocalVar).initCapacity(alloc, 8),
            .all_locals = try std.ArrayList(LocalVar).initCapacity(alloc, 8),
            .upvalues = try std.ArrayList(UpvalueSpec).initCapacity(alloc, 4),
            .scope_starts = try std.ArrayList(usize).initCapacity(alloc, 8),
        };
    }

    pub fn deinit(self: *FunctionState, alloc: std.mem.Allocator) void {
        self.locals.deinit(alloc);
        self.all_locals.deinit(alloc);
        self.upvalues.deinit(alloc);
        self.scope_starts.deinit(alloc);
    }
};

pub const Temps = struct {
    pipe: usize = 0,
    match_subject: usize = 0,
    bind: usize = 0,
    match_temp: usize = 0,
};

pub fn LoopScope(comptime CompilerType: type) type {
    return struct {
        compiler: *CompilerType,
        break_start: usize,
        prev_in_loop: usize,

        pub fn init(compiler: *CompilerType) !@This() {
            const prev = compiler.in_loop_depth;
            compiler.in_loop_depth += 1;
            const result_reg = try pushRegister(compiler);
            try compiler.instructions.append(compiler.alloc, .{
                .op = .load_nil,
                .a = result_reg,
            });
            try compiler.spans.append(compiler.alloc, compiler.active_span);
            try compiler.loop_result_regs.append(compiler.alloc, result_reg);
            return .{
                .compiler = compiler,
                .break_start = compiler.break_jumps.items.len,
                .prev_in_loop = prev,
            };
        }

        pub fn deinit(self: *@This()) void {
            const c = self.compiler;
            _ = c.loop_result_regs.pop();
            const exit_addr: usize = c.instructions.items.len;
            while (c.break_jumps.items.len > self.break_start) {
                const idx = c.break_jumps.pop() orelse unreachable;
                c.instructions.items[idx].bx = @intCast(exit_addr);
            }
            c.in_loop_depth = self.prev_in_loop;
        }
    };
}

pub fn toRegister(n: usize) !Register {
    std.debug.assert(n <= std.math.maxInt(Register));
    return @intCast(n);
}

pub fn pushRegister(self: *Compiler) !Register {
    const reg_val = try toRegister(self.active_registers);
    self.active_registers += 1;
    if (self.active_registers > self.max_registers) self.max_registers = self.active_registers;
    return reg_val;
}
pub fn popRegister(self: *Compiler) void {
    std.debug.assert(self.active_registers > 0);
    self.active_registers -= 1;
    if (self.slot_allocators.items.len > 0) {
        const next_slot = self.slot_allocators.items[self.slot_allocators.items.len - 1];
        if (self.active_registers < next_slot) self.active_registers = next_slot;
    }
}

pub fn currentFunctionState(self: *Compiler) ?*FunctionState {
    if (self.functions.items.len == 0) return null;
    return &self.functions.items[self.functions.items.len - 1];
}

pub fn declareLocal(self: *Compiler, name: []const u8, mutable: bool) !LocalSlot {
    var state_ptr = currentFunctionState(self);
    if (state_ptr == null) {
        var state = try FunctionState.init(self.alloc);
        self.functions.append(self.alloc, state) catch |err| {
            state.deinit(self.alloc);
            return err;
        };
        self.slot_allocators.append(self.alloc, 0) catch |err| {
            // SAFETY: functions was just pushed above
            var leaked = self.functions.pop() orelse unreachable;
            leaked.deinit(self.alloc);
            return err;
        };
        state_ptr = &self.functions.items[self.functions.items.len - 1];
    }
    // SAFETY: state_ptr is set in the if block above if it was null
    const state = state_ptr orelse unreachable;
    const slot = self.slot_allocators.items[self.slot_allocators.items.len - 1];
    self.slot_allocators.items[self.slot_allocators.items.len - 1] += 1;
    const local: LocalVar = .{ .name = name, .slot = slot, .mutable = mutable, .initialized = false, .kind = .unknown };
    try state.locals.append(self.alloc, local);
    try state.all_locals.append(self.alloc, local);
    return slot;
}

pub fn reserveLocalSlots(self: *Compiler) void {
    if (self.slot_allocators.items.len > 0) {
        const next_slot = self.slot_allocators.items[self.slot_allocators.items.len - 1];
        if (self.active_registers < next_slot) self.active_registers = next_slot;
        if (self.max_registers < next_slot) self.max_registers = next_slot;
    }
}

pub fn currentScopeStartIn(self: *const Compiler, fn_index: usize) usize {
    const state = self.functions.items[fn_index];
    if (state.scope_starts.items.len == 0) return 0;
    return state.scope_starts.items[state.scope_starts.items.len - 1];
}

pub fn pushScope(self: *Compiler) !void {
    const state = currentFunctionState(self) orelse return;
    try state.scope_starts.append(self.alloc, state.locals.items.len);
}

pub fn popScope(self: *Compiler) void {
    const state = currentFunctionState(self) orelse return;
    const start = state.scope_starts.pop() orelse return;
    state.locals.items.len = start;
}

pub fn findLocalInCurrentScope(self: *Compiler, name: []const u8) ?*LocalVar {
    const fn_index = if (self.functions.items.len == 0) return null else self.functions.items.len - 1;
    const state = &self.functions.items[fn_index];
    const start = currentScopeStartIn(self, fn_index);
    var i = state.locals.items.len;
    while (i > start) {
        i -= 1;
        if (std.mem.eql(u8, state.locals.items[i].name, name)) return &state.locals.items[i];
    }
    return null;
}

pub fn reuseOrDeclareLocal(self: *Compiler, name: []const u8, mutable: bool) !LocalSlot {
    if (findLocalInCurrentScope(self, name)) |local| {
        if (!local.initialized) return local.slot;
    }
    return declareLocal(self, name, mutable);
}

pub fn markLocalInitialized(self: *Compiler, slot: LocalSlot) void {
    const state = currentFunctionState(self) orelse return;
    var i = state.locals.items.len;
    while (i > 0) {
        i -= 1;
        if (state.locals.items[i].slot == slot) {
            state.locals.items[i].initialized = true;
            return;
        }
    }
    unreachable;
}

pub fn markLocalValueKind(self: *Compiler, slot: LocalSlot, kind: LocalValueKind) void {
    const state = currentFunctionState(self) orelse return;

    var i = state.locals.items.len;
    while (i > 0) {
        i -= 1;
        if (state.locals.items[i].slot == slot) {
            state.locals.items[i].kind = kind;
            break;
        }
    }

    i = state.all_locals.items.len;
    while (i > 0) {
        i -= 1;
        if (state.all_locals.items[i].slot == slot) {
            state.all_locals.items[i].kind = kind;
            break;
        }
    }
}

pub fn predeclareFunctionBindings(self: *Compiler, exprs: []const *Node) !void {
    for (exprs) |expr| switch (expr.expr) {
        .con_expr => |binding| {
            if (binding.target.expr != .ident or binding.value.expr != .fn_expr) continue;
            const name = binding.target.expr.ident;
            if (ast.isDiscardName(name)) continue;
            _ = try reuseOrDeclareLocal(self, name, false);
        },
        .let_expr => |binding| {
            if (binding.target.expr != .ident or binding.value.expr != .fn_expr) continue;
            const name = binding.target.expr.ident;
            if (ast.isDiscardName(name)) continue;
            _ = try reuseOrDeclareLocal(self, name, true);
        },
        else => {},
    };
}

pub fn resolveLocalVarIn(self: *const Compiler, fn_index: usize, name: []const u8) ?LocalVar {
    const locals = self.functions.items[fn_index].locals.items;
    var i = locals.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, locals[i].name, name)) return locals[i];
    }
    return null;
}

pub fn resolveLocal(self: *const Compiler, name: []const u8) ?LocalSlot {
    if (self.functions.items.len == 0) return null;
    return if (resolveLocalVarIn(self, self.functions.items.len - 1, name)) |v| v.slot else null;
}

pub fn resolveLocalVar(self: *const Compiler, name: []const u8) ?LocalVar {
    if (self.functions.items.len == 0) return null;
    return resolveLocalVarIn(self, self.functions.items.len - 1, name);
}

pub fn constTupleIndex(self: *const Compiler, index: @FieldType(Expr, "index")) ?usize {
    const key_num = switch (index.key.expr) {
        .number => |n| n,
        else => return null,
    };

    if (!std.math.isFinite(key_num) or @floor(key_num) != key_num or key_num < 0 or
        key_num > @as(f64, @floatFromInt(std.math.maxInt(usize))))
    {
        return null;
    }

    const object_is_tuple_local = switch (index.object.expr) {
        .ident => |name| blk: {
            const local = resolveLocalVar(self, name) orelse break :blk false;
            break :blk local.kind == .tuple_literal;
        },
        .tuple => true,
        else => false,
    };
    if (!object_is_tuple_local) return null;
    return @as(usize, @intFromFloat(key_num));
}

pub fn addUpvalue(self: *Compiler, fn_index: usize, spec: UpvalueSpec) !revo.UpvalueID {
    const state = &self.functions.items[fn_index];
    for (state.upvalues.items, 0..) |existing, idx| {
        if (existing.is_local == spec.is_local and existing.index == spec.index and existing.mutable == spec.mutable)
            return @intCast(idx);
    }
    const idx: revo.UpvalueID = @intCast(state.upvalues.items.len);
    try state.upvalues.append(self.alloc, spec);
    return idx;
}

pub fn resolveUpvalueRecursive(self: *Compiler, fn_index: usize, name: []const u8) !?revo.UpvalueID {
    // TODO: mark all recursive functions
    // walk outward through function states and capture when need be
    if (fn_index == 0) return null;
    const enc = fn_index - 1;
    if (resolveLocalVarIn(self, enc, name)) |local| {
        return try addUpvalue(self, fn_index, .{ .is_local = true, .index = local.slot, .mutable = local.mutable });
    }
    if (try resolveUpvalueRecursive(self, enc, name)) |slot| {
        std.debug.assert(slot < self.functions.items[enc].upvalues.items.len);
        const spec = self.functions.items[enc].upvalues.items[slot];
        return try addUpvalue(self, fn_index, .{ .is_local = false, .index = @intCast(slot), .mutable = spec.mutable });
    }
    return null;
}

pub fn resolveUpvalue(self: *Compiler, name: []const u8) !?revo.UpvalueID {
    if (self.functions.items.len == 0) return null;
    return resolveUpvalueRecursive(self, self.functions.items.len - 1, name);
}

pub fn collectConstLocals(self: *Compiler, locals: []const LocalVar) ![]LocalSlot {
    var out = try std.ArrayList(LocalSlot).initCapacity(self.alloc, locals.len);
    defer out.deinit(self.alloc);
    for (locals) |local| if (!local.mutable) try out.append(self.alloc, local.slot);
    return out.toOwnedSlice(self.alloc);
}
