const std = @import("std");

const revo = @import("revo");

const memory = revo.memory;
const Data = revo.Data;
const testing = revo.lang.testing;

pub const Tuple = struct {
    alloc: std.mem.Allocator,
    items: []Data,
    metatable: ?memory.TableID = null,

    pub fn deinit(self: *Tuple) void {
        self.alloc.free(self.items);
    }

    pub fn len(self: *const Tuple) usize {
        return self.items.len;
    }

    pub fn write(self: *Tuple, writer: *std.Io.Writer, vm: *revo.VM, mode: Data.RenderMode) !void {
        try writer.writeAll("(");
        for (self.items, 0..) |item, i| {
            if (i != 0) try writer.writeAll(", ");
            try item.write(writer, vm, mode);
        }
        if (self.items.len == 1) try writer.writeAll(",");
        try writer.writeAll(")");
    }
};

pub const TuplePool = struct {
    alloc: std.mem.Allocator,
    tuples: std.ArrayList(TupleSlot),
    free_head: ?memory.TupleID = null,

    pub const TupleSlot = struct {
        value: ?Tuple = null,
        marked: bool = false,
        next_free: ?memory.TupleID = null,
    };

    pub fn init(alloc: std.mem.Allocator) !TuplePool {
        return .{
            .alloc = alloc,
            .tuples = try std.ArrayList(TupleSlot).initCapacity(alloc, 4),
        };
    }

    pub fn deinit(self: *TuplePool) void {
        for (self.tuples.items) |*slot| {
            if (slot.value) |*tuple| {
                tuple.deinit();
            }
        }
        self.tuples.deinit(self.alloc);
    }

    pub fn create(self: *TuplePool, items: []const Data) !memory.TupleID {
        const owned = try self.alloc.dupe(Data, items);
        return try revo.allocSlot(
            TupleSlot,
            memory.TupleID,
            self.alloc,
            &self.tuples,
            &self.free_head,
            .{ .value = .{ .alloc = self.alloc, .items = owned } },
        );
    }

    pub fn get(self: *TuplePool, id: memory.TupleID) !*Tuple {
        if (id >= self.tuples.items.len) return error.InvalidTuple;
        const slot = &self.tuples.items[id];
        if (slot.value) |*tuple| return tuple;
        return error.InvalidTuple;
    }

    pub fn mark(self: *TuplePool, id: memory.TupleID, vm: *revo.VM) void {
        if (id >= self.tuples.items.len) return;
        const slot = &self.tuples.items[id];
        if (slot.value) |*tuple| {
            if (slot.marked) return;
            slot.marked = true;
            for (tuple.items) |item| vm.markData(item);
            if (tuple.metatable) |mt| vm.tables.mark(mt, vm);
        }
    }

    pub fn sweep(self: *TuplePool) void {
        revo.sweepSlots(TupleSlot, memory.TupleID, &self.tuples, &self.free_head, self, TuplePool.finalizeSlot);
    }

    fn finalizeSlot(slot: *TupleSlot, _: *TuplePool) void {
        if (slot.value) |*tuple| tuple.deinit();
    }

    pub fn bytes(self: *const TuplePool) usize {
        var total: usize = 0;
        for (self.tuples.items) |slot| {
            if (slot.value) |*tuple| {
                total += 32; // tuple base overhead
                total += @sizeOf(Data) * tuple.items.len; // per element
            }
        }
        return total;
    }
};

test "parses tuple literals and keeps paren grouping distinct" {
    try testing.expectPrinted("(1, 2, 3)", "(tuple 1 2 3)");
    try testing.expectPrinted("(_, x)", "(tuple _ x)");
    try testing.expectPrinted("(1,)", "(tuple 1)");
    try testing.expectPrinted("(1)", "1");
    try testing.top_nil("()");
}

test "parses tuple destructuring in bindings assignment and match" {
    try testing.expectPrinted(
        \\ const a, b = (:ok, "value")
        \\ (a, b) = (:err, "other")
        \\ match (:ok, "x")
        \\ | (:ok, value) value
        \\ | (:err, err) err
    , "(block (const (tuple-pattern a b) (tuple :ok \"value\")) (assign (tuple-pattern a b) (tuple :err \"other\")) (match (tuple :ok \"x\") (arm (tuple-pattern :ok value) value) (arm (tuple-pattern :err err) err)))");
}

test "tuple destructuring ignores extras but errors when too short" {
    try testing.top_number(
        \\ const a, b = (1, 2, 3)
        \\ a + b
    , 3);
}

test "tuple destructuring" {
    try testing.top_true(":true");
}

test "tuple length" {
    try testing.top_number(
        \\ const t = (1, 2, 3, 4, 5)
        \\ len(t)
    , 5);
}
