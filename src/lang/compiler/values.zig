const std = @import("std");

const revo = @import("revo");
const Data = revo.Data;
const Instruction = revo.Instruction;
const Compiler = revo.lang.compiler.Compiler;

const ast = @import("../ast.zig");
const Node = ast.Node;
const Binding = ast.Binding;
const StructItem = ast.StructItem;
const toRegister = @import("emit.zig").toRegister;
const emit = @import("emit.zig");
const state = @import("state.zig");
const flow = @import("flow.zig");

pub const BindingKind = enum { global, let, con };
pub const StructFieldTableKind = enum { fields, defaults, types };

pub fn compileLocalBinding(
    self: *Compiler,
    name: []const u8,
    value: *const Node,
    mutable: bool,
) !void {
    const slot = if (value.expr == .fn_expr)
        try state.reuseOrDeclareLocal(self, name, mutable)
    else
        try state.declareLocal(self, name, mutable);
    if (value.expr == .fn_expr) {
        try self.compileFn(value.expr.fn_expr.params, value.expr.fn_expr.body, name, null);
    } else {
        try self.compile(value, true);
    }
    state.markLocalInitialized(self, slot);
    state.markLocalValueKind(self, slot, switch (value.expr) {
        .tuple => .tuple_literal,
        else => .unknown,
    });
    try emit.regDupe(self);
    try emit.emit(self, .bind_local, slot);
}

pub fn bindPattern(
    self: *Compiler,
    pattern: *const Node,
    source_idx: usize,
    kind: BindingKind,
) !void {
    switch (pattern.expr) {
        .ident => |name| {
            if (ast.isDiscardName(name)) return;
            _ = try state.pushRegister(self);
            const move_instr: Instruction = .{
                .op = .move,
                .a = try toRegister(self.active_registers - 1),
                .b = try toRegister(source_idx),
            };
            try self.instructions.append(self.alloc, move_instr);
            try self.spans.append(self.alloc, self.active_span);
            switch (kind) {
                .con => try emit.emit(self, .store_global_const, try self.vm.internAtom(name)),
                .let, .global => try emit.emit(self, .store_global, try self.vm.internAtom(name)),
            }
        },
        .tuple_pattern => |items| {
            const mutable = kind != .con;
            for (items, 0..) |item, idx| {
                switch (item.expr) {
                    .ident => |name| {
                        if (ast.isDiscardName(name)) continue;
                        _ = try state.pushRegister(self);
                        const move_instr: Instruction = .{
                            .op = .move,
                            .a = try toRegister(self.active_registers - 1),
                            .b = try toRegister(source_idx),
                        };
                        try self.instructions.append(self.alloc, move_instr);
                        try self.spans.append(self.alloc, self.active_span);
                        try emit.emit(self, .tuple_get_const, idx);
                        try emit.emit(
                            self,
                            if (mutable) .store_global else .store_global_const,
                            try self.vm.internAtom(name),
                        );
                    },
                    .tuple_pattern => {
                        _ = try state.pushRegister(self);
                        const move_instr: Instruction = .{
                            .op = .move,
                            .a = try toRegister(self.active_registers - 1),
                            .b = try toRegister(source_idx),
                        };
                        try self.instructions.append(self.alloc, move_instr);
                        try self.spans.append(self.alloc, self.active_span);
                        try emit.emit(self, .tuple_get_const, idx);
                        try bindPattern(self, item, self.active_registers - 1, kind);
                    },
                    else => {},
                }
            }
        },
        else => {},
    }
}

pub fn compileTuple(self: *Compiler, items: []const *Node) !void {
    for (items) |item| try self.compile(item, true);
    try emit.emit(self, .tuple_new, @intCast(items.len));
}

pub fn compileAssign(
    self: *Compiler,
    target: *const Node,
    value: *const Node,
) !void {
    if (target.expr == .tuple_pattern) {
        try self.compile(value, true);
        const src_idx = self.active_registers - 1;
        try bindPattern(self, target, src_idx, .let);
        return;
    }
    try compileAssignSimple(self, target, value);
}

pub fn compileAssignSimple(
    self: *Compiler,
    target: *const Node,
    value: *const Node,
) !void {
    switch (target.expr) {
        .ident => |name| {
            try self.compile(value, true);
            try emit.regDupe(self);
            if (state.resolveLocal(self, name)) |slot| {
                try emit.emit(self, .store_local, slot);
                state.markLocalValueKind(self, slot, .unknown);
            } else if (try state.resolveUpvalue(self, name)) |slot| {
                try emit.emit(self, .store_upval, slot);
            } else {
                return self.fail(.InvalidAssignmentTarget, target, "assignment target is not declared");
            }
        },
        .field => |field| {
            try self.compile(field.object, true);
            try compileAssignIntoTableAtom(self, try self.vm.internAtom(field.name), value);
        },
        .index => |index| {
            try self.compile(index.object, true);
            if (index.key.expr == .hash) {
                try compileAssignIntoTableAtom(self, try self.vm.internAtom(index.key.expr.hash), value);
            } else {
                try self.compile(index.key, true);
                try compileAssignIntoTable(self, value);
            }
        },
        else => return self.fail(.InvalidAssignmentTarget, target, "invalid assignment target"),
    }
}
pub fn compileAssignIntoTable(self: *Compiler, value: *const Node) !void {
    try self.compile(value, true);
    try emit.emit(self, .table_set, 0);
    try emit.regRelease(self);
}

pub fn compileAssignIntoTableAtom(
    self: *Compiler,
    key_atom: revo.AtomID,
    value: *const Node,
) !void {
    try self.compile(value, true);
    try emit.emit(self, .table_set_atom, key_atom);
    try emit.regRelease(self);
}

pub fn compileStruct(
    self: *Compiler,
    expr: *const Node,
    name: []const u8,
    items: []const StructItem,
) !void {
    // always in synth toplevel __main, so always declare local
    const descriptor_slot = try state.reuseOrDeclareLocal(self, name, false);
    std.debug.assert(self.slot_allocators.items.len > 0);
    const idx = self.slot_allocators.items.len - 1;
    const descriptor_temp = self.slot_allocators.items[idx];
    self.slot_allocators.items[idx] += 1;
    state.reserveLocalSlots(self);

    const fields_id = try compileStructFieldTable(self, items, .fields);
    const defaults_id = try compileStructFieldTable(self, items, .defaults);
    const types_id = try compileStructFieldTable(self, items, .types);

    const fields_const = try self.vm.addConstant(Data.new.table(fields_id));
    const defaults_const = try self.vm.addConstant(Data.new.table(defaults_id));
    const types_const = try self.vm.addConstant(Data.new.table(types_id));
    const name_const = try self.vm.addConstant(try self.vm.ownDataString(name));

    try emit.emit(self, .table_new, 0);
    try flow.emitStorageStore(self, .{ .local = descriptor_temp }, false);

    // set all desc fields
    inline for (&[_]struct { key: []const u8, const_id: usize }{
        .{ .key = "__name", .const_id = name_const },
        .{ .key = "__fields", .const_id = fields_const },
        .{ .key = "__defaults", .const_id = defaults_const },
        .{ .key = "__types", .const_id = types_const },
    }) |entry| {
        try flow.emitStorageLoad(self, .{ .local = descriptor_temp });
        try emit.@"const"(self, Data.new.atom(try self.vm.internAtom(entry.key)));
        try emit.loadConst(self, entry.const_id);
        try emit.emit(self, .table_set, 0);
        try emit.regRelease(self);
    }

    for (items) |item| switch (item) {
        .field => {},
        .binding => |binding| {
            if (binding.target.expr != .ident)
                return self.fail(.UnsupportedSyntax, expr, "assignment target must be named");
            const key_atom = try self.vm.internAtom(binding.target.expr.ident);
            try flow.emitStorageLoad(self, .{ .local = descriptor_temp });
            try emit.@"const"(self, Data.new.atom(key_atom));
            if (binding.value.expr == .fn_expr) {
                try self.compileFn(
                    binding.value.expr.fn_expr.params,
                    binding.value.expr.fn_expr.body,
                    binding.target.expr.ident,
                    null,
                );
            } else {
                try self.compile(binding.value, true);
            }
            try emit.emit(self, .table_set, 0);
            try emit.regRelease(self);
        },
    };

    // __call mm for the desc bound to struct name
    try flow.emitStorageLoad(self, .{ .local = descriptor_temp });
    state.markLocalInitialized(self, descriptor_slot);
    try emit.regDupe(self);
    try emit.emit(self, .bind_local, descriptor_slot);
}

pub fn compileStructFieldTable(
    self: *Compiler,
    items: []const StructItem,
    kind: StructFieldTableKind,
) !revo.TableID {
    const table_id = try self.vm.tables.create();
    const table = self.vm.tables.get(table_id) catch {
        std.debug.assert(false);
        unreachable;
    };

    for (items) |item| switch (item) {
        .binding => {},
        .field => |field| {
            const key = Data.new.atom(try self.vm.internAtom(field.name));
            switch (kind) {
                .fields => table.putRaw(key, revo.core_atoms.data(.true)) catch return error.InvalidAssignmentTarget,
                .defaults => {
                    if (field.default_value) |value| table.putRaw(
                        key,
                        try constValueFromNode(self, value),
                    ) catch return error.InvalidAssignmentTarget;
                },
                .types => {
                    if (field.type_name) |type_name| table.putRaw(
                        key,
                        Data.new.atom(try self.vm.internAtom(type_name)),
                    ) catch return error.InvalidAssignmentTarget;
                },
            }
        },
    };

    return table_id;
}

pub fn constValueFromNode(self: *Compiler, node: *const Node) !Data {
    return switch (node.expr) {
        .number => |n| blk: {
            if (std.math.isFinite(n) and @floor(n) == n and
                n >= @as(f64, @floatFromInt(std.math.minInt(i64))) and
                n <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
            {
                break :blk Data.new.num(@as(i64, @intFromFloat(n)));
            }
            break :blk Data.new.num(n);
        },
        .string, .multiline_string => |s| try self.vm.ownDataString(s),
        .hash => |s| Data.new.atom(try self.vm.internAtom(s)),
        else => return self.fail(.UnsupportedSyntax, node, "struct defaults must be constant values"),
    };
}
pub fn compileTable(self: *Compiler, entries: []const ast.TableEntry) !void {
    try emit.emit(self, .table_new, 0);
    var array_index: i64 = 0;
    for (entries) |entry| {
        try emit.regDupe(self);
        if (entry.key) |key| {
            if (entry.computed) {
                try self.compile(key, true);
            } else switch (key.expr) {
                .ident => |name| try emit.@"const"(self, Data{ .atom = try self.vm.internAtom(name) }),
                else => try self.compile(key, true),
            }
        } else {
            try emit.@"const"(self, Data.new.num(array_index));
            array_index += 1;
        }
        try self.compile(entry.value, true);
        try emit.emit(self, .table_set, 0);
        try emit.regRelease(self);
    }
}
