//
// exports for embedding revo from c
//
const std = @import("std");
const revo = @import("revo");

pub const ErevoVM = opaque {};
pub const ErevoProgram = opaque {};

pub const ErevoType = enum(u64) {
    number = 0,
    string,
    atom,
    function,
    table,
    tuple,
};

pub const ErevoData = extern struct {
    tag: u64,
    value: u64,
};

const VM = struct {
    alloc: std.mem.Allocator,
    io: std.Io.Threaded,
    last_error: ?[:0]u8 = null,
};

const Program = struct {
    alloc: std.mem.Allocator,
    name: [:0]u8,
    source: [:0]u8,
    artifact: revo.lang.Artifact,
};

fn wrappedVm(vm: ?*ErevoVM) ?*revo.VM {
    return if (vm) |p| @ptrCast(@alignCast(p)) else null;
}

fn vmOf(inner: *revo.VM) *VM {
    return @ptrCast(@alignCast(inner.c_data.?));
}

fn programOf(program: ?*ErevoProgram) ?*Program {
    return if (program) |p| @ptrCast(@alignCast(p)) else null;
}

fn clearError(vm: *VM) void {
    if (vm.last_error) |msg| vm.alloc.free(msg);
    vm.last_error = null;
}

fn setError(vm: *VM, message: []const u8) void {
    clearError(vm);
    // SAFETY: c api, null means no error
    vm.last_error = vm.alloc.dupeZ(u8, message) catch null;
}

fn setErrorFmt(vm: *VM, comptime fmt: []const u8, args: anytype) void {
    const message = std.fmt.allocPrint(vm.alloc, fmt, args) catch return;
    defer vm.alloc.free(message);
    setError(vm, message);
}

fn makeVm(alloc: std.mem.Allocator) !*revo.VM {
    var io = std.Io.Threaded.init(alloc, .{});
    errdefer io.deinit();

    var runtime = try revo.Runtime.init(alloc, io.io(), &.{});
    errdefer runtime.deinit();

    const inner = runtime.vm orelse return error.NoVm;
    const wrap = try alloc.create(VM);
    errdefer alloc.destroy(wrap);

    wrap.* = .{
        .alloc = alloc,
        .io = io,
    };
    inner.c_data = @ptrCast(wrap);
    return inner;
}

fn freeProgram(program: *Program) void {
    program.alloc.free(program.artifact.instructions);
    program.alloc.free(program.artifact.spans);
    program.alloc.free(program.name);
    program.alloc.free(program.source);
    program.alloc.destroy(program);
}

fn makeProgram(vm: *VM, name: []const u8, source: []const u8, artifact: revo.lang.Artifact) !*Program {
    const program = try vm.alloc.create(Program);
    errdefer vm.alloc.destroy(program);

    const name_z = try vm.alloc.dupeZ(u8, name);
    errdefer vm.alloc.free(name_z);

    const source_z = try vm.alloc.dupeZ(u8, source);
    errdefer vm.alloc.free(source_z);

    program.* = .{
        .alloc = vm.alloc,
        .name = name_z,
        .source = source_z,
        .artifact = artifact,
    };
    return program;
}

fn compileProgram(inner: *revo.VM, name: []const u8, source: []const u8) ?*Program {
    const self = vmOf(inner);
    clearError(self);

    const result = revo.lang.build(inner, .{ .name = name, .text = source }, .{}) catch |err| {
        setErrorFmt(self, "{}", .{err});
        return null;
    };

    return switch (result) {
        .ok => |artifact| makeProgram(self, name, source, artifact) catch |err| {
            setErrorFmt(self, "{}", .{err});
            return null;
        },
        .err => |failure| blk: {
            var buf = std.Io.Writer.Allocating.init(self.alloc);
            defer buf.deinit();
            revo.lang.renderError(self.alloc, &buf.writer, .{ .name = name, .text = source }, failure) catch {
                setError(self, "compile error");
                inner.runtime.resetDiagArena();
                break :blk null;
            };
            setError(self, buf.written());
            inner.runtime.resetDiagArena();
            break :blk null;
        },
    };
}

fn runProgram(inner: *revo.VM, program: *Program, out_value: ?*ErevoData) bool {
    const self = vmOf(inner);
    clearError(self);

    inner.setProgramDebugInfo(program.artifact.spans, program.source, program.name) catch |err| {
        setErrorFmt(self, "{}", .{err});
        return false;
    };

    const result = revo.module.runCompiledModuleReport(inner, program.name, program.artifact.instructions) catch |err| {
        setErrorFmt(self, "{}", .{err});
        return false;
    };

    return switch (result) {
        .ok => blk: {
            if (out_value) |out| {
                const cr = inner.currentResult();
                const tag = @intFromEnum(cr.tag());
                const value = if (cr.asNum()) |n|
                    @as(u64, @bitCast(n))
                else if (cr.asString()) |v|
                    @as(u64, @intCast(v))
                else if (cr.asAtom()) |v|
                    @as(u64, @intCast(v))
                else if (cr.asFunction()) |v|
                    @as(u64, @intCast(v))
                else if (cr.asTable()) |v|
                    @as(u64, @intCast(v))
                else
                    @as(u64, @intCast(cr.asTuple().?));
                out.* = .{ .tag = tag, .value = value };
            }
            break :blk true;
        },
        .err => |failure| blk: {
            var buf = std.Io.Writer.Allocating.init(self.alloc);
            defer buf.deinit();
            failure.render(self.alloc, &buf.writer, program.source) catch {
                setError(self, "runtime error");
                inner.runtime.resetDiagArena();
                break :blk false;
            };
            setError(self, buf.written());
            inner.runtime.resetDiagArena();
            break :blk false;
        },
    };
}

pub export fn erevo_vm_create() callconv(.c) ?*ErevoVM {
    return @ptrCast(makeVm(std.heap.page_allocator) catch return null);
}

pub export fn erevo_vm_destroy(vm: ?*ErevoVM) callconv(.c) void {
    const inner = wrappedVm(vm) orelse return;
    const self = vmOf(inner);
    clearError(self);
    self.io.deinit();
    inner.runtime.deinit();
    self.alloc.destroy(self);
}

pub export fn erevo_vm_last_error(vm: ?*ErevoVM) callconv(.c) [*:0]const u8 {
    const inner = wrappedVm(vm) orelse return "";
    const self = vmOf(inner);
    return if (self.last_error) |msg| msg.ptr else "";
}

pub export fn erevo_compile(vm: ?*ErevoVM, name: [*:0]const u8, source: [*:0]const u8) callconv(.c) ?*ErevoProgram {
    const inner = wrappedVm(vm) orelse return null;
    const name_slice = std.mem.span(name);
    const source_slice = std.mem.span(source);
    return @ptrCast(compileProgram(inner, name_slice, source_slice) orelse return null);
}

pub export fn erevo_program_destroy(program: ?*ErevoProgram) callconv(.c) void {
    const self = programOf(program) orelse return;
    freeProgram(self);
}

pub export fn erevo_run(vm: ?*ErevoVM, program: ?*ErevoProgram, out_value: ?*ErevoData) callconv(.c) bool {
    const inner = wrappedVm(vm) orelse return false;
    const compiled = programOf(program) orelse return false;
    return runProgram(inner, compiled, out_value);
}

pub export fn erevo_eval(vm: ?*ErevoVM, name: [*:0]const u8, source: [*:0]const u8, out_value: ?*ErevoData) callconv(.c) bool {
    const inner = wrappedVm(vm) orelse return false;
    const name_slice = std.mem.span(name);
    const source_slice = std.mem.span(source);
    const program = compileProgram(inner, name_slice, source_slice) orelse return false;
    defer freeProgram(program);
    return runProgram(inner, program, out_value);
}
