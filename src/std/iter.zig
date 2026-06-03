/// every iter entry is registered in 4 places rn:
///   - global function
///   - string metatable
///   - tuple metatable
///   - table metatable
/// this is by design, even the "not giving them a whole iter module" part
const places: []const api.Placement = &.{
    api.g,
    api.method("string", .string),
    api.method("tuple", .tuple),
    api.method("table", .table),
};

pub const specs: []const api.FnSpec = &.{
    .{
        .name = "map",
        .placements = &.{
            api.g,
            api.method("string", .string),
            api.method("tuple", .tuple),
            api.method("table", .table),
        },
        .params = &.{
            .{ "collection", "any" },
            .{ "fn", "function" },
        },
        .ret = "string|tuple|table",
        .doc =
        \\transforms each element by applying function
        \\    map("hello", fn(c) = c:upper())
        \\    map((1,2,3), fn(x) = x * 2)
        \\    map({a=1, b=2}, fn(v) = v + 10)
        ,
        .f = root.define(&.{ .any, .function }, map_fn),
    },
    .{
        .name = "filter",
        .placements = places,
        .params = &.{
            .{ "collection", "any" },
            .{ "pred", "function" },
        },
        .ret = "string|tuple|table",
        .doc =
        \\keeps only elements where function returns true
        \\    filter("hello", fn(c) = c != "l")
        \\    filter((1,2,3,4), fn(x) = x > 2)
        \\    filter({a=1, b=2}, fn(v) = v > 1)
        ,
        .f = root.define(&.{ .any, .function }, filter_fn),
    },
    .{
        .name = "reduce",
        .placements = places,
        .params = &.{
            .{ "collection", "any" },
            .{ "fn", "function" },
            .{ "init", "any" },
        },
        .ret = "any",
        .doc =
        \\folds/accumulates elements using function and initial value
        \\    reduce((1,2,3,4), fn(acc, x) = acc + x, 0)
        \\    reduce("hello", fn(acc, c) = acc + 1, 0)
        \\    reduce({a=1, b=2}, fn(acc, v) = acc + v, 0)
        ,
        .f = root.define(&.{ .any, .function, .any }, reduce_fn),
    },
    .{
        .name = "each",
        .placements = places,
        .params = &.{
            .{ "collection", "any" },
            .{ "fn", "function" },
        },
        .ret = ":ok",
        .doc =
        \\iterates over elements, calling function for side effects, returns :ok
        \\    each("hello", fn(c) = print(c))
        \\    each((1,2,3), fn(x) = print(x))
        \\    each({a=1, b=2}, fn(v) = print(v))
        ,
        .f = root.define(&.{ .any, .function }, each_fn),
    },
    .{
        .name = "find",
        .placements = places,
        .params = &.{
            .{ "what", "any" },
            .{ "fn", "function" },
        },
        .ret = "any",
        .doc =
        \\returns first element where function returns true, or :missing if not found
        \\    find("hello", fn(c) = c == "l")
        \\    find((1,2,3,4), fn(x) = x > 2)
        \\    find({a=1, b=2}, fn(v) = v > 1)
        ,
        .f = root.define(&.{ .any, .function }, find_fn),
    },
    .{
        .name = "all?",
        .placements = places,
        .params = &.{
            .{ "collection", "any" },
            .{ "pred", "function" },
        },
        .ret = "boolean",
        .doc =
        \\returns true if function returns true for all elements
        \\    all?((1,2,3), fn(x) = x > 0)
        \\    all?("hello", fn(c) = c != " ")
        \\    all?({a=1, b=2}, fn(v) = v > 0)
        ,
        .f = root.define(&.{ .any, .function }, all_fn),
    },
    .{
        .name = "any?",
        .placements = places,
        .params = &.{
            .{ "collection", "any" },
            .{ "pred", "function" },
        },
        .ret = "boolean",
        .doc =
        \\returns true if function returns true for any element
        \\    any?((1,2,3), fn(x) = x > 2)
        \\    any?("hello", fn(c) = c == "l")
        \\    any?({a=1, b=2}, fn(v) = v > 1)
        ,
        .f = root.define(&.{ .any, .function }, any_fn),
    },
};

/// > map(collection: string|tuple|table, fn: function) -> string|tuple|table
/// transforms each element by applying function
///     map("hello", fn(c) = c:upper())
///     map((1,2,3), fn(x) = x * 2)
///     map({a=1, b=2}, fn(v) = v + 10)
pub fn map_fn(args: []const Data, vm: *VM) !NativeResult {
    if (args.len < 2) return .errArity(args.len, 2);

    const fn_data = args[1];
    if (!fn_data.isFunction()) return .errType(1, "function", dataToString(fn_data));

    switch (args[0].tag()) {
        .string => {
            const str = vm.stringValue(args[0].asString().?);
            var buf = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, str.len);
            errdefer buf.deinit(vm.runtime.alloc);

            for (str) |byte| {
                const char_str = try vm.ownDataString(&[_]u8{byte});
                const fn_result = try vm.callFunction(fn_data, &[_]Data{char_str});

                const mapped_byte = if (fn_result.asString()) |s|
                    vm.stringValue(s)[0]
                else if (fn_result.asNum()) |n|
                    @as(u8, @intFromFloat(std.math.clamp(@round(n), 0, 255)))
                else
                    return .errType(0, "string or number", dataToString(fn_result));
                try buf.append(vm.runtime.alloc, mapped_byte);
            }

            const result_str = try vm.adoptDataString(try buf.toOwnedSlice(vm.runtime.alloc));
            return .{ .ok = result_str };
        },
        .tuple => {
            const t_id = args[0].asTuple().?;
            const tuple = try vm.tuples.get(t_id);
            var result_items = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, tuple.items.len);
            errdefer result_items.deinit(vm.runtime.alloc);

            for (tuple.items) |item| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{item});
                try result_items.append(vm.runtime.alloc, fn_result);
            }

            const result_tuple = try vm.tuples.create(result_items.items);
            result_items.deinit(vm.runtime.alloc);
            return .okData(Data.new.tuple(result_tuple));
        },
        .table => {
            const table_id = args[0].asTable().?;
            const result_table_id = try vm.tables.create();
            const result_table = try vm.tables.get(result_table_id);
            const table = try vm.tables.get(table_id);

            for (table.array.items) |item| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{item});
                try result_table.array.append(vm.runtime.alloc, fn_result);
            }

            for (table.hash_order.items) |key| {
                if (table.getRaw(key)) |val| {
                    const fn_result = try vm.callFunction(fn_data, &[_]Data{val});
                    try result_table.putRaw(key, fn_result);
                }
            }

            return .okData(Data.new.table(result_table_id));
        },
        else => return .errType(0, "string, tuple, or table", dataToString(args[0])),
    }
}

/// > filter(collection: string|tuple|table, fn: function) -> string|tuple|table
/// keeps only elements where function returns true
///     filter("hello", fn(c) = c != "l")
///     filter((1,2,3,4), fn(x) = x > 2)
///     filter({a=1, b=2}, fn(v) = v > 1)
pub fn filter_fn(args: []const Data, vm: *VM) !NativeResult {
    if (args.len < 2) return .errArity(args.len, 2);

    const fn_data = args[1];
    if (!fn_data.isFunction()) return .errType(1, "function", dataToString(fn_data));

    switch (args[0].tag()) {
        .string => {
            const str = vm.stringValue(args[0].asString().?);
            var buf = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, str.len);
            errdefer buf.deinit(vm.runtime.alloc);

            for (str) |byte| {
                const char_str = try vm.ownDataString(&[_]u8{byte});
                const fn_result = try vm.callFunction(fn_data, &[_]Data{char_str});
                if (isTruthy(fn_result)) {
                    try buf.append(vm.runtime.alloc, byte);
                }
            }

            const result_str = try vm.adoptDataString(try buf.toOwnedSlice(vm.runtime.alloc));
            return .{ .ok = result_str };
        },
        .tuple => {
            const t_id = args[0].asTuple().?;
            const tuple = try vm.tuples.get(t_id);
            var result_items = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, tuple.items.len);
            errdefer result_items.deinit(vm.runtime.alloc);

            for (tuple.items) |item| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{item});
                if (isTruthy(fn_result)) {
                    try result_items.append(vm.runtime.alloc, item);
                }
            }

            const result_tuple = try vm.tuples.create(result_items.items);
            result_items.deinit(vm.runtime.alloc);
            return .okData(Data.new.tuple(result_tuple));
        },
        .table => {
            const table_id = args[0].asTable().?;
            const result_table_id = try vm.tables.create();
            const result_table = try vm.tables.get(result_table_id);
            const table = try vm.tables.get(table_id);

            for (table.array.items) |item| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{item});
                if (isTruthy(fn_result)) {
                    try result_table.array.append(vm.runtime.alloc, item);
                }
            }

            for (table.hash_order.items) |key| {
                if (table.getRaw(key)) |val| {
                    const fn_result = try vm.callFunction(fn_data, &[_]Data{val});
                    if (isTruthy(fn_result)) {
                        try result_table.putRaw(key, val);
                    }
                }
            }

            return .okData(Data.new.table(result_table_id));
        },
        else => return .errType(0, "string, tuple, or table", dataToString(args[0])),
    }
}

/// > reduce(collection: string|tuple|table, fn: function, init: any) -> any
/// folds/accumulates elements using function and initial value
///     reduce((1,2,3,4), fn(acc, x) = acc + x, 0)
///     reduce("hello", fn(acc, c) = acc + 1, 0)
///     reduce({a=1, b=2}, fn(acc, v) = acc + v, 0)
pub fn reduce_fn(args: []const Data, vm: *VM) !NativeResult {
    if (args.len < 3) return .errArity(args.len, 3);

    const fn_data = args[1];
    if (!fn_data.isFunction()) return .errType(1, "function", dataToString(fn_data));

    var accumulator = args[2];

    switch (args[0].tag()) {
        .string => {
            const str = vm.stringValue(args[0].asString().?);
            for (str) |byte| {
                const char_str = try vm.ownDataString(&[_]u8{byte});
                accumulator = try vm.callFunction(fn_data, &[_]Data{ accumulator, char_str });
            }
        },
        .tuple => {
            const t_id = args[0].asTuple().?;
            const tuple = try vm.tuples.get(t_id);
            for (tuple.items) |item| {
                accumulator = try vm.callFunction(fn_data, &[_]Data{ accumulator, item });
            }
        },
        .table => {
            const table_id = args[0].asTable().?;
            const table = try vm.tables.get(table_id);

            for (table.array.items) |item| {
                accumulator = try vm.callFunction(fn_data, &[_]Data{ accumulator, item });
            }

            for (table.hash_order.items) |key| {
                if (table.getRaw(key)) |val| {
                    accumulator = try vm.callFunction(fn_data, &[_]Data{ accumulator, val });
                }
            }
        },
        else => return .errType(0, "string, tuple, or table", dataToString(args[0])),
    }

    return .{ .ok = accumulator };
}

/// > each(collection: string|tuple|table, fn: function) -> atom
/// iterates over elements, calling function for side effects, returns :ok
///     each("hello", fn(c) = print(c))
///     each((1,2,3), fn(x) = print(x))
///     each({a=1, b=2}, fn(v) = print(v))
pub fn each_fn(args: []const Data, vm: *VM) !NativeResult {
    if (args.len < 2) return .errArity(args.len, 2);

    const fn_data = args[1];
    if (!fn_data.isFunction()) return .errType(1, "function", dataToString(fn_data));

    switch (args[0].tag()) {
        .string => {
            const str = vm.stringValue(args[0].asString().?);
            for (str) |byte| {
                const char_str = try vm.ownDataString(&[_]u8{byte});
                _ = try vm.callFunction(fn_data, &[_]Data{char_str});
            }
        },
        .tuple => {
            const t_id = args[0].asTuple().?;
            const tuple = try vm.tuples.get(t_id);
            for (tuple.items) |item| {
                _ = try vm.callFunction(fn_data, &[_]Data{item});
            }
        },
        .table => {
            const table_id = args[0].asTable().?;
            const table = try vm.tables.get(table_id);

            for (table.array.items) |item| {
                _ = try vm.callFunction(fn_data, &[_]Data{item});
            }

            for (table.hash_order.items) |key| {
                if (table.getRaw(key)) |val| {
                    _ = try vm.callFunction(fn_data, &[_]Data{val});
                }
            }
        },
        else => return .errType(0, "string, tuple, or table", dataToString(args[0])),
    }

    return root.okAtom(vm);
}

/// > find(collection: string|tuple|table, fn: function) -> any
/// returns first element where function returns true, or :missing if not found
///     find("hello", fn(c) = c == "l")
///     find((1,2,3,4), fn(x) = x > 2)
///     find({a=1, b=2}, fn(v) = v > 1)
pub fn find_fn(args: []const Data, vm: *VM) !NativeResult {
    if (args.len < 2) return .errArity(args.len, 2);

    const fn_data = args[1];
    if (!fn_data.isFunction()) return .errType(1, "function", dataToString(fn_data));

    switch (args[0].tag()) {
        .string => {
            const str = vm.stringValue(args[0].asString().?);
            for (str) |byte| {
                const char_str = try vm.ownDataString(&[_]u8{byte});
                const fn_result = try vm.callFunction(fn_data, &[_]Data{char_str});
                if (isTruthy(fn_result)) {
                    return .{ .ok = char_str };
                }
            }
        },
        .tuple => {
            const t_id = args[0].asTuple().?;
            const tuple = try vm.tuples.get(t_id);
            for (tuple.items) |item| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{item});
                if (isTruthy(fn_result)) {
                    return .{ .ok = item };
                }
            }
        },
        .table => {
            const table_id = args[0].asTable().?;
            const table = try vm.tables.get(table_id);

            for (table.array.items) |item| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{item});
                if (isTruthy(fn_result)) {
                    return .{ .ok = item };
                }
            }

            for (table.hash_order.items) |key| {
                if (table.getRaw(key)) |val| {
                    const fn_result = try vm.callFunction(fn_data, &[_]Data{val});
                    if (isTruthy(fn_result)) {
                        return .{ .ok = val };
                    }
                }
            }
        },
        else => return .errType(0, "string, tuple, or table", dataToString(args[0])),
    }

    return .{ .ok = revo.core_atoms.data(.missing) };
}

/// > all?(collection: string|tuple|table, fn: function) -> boolean
/// returns true if function returns true for all elements
///     all?((1,2,3), fn(x) = x > 0)
///     all?("hello", fn(c) = c != " ")
///     all?({a=1, b=2}, fn(v) = v > 0)
pub fn all_fn(args: []const Data, vm: *VM) !NativeResult {
    if (args.len < 2) return .errArity(args.len, 2);

    const fn_data = args[1];
    if (!fn_data.isFunction()) return .errType(1, "function", dataToString(fn_data));

    switch (args[0].tag()) {
        .string => {
            const str = vm.stringValue(args[0].asString().?);
            for (str) |byte| {
                const char_str = try vm.ownDataString(&[_]u8{byte});
                const fn_result = try vm.callFunction(fn_data, &[_]Data{char_str});
                if (!isTruthy(fn_result)) {
                    return .{ .ok = Data.new.boolean(false) };
                }
            }
        },
        .tuple => {
            const t_id = args[0].asTuple().?;
            const tuple = try vm.tuples.get(t_id);
            for (tuple.items) |item| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{item});
                if (!isTruthy(fn_result)) {
                    return .{ .ok = Data.new.boolean(false) };
                }
            }
        },
        .table => {
            const table_id = args[0].asTable().?;
            const table = try vm.tables.get(table_id);

            for (table.array.items) |item| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{item});
                if (!isTruthy(fn_result)) {
                    return .{ .ok = Data.new.boolean(false) };
                }
            }

            for (table.hash_order.items) |key| {
                if (table.getRaw(key)) |val| {
                    const fn_result = try vm.callFunction(fn_data, &[_]Data{val});
                    if (!isTruthy(fn_result)) {
                        return .{ .ok = Data.new.boolean(false) };
                    }
                }
            }
        },
        else => return .errType(0, "string, tuple, or table", dataToString(args[0])),
    }

    return .{ .ok = Data.new.boolean(true) };
}

/// > any?(collection: string|tuple|table, fn: function) -> boolean
/// returns true if function returns true for any element
///     any?((1,2,3), fn(x) = x > 2)
///     any?("hello", fn(c) = c == "l")
///     any?({a=1, b=2}, fn(v) = v > 1)
pub fn any_fn(args: []const Data, vm: *VM) !NativeResult {
    if (args.len < 2) return .errArity(args.len, 2);

    const fn_data = args[1];
    if (!fn_data.isFunction()) return .errType(1, "function", dataToString(fn_data));

    switch (args[0].tag()) {
        .string => {
            const str = vm.stringValue(args[0].asString().?);
            for (str) |byte| {
                const char_str = try vm.ownDataString(&[_]u8{byte});
                const fn_result = try vm.callFunction(fn_data, &[_]Data{char_str});
                if (isTruthy(fn_result)) {
                    return .{ .ok = Data.new.boolean(true) };
                }
            }
        },
        .tuple => {
            const t_id = args[0].asTuple().?;
            const tuple = try vm.tuples.get(t_id);
            for (tuple.items) |item| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{item});
                if (isTruthy(fn_result)) {
                    return .{ .ok = Data.new.boolean(true) };
                }
            }
        },
        .table => {
            const table_id = args[0].asTable().?;
            const table = try vm.tables.get(table_id);

            for (table.array.items) |item| {
                const fn_result = try vm.callFunction(fn_data, &[_]Data{item});
                if (isTruthy(fn_result)) {
                    return .{ .ok = Data.new.boolean(true) };
                }
            }

            for (table.hash_order.items) |key| {
                if (table.getRaw(key)) |val| {
                    const fn_result = try vm.callFunction(fn_data, &[_]Data{val});
                    if (isTruthy(fn_result)) {
                        return .{ .ok = Data.new.boolean(true) };
                    }
                }
            }
        },
        else => return .errType(0, "string, tuple, or table", dataToString(args[0])),
    }

    return .{ .ok = Data.new.boolean(false) };
}

/// TODO: maybe dont do that
inline fn isTruthy(data: Data) bool {
    return !revo.isFalse(data);
}

const std = @import("std");

const revo = @import("../root.zig");
const Data = revo.Data;
const VM = revo.VM;
const api = @import("api.zig");
const root = @import("root.zig");
const NativeResult = root.NativeResult;
const dataToString = root.dataToString;
