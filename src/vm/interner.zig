const std = @import("std");

const lang = revo.lang;
const lang_testing = revo.lang.testing;
const revo = @import("revo");

const VM = revo.VM;

const memory = @import("memory.zig");

pub const Interner = @This();

pub const Slot = struct {
    value: ?[]u8 = null,
    marked: bool = false,
    next_free: ?memory.StringID = null,
};

alloc: std.mem.Allocator,
slots: std.ArrayList(Slot),
by_name: std.StringHashMap(memory.StringID),
free_head: ?memory.StringID = null,

pub fn init(alloc: std.mem.Allocator) !Interner {
    var self = Interner{
        .alloc = alloc,
        .slots = try std.ArrayList(Slot).initCapacity(
            alloc,
            @typeInfo(revo.core_atoms).@"enum".fields.len,
        ),
        .by_name = std.StringHashMap(memory.StringID).init(alloc),
    };
    inline for (@typeInfo(revo.core_atoms).@"enum".fields) |field| {
        _ = try self.own(field.name);
    }
    return self;
}

pub fn deinit(self: *Interner) void {
    for (self.slots.items) |slot| {
        if (slot.value) |s| self.alloc.free(s);
    }
    self.by_name.deinit();
    self.slots.deinit(self.alloc);
}

fn insert(self: *Interner, owned: []u8) !memory.StringID {
    return try revo.allocSlot(
        Slot,
        memory.StringID,
        self.alloc,
        &self.slots,
        &self.free_head,
        .{ .value = owned },
    );
}

pub fn own(self: *Interner, value: []const u8) !memory.StringID {
    if (self.by_name.get(value)) |id| return id;
    const owned = try self.alloc.dupe(u8, value);
    errdefer self.alloc.free(owned);
    const id = try self.insert(owned);
    try self.by_name.put(owned, id);
    return id;
}

pub fn adopt(self: *Interner, value: []u8) !memory.StringID {
    if (self.by_name.get(value)) |id| {
        self.alloc.free(value);
        return id;
    }
    const id = try self.insert(value);
    try self.by_name.put(value, id);
    return id;
}

pub fn lookup(self: *const Interner, value: []const u8) ?memory.StringID {
    return self.by_name.get(value);
}

pub fn get(self: *const Interner, id: memory.StringID) ![]const u8 {
    if (id >= self.slots.items.len) return error.InvalidString;
    const slot = self.slots.items[id];
    return slot.value orelse error.InvalidString;
}

pub fn getAssumeAlive(self: *const Interner, id: memory.StringID) []const u8 {
    return self.slots.items[id].value.?;
}

pub fn mark(self: *Interner, id: memory.StringID) void {
    if (id >= self.slots.items.len) return;
    const slot = &self.slots.items[id];
    if (slot.value != null) slot.marked = true;
}

pub fn sweep(self: *Interner) void {
    revo.sweepSlots(Slot, memory.StringID, &self.slots, &self.free_head, self, Interner.finalizeSlot);
}

fn finalizeSlot(slot: *Slot, self: *Interner) void {
    if (slot.value) |s| {
        _ = self.by_name.remove(s);
        self.alloc.free(s);
    }
}

pub fn contains(self: *Interner, id: memory.StringID) bool {
    return id < self.slots.items.len and self.slots.items[id].value != null;
}

pub fn bytes(self: *const Interner) usize {
    var total: usize = 0;
    for (self.slots.items) |slot| {
        if (slot.value) |s| {
            total += 24;
            total += s.len;
        }
    }
    return total;
}

test "string literals survive source free" {
    var vm = try VM.init(lang_testing.runtime());
    defer vm.deinit();

    const alloc = lang_testing.runtime().alloc;
    const source = try alloc.dupe(u8, "\"hello\"");
    const artifact = switch (try lang.build(&vm, .{ .text = source }, .{})) {
        .ok => |ok| ok,
        .err => return error.ParseFailed,
    };
    alloc.free(source);
    defer alloc.free(artifact.instructions);
    defer alloc.free(artifact.spans);

    vm.mainFiber().program = artifact.instructions;
    try vm.run();

    const value = try vm.pop();
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings("hello", vm.stringValue(value.string));
}

test "interner deduplicates and reuses freed slot ids" {
    var interner = try Interner.init(std.testing.allocator);
    defer interner.deinit();

    const first = try interner.own("abc");
    const second = try interner.own("abc");
    try std.testing.expectEqual(first, second);

    interner.sweep();
    try std.testing.expect(!interner.contains(first));

    const reused = try interner.own("new");
    try std.testing.expectEqual(first, reused);
    try std.testing.expectEqualStrings("new", try interner.get(reused));
}
