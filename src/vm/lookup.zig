const std = @import("std");

const revo = @import("revo");

const Data = @import("memory.zig").Data;
const mem = @import("memory.zig");
const VM = @import("VM.zig");

pub const FieldLookup = struct {
    value: Data,
    from_meta: bool,
};

pub fn resolveField(self: *VM, object: Data, key: Data) VM.EvalError!?FieldLookup {
    switch (object) {
        .table => |table_id| {
            const t = try self.tables.get(table_id);
            if (key == .atom) {
                if (try t.structFieldIndex(self, key.atom)) |field_idx| {
                    if (field_idx < t.array.items.len)
                        return .{ .value = t.array.items[field_idx], .from_meta = false };
                }
            }
            if (t.getRaw(key)) |value| {
                return .{ .value = value, .from_meta = false };
            }
            if (t.metatable) |mt_id| {
                if (try resolveViaMetatable(self, object, key, mt_id)) |resolved| {
                    return resolved;
                }
            }
            const type_mt_id = self.metatables[@intFromEnum(std.meta.Tag(Data).table)] orelse return null;
            return resolveViaMetatable(self, object, key, type_mt_id);
        },
        .tuple => |tuple_id| {
            var instance_mt_id: ?@TypeOf(self.metatables[0].?) = null;
            var tuple_ref: ?*revo.tuple.Tuple = null;
            if (self.tuples.get(tuple_id)) |t| {
                tuple_ref = t;
                instance_mt_id = t.metatable;
            } else |_| {} // invalid tuple id, fall through to use default metatable

            // fast path::: tuple numeric indexing should not require mm lookup
            if (tuple_ref) |t| {
                const idx_opt: ?usize = switch (key) {
                    .number => |n| if (n >= 0 and @floor(n) == n and n <= @as(f64, @floatFromInt(std.math.maxInt(usize)))) @as(usize, @intFromFloat(n)) else null,
                    else => null,
                };
                if (idx_opt) |idx| {
                    if (idx < t.items.len) {
                        return .{ .value = t.items[idx], .from_meta = false };
                    }
                    return null;
                }
            }

            if (instance_mt_id) |mt_id| {
                if (try resolveViaMetatable(self, object, key, mt_id)) |resolved| {
                    return resolved;
                }
            }

            const type_mt_id = self.metatables[@intFromEnum(std.meta.Tag(Data).tuple)] orelse return null;
            if (instance_mt_id != null and instance_mt_id.? == type_mt_id) return null;
            return resolveViaMetatable(self, object, key, type_mt_id);
        },
        else => {
            const mt_id = try self.getMetatableId(object) orelse return null;
            return resolveViaMetatable(self, object, key, mt_id);
        },
    }
}

fn resolveViaMetatable(self: *VM, object: Data, key: Data, mt_id: @TypeOf(self.metatables[0].?)) VM.EvalError!?FieldLookup {
    const mt = try self.tables.get(mt_id);
    if (mt.getRaw(key)) |value| {
        return .{ .value = value, .from_meta = true };
    }
    if (mt.getRaw(.{ .atom = revo.core_atoms.atom_id(.__index) })) |indexer| {
        self.perf.meta_index_fallbacks += 1;
        return resolveIndex(self, object, key, indexer);
    }
    return null;
}

pub fn resolveIndex(self: *VM, object: Data, key: Data, indexer: Data) VM.EvalError!?FieldLookup {
    switch (indexer) {
        .function => |fn_id| {
            const func = try self.functions.get(fn_id);
            const value = switch (func.*) {
                .closure => |closure| switch (closure.arity) {
                    1 => try self.callFunction(indexer, &.{object}),
                    else => try self.callFunction(indexer, &.{ object, key }),
                },
                .native => try self.callFunction(indexer, &.{ object, key }),
                .c_function => try self.callFunction(indexer, &.{ object, key }),
            };
            return .{ .value = value, .from_meta = true };
        },
        .table => |table_id| {
            const index_table = try self.tables.get(table_id);
            if (index_table.getRaw(key)) |value| {
                return .{ .value = value, .from_meta = true };
            }
            if (index_table.metatable) |mt_id| {
                const mt = try self.tables.get(mt_id);
                if (mt.getRaw(key)) |value| {
                    return .{ .value = value, .from_meta = true };
                }
                if (mt.getRaw(.{ .atom = revo.core_atoms.atom_id(.__index) })) |next_indexer| {
                    self.perf.meta_index_fallbacks += 1;
                    return resolveIndex(self, .{ .table = table_id }, key, next_indexer);
                }
            }
            return null;
        },
        else => return .{ .value = indexer, .from_meta = true },
    }
}

pub fn callField(self: *VM, argc: usize) VM.EvalError!void {
    const slots = self.currentFiber().slots.items;
    const key_slot = slots.len - argc - 1;
    const object_slot = key_slot - 1;
    const object = slots[object_slot];
    const key = slots[key_slot];
    const lookup = (try resolveField(self, object, key)) orelse {
        self.currentFiber().slots.items.len = object_slot;
        const key_name = switch (key) {
            .atom => |atom| self.atomName(atom),
            else => revo.std_lib.dataToString(key),
        };
        try self.setRuntimeMessageFmt("field `{s}` does not exist on {s}", .{
            key_name,
            revo.std_lib.typeof(object),
        });
        return error.NotAFunction;
    };

    if (!lookup.from_meta) {
        self.currentFiber().slots.items[key_slot] = lookup.value;
        std.mem.copyForwards(
            Data,
            self.currentFiber().slots.items[object_slot .. self.currentFiber().slots.items.len - 1],
            self.currentFiber().slots.items[key_slot..self.currentFiber().slots.items.len],
        );
        self.currentFiber().slots.items.len -= 1;
        try callViaStackLayout(self, object_slot, argc);
        return;
    }

    self.currentFiber().slots.items[object_slot] = lookup.value;
    self.currentFiber().slots.items[key_slot] = object;
    try callViaStackLayout(self, object_slot, argc + 1);
}

fn callViaStackLayout(self: *VM, callee_slot: usize, argc: usize) VM.EvalError!void {
    const args_start = callee_slot + 1;
    const args_end = args_start + argc;
    const callee = self.currentFiber().slots.items[callee_slot];
    try self.currentFiber().slots.ensureTotalCapacity(self.runtime.alloc, self.currentFiber().slots.items.len + argc + 1);
    const result = try self.callFunction(callee, self.currentFiber().slots.items[args_start..args_end]);
    self.currentFiber().slots.items.len = callee_slot;
    try self.currentFiber().slots.append(self.runtime.alloc, result);
}

pub fn setMetatable(self: *VM, val: Data, mt: ?mem.TableID) !void {
    switch (val) {
        .table => |id| {
            try self.setTableMetatable(id, mt);
        },
        .tuple => |id| {
            if (self.tuples.get(id)) |tuple_ref| {
                tuple_ref.metatable = mt;
            } else |_| {
                self.metatables[@intFromEnum(std.meta.Tag(Data).tuple)] = mt;
            }
        },
        .number => self.metatables[@intFromEnum(std.meta.Tag(Data).number)] = mt,
        else => self.metatables[@intFromEnum(std.meta.activeTag(val))] = mt,
    }
}

pub fn setTableMetatable(self: *VM, id: mem.TableID, mt: ?mem.TableID) !void {
    if (self.tables.isValid(id)) {
        const tbl_ref = try self.tables.get(id);
        tbl_ref.metatable = mt;
    } else {
        self.metatables[@intFromEnum(std.meta.Tag(Data).table)] = mt;
    }
}

pub fn setStructInstanceTable(self: *VM, id: mem.TableID, descriptor_id: mem.TableID) !void {
    try self.setTableMetatable(id, descriptor_id);
}

pub fn getMetatable(self: *VM, val: Data) !?*revo.table.Table {
    const id = try self.getMetatableId(val) orelse return null;
    return self.tables.get(id) catch return null;
}

pub fn getMetamethod(self: *VM, val: Data, name: []const u8) !?Data {
    return self.getMetamethodByAtom(val, try self.internAtom(name));
}
