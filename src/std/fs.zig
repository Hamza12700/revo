const std = @import("std");
const builtin = @import("builtin");
const revo = @import("../root.zig");
const root = @import("root.zig");
const meta = @import("meta.zig");

const Data = revo.Data;
const VM = revo.VM;
const NativeResult = root.NativeResult;
const Dir = std.Io.Dir;
const File = std.Io.File;

const path_key = "__path";
// 1gb
const max_read_size = 1024 * 1024 * 1024;
const PermTag = @typeInfo(File.Permissions).@"enum".tag_type;

const FileHandle = struct {
    path: []const u8,
};

pub fn register(vm: *VM) !void {
    try root.registerTableFunctions(vm, "fs", &[_]root.FuncDef{
        .{ .name = "open", .f = root.define(&.{.string}, open_fn) },
        .{ .name = "readdir", .f = root.define(&.{.string}, readdir_fn) },
        .{ .name = "exists?", .f = root.define(&.{.string}, exists_fn) },
        .{ .name = "remove", .f = root.define(&.{.string}, remove_fn) },
        .{ .name = "mkdir", .f = root.defineVariadic(&.{.string}, mkdir_fn) },
        .{ .name = "rename", .f = root.define(&.{ .string, .string }, rename_fn) },
    });
    try root.registerTableFunctions(vm, "file", &[_]root.FuncDef{
        .{ .name = "read", .f = root.define(&.{.any}, read_fn) },
        .{ .name = "write", .f = root.defineVariadic(&.{ .any, .any }, write_fn) },
        .{ .name = "append", .f = root.defineVariadic(&.{ .any, .any }, append_fn) },
        .{ .name = "stat", .f = root.define(&.{.any}, stat_fn) },
        .{ .name = "close", .f = root.define(&.{.any}, close_fn) },
    });
}

fn wrapFile(vm: *VM, path: []const u8) !Data {
    const file_table = try vm.tables.create();
    var table = try vm.tables.get(file_table);
    try table.putRaw(try vm.dataAtom(path_key), try vm.ownDataString(path));

    const metatable = try vm.tables.create();
    var mt = try vm.tables.get(metatable);
    const file_module = vm.globals.get(try vm.internAtom("file")) orelse return error.FileModuleNotFound;
    try mt.putRaw(try vm.dataAtom("__index"), file_module);

    const set_result = try meta.set_metatable_(&.{ Data{ .table = file_table }, Data{ .table = metatable } }, vm);
    if (set_result != .ok) return error.SetMetatableFailed;
    return Data{ .table = file_table };
}

fn parseFileHandle(value: Data, vm: *VM) !FileHandle {
    if (value != .table) return error.InvalidFile;
    const table = try vm.tables.get(value.table);

    const path_data = table.getRaw(try vm.dataAtom(path_key)) orelse return error.InvalidFile;

    return .{
        .path = switch (path_data) {
            .string => |id| vm.stringValue(id),
            else => return error.InvalidFile,
        },
    };
}

fn kindName(kind: File.Kind) []const u8 {
    return switch (kind) {
        .file => "file",
        .directory => "directory",
        .sym_link => "symlink",
        else => "unknown",
    };
}

fn parsePermissions(vm: *VM, value: Data) !File.Permissions {
    switch (value) {
        .number => |n| {
            if (!std.math.isFinite(n) or @floor(n) != n) return error.InvalidPermissions;
            const raw: PermTag = @as(PermTag, @intFromFloat(n));
            return @as(File.Permissions, @enumFromInt(raw));
        },
        .atom => |id| {
            const name = vm.atomName(id);
            inline for (@typeInfo(File.Permissions).@"enum".fields) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    return @as(File.Permissions, @enumFromInt(field.value));
                }
            }
            return error.InvalidPermissions;
        },
        else => return error.InvalidPermissions,
    }
}

fn makeStatTable(vm: *VM, stat: File.Stat) !Data {
    const table = try vm.tables.create();
    var t = try vm.tables.get(table);

    try t.putRaw(try vm.dataAtom("size"), Data.new.num(stat.size));
    try t.putRaw(try vm.dataAtom("kind"), try vm.ownDataString(@tagName(stat.kind)));
    try t.putRaw(try vm.dataAtom("permissions"), Data.new.num(@intFromEnum(stat.permissions)));
    try t.putRaw(try vm.dataAtom("mtime"), Data.new.num(stat.mtime.toSeconds()));
    try t.putRaw(try vm.dataAtom("atime"), Data.new.num((stat.atime orelse stat.mtime).toSeconds()));
    try t.putRaw(try vm.dataAtom("ctime"), Data.new.num(stat.ctime.toSeconds()));

    return Data{ .table = table };
}

fn mapIOError(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "NotFound",
        error.AccessDenied => "PermissionDenied",
        error.PermissionDenied => "PermissionDenied",
        error.IsDir => "IsDirectory",
        error.NotDir => "NotDirectory",
        error.PathAlreadyExists => "AlreadyExists",
        error.ReadOnlyFileSystem => "ReadOnlyFileSystem",
        error.NoSpaceLeft => "NoSpaceLeft",
        error.FileBusy => "FileBusy",
        error.DeviceBusy => "DeviceBusy",
        error.WouldBlock => "WouldBlock",
        error.Unexpected => "IoError",
        else => "UnknownError",
    };
}

/// > fs.open(path: string) -> !table
/// wraps a path in a file handle table
/// use `file.close()` when you're done with the handle
fn open_fn(args: []const Data, vm: *VM) !NativeResult {
    const path = vm.stringValue(args[0].string);
    return try NativeResult.Ok(vm, try wrapFile(vm, path));
}

/// > file:read() -> !string
/// reads the full file contents as a string
fn read_fn(args: []const Data, vm: *VM) !NativeResult {
    const handle = parseFileHandle(args[0], vm) catch return try NativeResult.Err(vm, "InvalidFile");

    const stat = Dir.cwd().statFile(vm.runtime.io, handle.path, .{}) catch return try NativeResult.Err(vm, "StatError");
    if (stat.size > max_read_size) return try NativeResult.Err(vm, "FileTooLarge");

    const data = Dir.cwd().readFileAlloc(
        vm.runtime.io,
        handle.path,
        vm.runtime.alloc,
        .limited(max_read_size),
    ) catch |err| {
        return try NativeResult.Err(vm, mapIOError(err));
    };
    return try NativeResult.Ok(vm, try vm.adoptDataString(data));
}

/// > file:write(data: any, ?permissions: atom|number) -> !number
/// overwrites the file with the provided string
/// optional permissions default to the platform file default
fn write_fn(args: []const Data, vm: *VM) !NativeResult {
    const handle = parseFileHandle(args[0], vm) catch return try NativeResult.Err(vm, "InvalidFile");
    if (args[1] != .string) return try NativeResult.Err(vm, "InvalidArguments");
    const permissions = if (args.len > 2) parsePermissions(vm, args[2]) catch return try NativeResult.Err(vm, "InvalidPermissions") else .default_file;

    const data = vm.stringValue(args[1].string);
    Dir.cwd().writeFile(vm.runtime.io, .{
        .sub_path = handle.path,
        .data = data,
        .flags = .{ .permissions = permissions },
    }) catch |err| {
        return try NativeResult.Err(vm, mapIOError(err));
    };

    return try NativeResult.Ok(vm, Data.new.num(data.len));
}

/// > file:append(data: any, ?permissions: atom|number) -> !number
/// appends data to the file, creating it if needed
/// optional permissions default to the platform file default
fn append_fn(args: []const Data, vm: *VM) !NativeResult {
    const handle = parseFileHandle(args[0], vm) catch return try NativeResult.Err(vm, "InvalidFile");
    if (args[1] != .string) return try NativeResult.Err(vm, "InvalidArguments");
    const permissions = if (args.len > 2) parsePermissions(vm, args[2]) catch return try NativeResult.Err(vm, "InvalidPermissions") else .default_file;

    const data = vm.stringValue(args[1].string);
    const file = Dir.cwd().createFile(vm.runtime.io, handle.path, .{
        .truncate = false,
        .permissions = permissions,
    }) catch |err| {
        return try NativeResult.Err(vm, mapIOError(err));
    };

    const stat = file.stat(vm.runtime.io) catch |err| {
        return try NativeResult.Err(vm, mapIOError(err));
    };
    try file.writePositionalAll(vm.runtime.io, data, stat.size);

    return try NativeResult.Ok(vm, Data.new.num(data.len));
}

/// > file:stat() -> !table
/// get file metadata as a table
fn stat_fn(args: []const Data, vm: *VM) !NativeResult {
    const handle = parseFileHandle(args[0], vm) catch return try NativeResult.Err(vm, "InvalidFile");
    const stat = Dir.cwd().statFile(vm.runtime.io, handle.path, .{}) catch |err| {
        return try NativeResult.Err(vm, mapIOError(err));
    };
    return try NativeResult.Ok(vm, try makeStatTable(vm, stat));
}

/// > file:close() -> !atom
/// closes a file handle table
/// this is currently a logical close for wrapper handles
fn close_fn(args: []const Data, vm: *VM) !NativeResult {
    _ = parseFileHandle(args[0], vm) catch return try NativeResult.Err(vm, "InvalidFile");
    return try NativeResult.Ok(vm, revo.core_atoms.data(.ok));
}

/// > fs.exists?(path: string) -> !atom
/// does path exist?
fn exists_fn(args: []const Data, vm: *VM) !NativeResult {
    const path = vm.stringValue(args[0].string);
    const file = if (std.fs.path.isAbsolute(path))
        Dir.openFileAbsolute(vm.runtime.io, path, .{
            .allow_directory = true,
            .path_only = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return try NativeResult.Ok(vm, revo.core_atoms.data(.false)),
            else => return try NativeResult.Err(vm, mapIOError(err)),
        }
    else
        Dir.cwd().openFile(vm.runtime.io, path, .{
            .allow_directory = true,
            .path_only = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return try NativeResult.Ok(vm, revo.core_atoms.data(.false)),
            else => return try NativeResult.Err(vm, mapIOError(err)),
        };
    defer file.close(vm.runtime.io);
    return try NativeResult.Ok(vm, revo.core_atoms.data(.true));
}

/// > fs.mkdir(path: string, ?permissions: atom|number) -> !atom
/// creates a directory, using default permissions when omitted
fn mkdir_fn(args: []const Data, vm: *VM) !NativeResult {
    const path = vm.stringValue(args[0].string);
    const permissions: File.Permissions = if (args.len > 1)
        parsePermissions(vm, args[1]) catch return try NativeResult.Err(vm, "InvalidPermissions")
    else if (builtin.target.os.tag == .windows)
        // windows doesn't have a sepaarte directory perm
        @as(File.Permissions, @enumFromInt(0))
    else
        .default_dir;

    Dir.cwd().createDir(vm.runtime.io, path, permissions) catch |err| {
        return try NativeResult.Err(vm, mapIOError(err));
    };
    return try NativeResult.Ok(vm, revo.core_atoms.data(.ok));
}

/// > fs.remove(path: string) -> !atom
/// removes a file or empty directory at path
fn remove_fn(args: []const Data, vm: *VM) !NativeResult {
    const path = vm.stringValue(args[0].string);
    Dir.cwd().deleteFile(vm.runtime.io, path) catch |file_err| switch (file_err) {
        error.IsDir => {
            Dir.cwd().deleteDir(vm.runtime.io, path) catch |err| {
                return try NativeResult.Err(vm, mapIOError(err));
            };
            return try NativeResult.Ok(vm, revo.core_atoms.data(.ok));
        },
        error.FileNotFound => return try NativeResult.Err(vm, "NotFound"),
        else => return try NativeResult.Err(vm, mapIOError(file_err)),
    };
    return try NativeResult.Ok(vm, revo.core_atoms.data(.ok));
}

/// > fs.readdir(path: string) -> !table
/// ret: table of directory entries
fn readdir_fn(args: []const Data, vm: *VM) !NativeResult {
    const path = vm.stringValue(args[0].string);

    const open_dir = Dir.cwd().openDir(vm.runtime.io, path, .{}) catch |err| {
        return try NativeResult.Err(vm, mapIOError(err));
    };
    defer open_dir.close(vm.runtime.io);
    var iter = open_dir.iterate();

    var entries = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, 16);
    defer entries.deinit(vm.runtime.alloc);

    while (try iter.next(vm.runtime.io)) |ent| {
        const entry_table = try vm.tables.create();
        var t = try vm.tables.get(entry_table);
        try t.putRaw(try vm.dataAtom("name"), try vm.ownDataString(ent.name));
        try t.putRaw(try vm.dataAtom("kind"), try vm.ownDataString(kindName(ent.kind)));
        try entries.append(vm.runtime.alloc, Data{ .table = entry_table });
    }

    const result_table = try vm.tables.create();
    var t = try vm.tables.get(result_table);
    for (entries.items, 1..) |entry, i| {
        try t.putRaw(Data.new.num(i), entry);
    }

    return try NativeResult.Ok(vm, Data{ .table = result_table });
}

/// > fs.rename(old_path: string, new_path: string) -> !atom
/// renames a file or directory
fn rename_fn(args: []const Data, vm: *VM) !NativeResult {
    const old_path = vm.stringValue(args[0].string);
    const new_path = vm.stringValue(args[1].string);
    Dir.cwd().rename(old_path, Dir.cwd(), new_path, vm.runtime.io) catch |err| {
        return try NativeResult.Err(vm, mapIOError(err));
    };
    return try NativeResult.Ok(vm, revo.core_atoms.data(.ok));
}

const testing = revo.lang.testing;
const io = std.testing.io;
const alloc = std.testing.allocator;

fn sourceForPath(comptime template: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, template, .{path});
}

test "fs.open/read reads file contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello from fs" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const file_path = try std.fs.path.join(alloc, &.{ dir_path, "a.txt" });
    defer alloc.free(file_path);

    const source = try sourceForPath(
        \\ fs.open("{s}"):unwrap():read():unwrap()
    , file_path);
    defer alloc.free(source);

    try testing.top_string(source, "hello from fs");
}

test "fs.write overwrites file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "w.txt", .data = "old" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const file_path = try std.fs.path.join(alloc, &.{ dir_path, "w.txt" });
    defer alloc.free(file_path);

    const source = try sourceForPath(
        \\ const f = fs.open("{s}"):unwrap()
        \\ f:write("new value"):unwrap()
        \\ f:read():unwrap()
    , file_path);
    defer alloc.free(source);

    try testing.top_string(source, "new value");
}

test "fs.append appends to file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "app.txt", .data = "hello" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const file_path = try std.fs.path.join(alloc, &.{ dir_path, "app.txt" });
    defer alloc.free(file_path);

    const source = try sourceForPath(
        \\ const f = fs.open("{s}"):unwrap()
        \\ f:append(" world"):unwrap()
        \\ f:read():unwrap()
    , file_path);
    defer alloc.free(source);

    try testing.top_string(source, "hello world");
}

test "fs.append creates missing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const file_path = try std.fs.path.join(alloc, &.{ dir_path, "new.txt" });
    defer alloc.free(file_path);

    const source = try sourceForPath(
        \\ const f = fs.open("{s}"):unwrap()
        \\ f:append("created"):unwrap()
        \\ f:read():unwrap()
    , file_path);
    defer alloc.free(source);

    try testing.top_string(source, "created");
}

test "fs.readdir returns table of entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "b" });

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);

    const source = try sourceForPath(
        \\ type(fs.readdir("{s}"):unwrap()) == :table
    , dir_path);
    defer alloc.free(source);
    try testing.top_true(source);
}
