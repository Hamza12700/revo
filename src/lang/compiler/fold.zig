const std = @import("std");

const revo = @import("revo");
const Compiler = revo.lang.compiler.Compiler;
const Data = revo.Data;

const ast = @import("../ast.zig");
const Expr = ast.Expr;
const emit = @import("emit.zig");

pub fn maybeFoldConstBinary(self: *Compiler, b: anytype) !bool {
    const left: Expr = b.left.expr;
    const right: Expr = b.right.expr;

    if (left == .number and right == .number) {
        const lhs = left.number;
        const rhs = right.number;

        const maybe_fold = fops.getFoldFn(b.op);
        if (maybe_fold == null) return false;

        const result = maybe_fold.?(lhs, rhs) orelse return false;

        if (!std.math.isFinite(result)) return false;
        if (@floor(result) != result) return false;
        if (result < @as(f64, @floatFromInt(std.math.minInt(i64))) or
            result > @as(f64, @floatFromInt(std.math.maxInt(i64))))
            return false;

        try emit.@"const"(self, Data.new.num(@as(i64, @intFromFloat(result))));
        return true;
    } else if (left == .string and right == .string) {
        if (b.op != .add) return false;

        const result = try std.mem.concat(self.alloc, u8, &[2][]const u8{ left.string, right.string });
        defer self.alloc.free(result);
        const data = try self.vm.ownDataString(result);
        try emit.@"const"(self, data);
        return true;
    }
    return false;
}

const fops = struct {
    const FoldFn = *const fn (f64, f64) ?f64;

    pub fn add(lhs: f64, rhs: f64) ?f64 {
        return lhs + rhs;
    }

    pub fn sub(lhs: f64, rhs: f64) ?f64 {
        return lhs - rhs;
    }

    pub fn mul(lhs: f64, rhs: f64) ?f64 {
        return lhs * rhs;
    }

    pub fn div(lhs: f64, rhs: f64) ?f64 {
        if (rhs == 0) return null;
        return lhs / rhs;
    }

    pub fn mod_op(lhs: f64, rhs: f64) ?f64 {
        if (rhs == 0) return null;
        return @mod(lhs, rhs);
    }

    pub const fold_table = blk: {
        var table = std.EnumArray(ast.BinOp, ?FoldFn).initFill(null);

        const info = @typeInfo(@This()).@"struct";
        for (info.fields) |field| {
            if (field.type == FoldFn) {
                const tag_name = if (std.mem.eql(u8, field.name, "mod.emit")) "mod" else field.name;

                for (std.enums.values(ast.BinOp)) |tag|
                    if (std.mem.eql(u8, @tagName(tag), tag_name)) {
                        table.set(tag, @field(@This(), field.name));
                        break;
                    };
            }
        }
        break :blk table;
    };

    pub fn getFoldFn(op: ast.BinOp) ?FoldFn {
        return fold_table.get(op);
    }
};
