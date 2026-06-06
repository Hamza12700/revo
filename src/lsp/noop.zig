// this is the entrypoint for when you don't have an lsp built
const std = @import("std");

pub fn runLsp(gpa: std.mem.Allocator, io: std.Io) !void {
    _ = gpa;
    _ = io;
    std.debug.print("lsp not available (build without -Dnolsp)\n", .{});
    std.process.exit(1);
}
