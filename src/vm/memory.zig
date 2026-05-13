const std = @import("std");

const revo = @import("revo");

pub const StringID = usize;
pub const AtomID = usize;
pub const FunctionID = usize;
pub const TableID = usize;
pub const TupleID = usize;

pub const Type = enum(u4) { number = 0, string = 1, atom = 2, function = 3, table = 4, tuple = 5 };

pub const Data = union(Type) {
    number: f64,
    string: StringID,
    atom: AtomID,
    function: FunctionID, // id into FunctionPool
    table: TableID, // id into TablePool
    tuple: TupleID, // id into TuplePool

    pub const new = struct {
        pub inline fn num(val: anytype) Data {
            return .{ .number = switch (@typeInfo(@TypeOf(val))) {
                .comptime_int, .int => @as(f64, @floatFromInt(val)),
                .comptime_float, .float => val,
                else => @compileError("new.num expects int or float"),
            } };
        }
        pub inline fn nil() Data {
            return revo.core_atoms.data(.nil);
        }
        pub inline fn str(id: StringID) Data {
            return .{ .string = id };
        }
        pub inline fn atom(id: AtomID) Data {
            return .{ .atom = id };
        }
        pub inline fn boolean(val: bool) Data {
            return if (val) revo.core_atoms.data(.true) else revo.core_atoms.data(.false);
        }
        pub inline fn table(id: TableID) Data {
            return .{ .table = id };
        }
        pub inline fn tuple(id: TupleID) Data {
            return .{ .tuple = id };
        }
    };

    pub const RenderMode = enum(u1) { display, debug };

    pub fn write(self: Data, writer: *std.Io.Writer, vm: *revo.VM, mode: RenderMode) anyerror!void {
        if (mode == .debug) {
            if (try vm.getMetamethod(self, "__debug")) |mm| {
                const result = switch (mm) {
                    .function => try vm.callFunction(mm, &.{self}),
                    else => return error.TypeError,
                };
                switch (result) {
                    .string => |id| {
                        try writer.writeAll(vm.stringValue(id));
                        return;
                    },
                    else => return error.TypeError,
                }
            }
        }

        switch (self) {
            .number => |n| {
                try writer.print("{}", .{n});
            },
            .string => |id| switch (mode) {
                .display => try writer.writeAll(vm.stringValue(id)),
                .debug => {
                    try writer.print("\"{s}\"", .{vm.stringValue(id)});
                },
            },
            .atom => |id| {
                try writer.print(":{s}", .{vm.atomName(id)});
            },
            .function => |id| {
                const f = try vm.functions.get(id);
                switch (f.*) {
                    .native => {
                        try writer.print("#fn(){}/{}", .{ id, f.arity() });
                    },
                    .c_function => |cf| {
                        try writer.print("${s}@{}()/{}", .{ cf.name, id, f.arity() });
                    },
                    .closure => {
                        try writer.print("{s}()/{d}", .{ f.name(), f.arity() });
                    },
                }
            },
            .table => |id| {
                const table = vm.tables.get(id) catch {
                    try writer.writeAll("<dead-table>");
                    return;
                };
                table.write(writer, vm, mode) catch {
                    try writer.writeAll("<table-unprintable>");
                };
            },
            .tuple => |id| {
                const tuple = vm.tuples.get(id) catch {
                    try writer.writeAll("<dead-tuple>");
                    return;
                };
                tuple.write(writer, vm, mode) catch {
                    try writer.writeAll("<tuple-unprintable>");
                };
            },
        }
    }

    pub fn print(self: Data, vm: *revo.VM) void {
        var buf: [16]u8 = undefined;
        var stdout = vm.runtime.stdout.writer(vm.runtime.io, &buf);
        self.write(&stdout.interface, vm, .debug) catch {
            std.debug.print("<print-error>", .{});
            return;
        };
    }

    pub fn as_number(self: Data) !f64 {
        return switch (self) {
            .number => |v| v,
            else => error.TypeError,
        };
    }
};
