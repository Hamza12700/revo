const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");
const meta = @import("meta.zig");
const Scheduler = revo.vm.Scheduler;

const Data = revo.Data;
const VM = revo.VM;
const NativeResult = root.NativeResult;

pub const SocketEntry = union(enum) {
    stream: StreamEntry,
    server: std.Io.net.Server,
};

pub const StreamEntry = struct {
    socket: std.Io.net.Stream,
    pending: []u8 = &.{},
};

const RecvMode = enum {
    read_some,
    read_all,
    read_line,
};

const SendWaitToken = struct {
    message: VM.memory.StringID,
    offset: usize = 0,
};

const RecvWaitToken = struct {
    entry_ptr: ?*SocketEntry = null,
    mode: RecvMode = .read_some,
    max_bytes: usize = 4096,
    delimiter: u8 = '\n',
};

fn setSocketNonBlocking(handle: std.posix.fd_t) !void {
    const flags = std.c.fcntl(handle, std.posix.F.GETFL, @as(c_int, 0));
    if (flags == -1) return error.Unexpected;
    const new_flags: c_int = flags | @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true }));
    const rc = std.c.fcntl(handle, std.posix.F.SETFL, new_flags);
    if (rc == -1) return error.Unexpected;
}

// wake a fiber with a (tag, payload) tuple
fn wakeFiber(vm: *VM, fiber_id: VM.FiberID, tag: revo.core_atoms, payload: Data) !void {
    const items = [_]Data{
        .{ .atom = @intFromEnum(tag) },
        payload,
    };
    try vm.sched.wakeFiber(
        vm.runtime.alloc,
        fiber_id,
        Data.new.tuple(try vm.tuples.create(&items)),
    );
}

fn appendPending(alloc: std.mem.Allocator, stream: *StreamEntry, chunk: []const u8) !void {
    if (chunk.len == 0) return;
    if (stream.pending.len == 0) {
        stream.pending = try alloc.dupe(u8, chunk);
        return;
    }
    const merged = try std.mem.concat(alloc, u8, &[_][]const u8{ stream.pending, chunk });
    if (stream.pending.len > 0) alloc.free(stream.pending);
    stream.pending = merged;
}

fn tryExtractPendingDelimited(vm: *VM, stream: *StreamEntry, delimiter: u8) !?Data {
    const idx = std.mem.indexOfScalar(u8, stream.pending, delimiter) orelse return null;
    const line = try vm.ownDataString(stream.pending[0..idx]);
    const rest = stream.pending[idx + 1 ..];
    if (rest.len > 0) {
        const new_pending = try vm.runtime.alloc.dupe(u8, rest);
        if (stream.pending.len > 0) vm.runtime.alloc.free(stream.pending);
        stream.pending = new_pending;
    } else {
        if (stream.pending.len > 0) vm.runtime.alloc.free(stream.pending);
        stream.pending = &.{};
    }
    return line;
}

fn deinitToken(comptime T: type, alloc: std.mem.Allocator, token: usize) void {
    if (token == 0) return;
    alloc.destroy(@as(*T, @ptrFromInt(token)));
}

fn completeWaiter(vm: *VM, waiter: *Scheduler.WaitEntry, tag: revo.core_atoms, payload: Data) !Scheduler.IoDispatchResult {
    try wakeFiber(vm, waiter.fiber_id, tag, payload);
    return .{ .completed = true, .woke = true };
}

fn deinitSendToken(alloc: std.mem.Allocator, token: usize) void {
    deinitToken(SendWaitToken, alloc, token);
}

fn deinitRecvToken(alloc: std.mem.Allocator, token: usize) void {
    deinitToken(RecvWaitToken, alloc, token);
}

fn onSendReady(vm: *VM, waiter: *Scheduler.WaitEntry, _: i16) !Scheduler.IoDispatchResult {
    const t = @as(*SendWaitToken, @ptrFromInt(waiter.token));
    const msg = vm.stringValue(t.message);
    const remaining = msg[t.offset..];
    const flags: u32 = std.posix.MSG.DONTWAIT | std.posix.MSG.NOSIGNAL;
    const rc = std.c.send(@as(std.posix.fd_t, @intCast(waiter.wait_id)), remaining.ptr, remaining.len, flags);
    switch (std.posix.errno(rc)) {
        .AGAIN => return .{},
        .SUCCESS => {},
        else => |err| {
            deinitToken(SendWaitToken, vm.runtime.alloc, waiter.token);
            waiter.token = 0;
            return try completeWaiter(vm, waiter, .err, try vm.dataAtom(@tagName(err)));
        },
    }
    const sent: usize = @intCast(rc);
    const next_offset = t.offset + sent;
    if (next_offset >= msg.len) {
        deinitToken(SendWaitToken, vm.runtime.alloc, waiter.token);
        waiter.token = 0;
        return try completeWaiter(vm, waiter, .ok, Data.new.num(msg.len));
    }
    t.offset = next_offset;
    return .{};
}

fn freePending(alloc: std.mem.Allocator, pending: *[]u8) void {
    if (pending.len > 0) alloc.free(pending.*);
    pending.* = &.{};
}

fn onRecvReady(vm: *VM, waiter: *Scheduler.WaitEntry, _: i16) !Scheduler.IoDispatchResult {
    const t = @as(*RecvWaitToken, @ptrFromInt(waiter.token));
    const entry_ptr = t.entry_ptr orelse return .{ .completed = true, .woke = false };
    const stream = switch (entry_ptr.*) {
        .stream => |*s| s,
        .server => {
            deinitToken(RecvWaitToken, vm.runtime.alloc, waiter.token);
            waiter.token = 0;
            return try completeWaiter(vm, waiter, .err, revo.core_atoms.data(.CannotRecvOnServer));
        },
    };

    switch (t.mode) {
        .read_some => {
            if (stream.pending.len > 0) {
                const take = @min(t.max_bytes, stream.pending.len);
                const payload = try vm.ownDataString(stream.pending[0..take]);
                if (take < stream.pending.len) {
                    const rest = try vm.runtime.alloc.dupe(u8, stream.pending[take..]);
                    freePending(vm.runtime.alloc, &stream.pending);
                    stream.pending = rest;
                } else {
                    freePending(vm.runtime.alloc, &stream.pending);
                }
                deinitToken(RecvWaitToken, vm.runtime.alloc, waiter.token);
                waiter.token = 0;
                return try completeWaiter(vm, waiter, .ok, payload);
            }
        },
        .read_line => {
            if (try tryExtractPendingDelimited(vm, stream, t.delimiter)) |line| {
                deinitToken(RecvWaitToken, vm.runtime.alloc, waiter.token);
                waiter.token = 0;
                return try completeWaiter(vm, waiter, .ok, line);
            }
        },
        .read_all => {},
    }

    const temp_buf = try vm.runtime.alloc.alloc(u8, t.max_bytes);
    defer vm.runtime.alloc.free(temp_buf);
    const flags: u32 = std.posix.MSG.DONTWAIT | std.posix.MSG.NOSIGNAL;
    const rc = std.c.recv(@as(std.posix.fd_t, @intCast(waiter.wait_id)), temp_buf.ptr, temp_buf.len, flags);
    switch (std.posix.errno(rc)) {
        .AGAIN => return .{},
        .SUCCESS => {},
        else => |err| {
            deinitToken(RecvWaitToken, vm.runtime.alloc, waiter.token);
            waiter.token = 0;
            return try completeWaiter(vm, waiter, .err, try vm.dataAtom(@tagName(err)));
        },
    }
    const n: usize = @intCast(rc);
    if (n == 0) {
        deinitToken(RecvWaitToken, vm.runtime.alloc, waiter.token);
        waiter.token = 0;
        if (stream.pending.len > 0) {
            const payload = try vm.ownDataString(stream.pending);
            freePending(vm.runtime.alloc, &stream.pending);
            return try completeWaiter(vm, waiter, .ok, payload);
        } else {
            return try completeWaiter(vm, waiter, .err, revo.core_atoms.data(.SocketClosed));
        }
    }

    switch (t.mode) {
        .read_some => {
            deinitToken(RecvWaitToken, vm.runtime.alloc, waiter.token);
            waiter.token = 0;
            return try completeWaiter(vm, waiter, .ok, try vm.ownDataString(temp_buf[0..n]));
        },
        .read_line => {
            try appendPending(vm.runtime.alloc, stream, temp_buf[0..n]);
            if (try tryExtractPendingDelimited(vm, stream, t.delimiter)) |line| {
                deinitToken(RecvWaitToken, vm.runtime.alloc, waiter.token);
                waiter.token = 0;
                return try completeWaiter(vm, waiter, .ok, line);
            }
            return .{};
        },
        .read_all => {
            try appendPending(vm.runtime.alloc, stream, temp_buf[0..n]);
            return .{};
        },
    }
}

fn onAcceptReady(vm: *VM, waiter: *Scheduler.WaitEntry, _: i16) !Scheduler.IoDispatchResult {
    const rc = std.c.accept(@as(std.posix.fd_t, @intCast(waiter.wait_id)), null, null);
    switch (std.posix.errno(rc)) {
        .AGAIN => return .{},
        .SUCCESS => {},
        else => |err| return try completeWaiter(vm, waiter, .err, try vm.dataAtom(@tagName(err))),
    }
    const handle: std.posix.fd_t = @intCast(rc);
    setSocketNonBlocking(handle) catch |err| {
        _ = std.c.close(handle);
        return try completeWaiter(vm, waiter, .err, try vm.dataAtom(@errorName(err)));
    };
    const new_entry_ptr = try vm.runtime.alloc.create(SocketEntry);
    new_entry_ptr.* = .{
        .stream = .{
            .socket = .{
                .socket = .{
                    .handle = handle,
                    .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } },
                },
            },
            .pending = &.{},
        },
    };
    return try completeWaiter(vm, waiter, .ok, try wrapSocket(vm, new_entry_ptr, false));
}

pub fn register(vm: *VM) !void {
    try root.registerTableFunctions(vm, "net", &[_]root.FuncDef{
        .{ .name = "connect", .f = root.define(&.{ .string, .number }, connect_fn) },
        .{ .name = "listen", .f = root.defineVariadic(&.{.number}, listen_fn) },
    });
    try root.registerTableFunctions(vm, "socket", &[_]root.FuncDef{
        .{ .name = "accept", .f = root.define(&.{.table}, accept_fn) },
        .{ .name = "send", .f = root.define(&.{ .table, .string }, send_fn) },
        .{ .name = "recv", .f = root.define(&.{ .table, .table }, recv) },
        .{ .name = "close", .f = root.define(&.{.table}, socket_close_fn) },
    });
}

// poll io waiters, poll and wake fibers
pub fn pollIoWaiters(vm: *VM, timeout_ms: i32) !bool {
    var poll_fds = try std.ArrayList(std.posix.pollfd).initCapacity(vm.runtime.alloc, 4);
    defer poll_fds.deinit(vm.runtime.alloc);

    var poll_to_waiter = try std.ArrayList(usize).initCapacity(vm.runtime.alloc, 4);
    defer poll_to_waiter.deinit(vm.runtime.alloc);

    var completed_waiters = try std.ArrayList(usize).initCapacity(vm.runtime.alloc, 4);
    defer completed_waiters.deinit(vm.runtime.alloc);

    for (vm.sched.io_waiters.items, 0..) |waiter, idx| {
        const events: i16 = switch (waiter.intent) {
            .read => std.posix.POLL.IN,
            .write => std.posix.POLL.OUT,
            .read_write => std.posix.POLL.IN | std.posix.POLL.OUT,
        };
        try poll_fds.append(vm.runtime.alloc, .{
            .fd = @as(std.posix.fd_t, @intCast(waiter.wait_id)),
            .events = events,
            .revents = 0,
        });
        try poll_to_waiter.append(vm.runtime.alloc, idx);
    }

    if (poll_fds.items.len == 0) return false;

    _ = try std.posix.poll(poll_fds.items, timeout_ms);

    var woke_any = false;
    var poll_idx = poll_fds.items.len;
    while (poll_idx > 0) {
        poll_idx -= 1;
        const pfd = poll_fds.items[poll_idx];
        if (pfd.revents == 0) continue;

        const waiter_idx = poll_to_waiter.items[poll_idx];
        if (waiter_idx >= vm.sched.io_waiters.items.len) continue;

        const waiter = &vm.sched.io_waiters.items[waiter_idx];
        if (waiter.fiber_id >= vm.sched.fibers.items.len) {
            try completed_waiters.append(vm.runtime.alloc, waiter_idx);
            continue;
        }

        const dispatch = try waiter.on_ready(vm, waiter, pfd.revents);
        if (dispatch.completed) try completed_waiters.append(vm.runtime.alloc, waiter_idx);
        woke_any = woke_any or dispatch.woke;
    }

    // remove completions after the poll pass so swapremove can't shift live indices
    while (completed_waiters.items.len > 0) {
        var best_pos: usize = 0;
        var best_waiter: usize = completed_waiters.items[0];
        for (completed_waiters.items[1..], 1..) |waiter_idx, pos| {
            if (waiter_idx > best_waiter) {
                best_waiter = waiter_idx;
                best_pos = pos;
            }
        }
        const removed = vm.sched.io_waiters.swapRemove(best_waiter);
        if (removed.on_deinit) |deinit_fn| deinit_fn(vm.runtime.alloc, removed.token);
        _ = completed_waiters.swapRemove(best_pos);
    }

    return woke_any;
}

// ret table wraps heap alloced SocketEntry gc probably doesnt nuke it
pub fn wrapSocket(vm: *VM, entry_ptr: *SocketEntry, is_server: bool) !Data {
    const sock_table = try vm.tables.create();
    var table = try vm.tables.get(sock_table);

    try table.putRaw(
        Data.new.atom(try vm.internAtom("__is_server")),
        Data.new.boolean(is_server),
    );

    try table.putRaw(
        Data.new.atom(try vm.internAtom("__entry_ptr")),
        Data.new.num(@intFromPtr(entry_ptr)),
    );

    if (is_server) {
        const port = switch (entry_ptr.*) {
            .server => |s| s.socket.address.getPort(),
            .stream => 0,
        };
        try table.putRaw(
            Data.new.atom(try vm.internAtom("port")),
            Data.new.num(port),
        );
    }

    // the socket module as mt __index so methods resolve
    const metatable = try vm.tables.create();
    var mt = try vm.tables.get(metatable);
    const socket_module_data = vm.globals.get(try vm.internAtom("socket")) orelse
        return error.SocketModuleNotFound;
    try mt.putRaw(
        Data.new.atom(try vm.internAtom("__index")),
        socket_module_data,
    );

    const mt_array = [_]Data{ Data{ .table = sock_table }, Data{ .table = metatable } };
    const set_result = try meta.set_metatable_(&mt_array, vm);
    if (set_result != .ok) return error.SetMetatableFailed;

    return Data{ .table = sock_table };
}

fn isServer(socket_data: Data, vm: *VM) !bool {
    const table = try vm.tables.get(socket_data.table);
    const d = table.getRaw(Data.new.atom(try vm.internAtom("__is_server"))) orelse
        return error.InvalidSocket;
    return !revo.isFalse(d);
}

/// ret always live ptr or SocketClosed
fn getEntryPtr(socket_data: Data, vm: *VM) !*SocketEntry {
    const table = try vm.tables.get(socket_data.table);
    const d = table.getRaw(Data.new.atom(try vm.internAtom("__entry_ptr"))) orelse
        return error.InvalidSocket;
    const addr = @as(usize, @intFromFloat(d.number));
    if (addr == 0) return error.SocketClosed;
    return @as(*SocketEntry, @ptrFromInt(addr));
}

/// poison the pointer slot and free the entry,,, idempotent
fn closeEntry(socket_data: Data, vm: *VM) !void {
    const entry_ptr = getEntryPtr(socket_data, vm) catch |e| switch (e) {
        error.SocketClosed => return,
        else => return e,
    };

    const io = vm.runtime.io;
    switch (entry_ptr.*) {
        .stream => |*s| {
            if (s.pending.len > 0) vm.runtime.alloc.free(s.pending);
            s.socket.close(io);
        },
        .server => |s| std.Io.net.Server.deinit(@constCast(&s), io),
    }
    vm.runtime.alloc.destroy(entry_ptr);

    // zeroise so double close is nop rather than use-after-free
    var tbl = try vm.tables.get(socket_data.table);
    try tbl.putRaw(
        Data.new.atom(try vm.internAtom("__entry_ptr")),
        Data.new.num(0),
    );
}

/// > net:connect(host: string, port: number) -> socket
/// connects to a remote host and port, returns a socket handle
fn connect_fn(args: []const Data, vm: *VM) !NativeResult {
    const host = vm.stringValue(args[0].string);
    const port: u16 = @as(u16, @intFromFloat(args[1].number));

    const host_to_use = if (std.mem.eql(u8, host, "localhost")) "127.0.0.1" else host;
    const addr = std.Io.net.IpAddress.parseIp4(host_to_use, port) catch |err| {
        return try root.resultTuple(vm, .err, try vm.dataAtom(@errorName(err)));
    };

    const stream = addr.connect(vm.runtime.io, .{
        .mode = std.Io.net.Socket.Mode.stream,
        .protocol = std.Io.net.Protocol.tcp,
    }) catch |err| {
        return try root.resultTuple(vm, .err, try vm.dataAtom(@errorName(err)));
    };
    setSocketNonBlocking(stream.socket.handle) catch |err| return try root.resultTuple(vm, .err, try vm.dataAtom(@errorName(err)));

    const entry_ptr = try vm.runtime.alloc.create(SocketEntry);
    entry_ptr.* = .{ .stream = .{ .socket = stream } };

    return try .Ok(vm, try wrapSocket(vm, entry_ptr, false));
}

/// > net:listen(port: number [, backlog: number]) -> socket
/// listens for incoming connections on the given port, returns server socket
fn listen_fn(args: []const Data, vm: *VM) !NativeResult {
    const port: u16 = @as(u16, @intFromFloat(args[0].number));
    const backlog: u31 = if (args.len > 1) @as(u31, @intFromFloat(args[1].number)) else 128;

    const addr = std.Io.net.IpAddress.parseIp4("0.0.0.0", port) catch |err| {
        return try root.resultTuple(vm, .err, try vm.dataAtom(@errorName(err)));
    };

    const server = addr.listen(vm.runtime.io, .{
        .mode = std.Io.net.Socket.Mode.stream,
        .protocol = std.Io.net.Protocol.tcp,
        .kernel_backlog = backlog,
        .reuse_address = true,
    }) catch |err| {
        return try root.resultTuple(vm, .err, try vm.dataAtom(@errorName(err)));
    };

    setSocketNonBlocking(server.socket.handle) catch |err| return try root.resultTuple(vm, .err, try vm.dataAtom(@errorName(err)));

    const entry_ptr = try vm.runtime.alloc.create(SocketEntry);
    entry_ptr.* = .{ .server = server };

    return try .Ok(vm, try wrapSocket(vm, entry_ptr, true));
}

/// > socket:accept() -> socket
/// accepts an incoming client connection on a server socket
fn accept_fn(args: []const Data, vm: *VM) !NativeResult {
    const socket_data = Data{ .table = args[0].table };

    if (!try isServer(socket_data, vm)) return try root.resultTuple(vm, .err, revo.core_atoms.data(.NotServerSocket));

    const entry_ptr = try getEntryPtr(socket_data, vm);
    const server = switch (entry_ptr.*) {
        .server => |*s| s,
        .stream => return try root.resultTuple(vm, .err, revo.core_atoms.data(.NotServerSocket)),
    };

    // if an async backend is present, dispatch to the default backend submit
    if (vm.runtime.async_backend) |backend| {
        // allocate job and submit to backend; backend owns job afterwards
        const job = try vm.runtime.alloc.create(revo.async_backend.AsyncJob);
        job.* = .{
            .fiber_id = vm.sched.current_fiber,
            .kind = revo.async_backend.AsyncJobKind.socket_accept,
            .handle = server.socket.handle,
            .message_id = 0,
            .offset = 0,
            .buffer = null,
            .max_bytes = 0,
        };
        _ = try revo.async_backend_posix.submit(backend, @ptrCast(vm), job);
        // park current fiber; backend must wake it
        vm.sched.parkCurrent(.{ .io = .{ .wait_id = @intCast(server.socket.handle) } });
        return .parked();
    }

    const rc = std.c.accept(server.socket.handle, null, null);
    switch (std.posix.errno(rc)) {
        .AGAIN => {
            try vm.sched.parkCurrentForIo(
                vm.runtime.alloc,
                @intCast(server.socket.handle),
                .read,
                0,
                onAcceptReady,
                null,
            );
            return .parked();
        },
        .SUCCESS => {},
        else => |err| return try root.resultTuple(vm, .err, try vm.dataAtom(@tagName(err))),
    }
    const handle: std.posix.fd_t = @intCast(rc);
    setSocketNonBlocking(handle) catch |err| return try root.resultTuple(vm, .err, try vm.dataAtom(@errorName(err)));
    const new_entry_ptr = try vm.runtime.alloc.create(SocketEntry);
    new_entry_ptr.* = .{
        .stream = .{
            .socket = .{
                .socket = .{
                    .handle = handle,
                    .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } },
                },
            },
            .pending = &.{},
        },
    };
    return try .Ok(vm, try wrapSocket(vm, new_entry_ptr, false));
}

/// > socket:send(data: string) -> number
/// sends data over the socket, returns number of bytes sent
fn send_fn(args: []const Data, vm: *VM) !NativeResult {
    const socket_data = Data{ .table = args[0].table };
    const message = vm.stringValue(args[1].string);

    if (try isServer(socket_data, vm)) return try root.resultTuple(vm, .err, revo.core_atoms.data(.CannotSendOnServer));

    const entry_ptr = try getEntryPtr(socket_data, vm);
    const stream = switch (entry_ptr.*) {
        .stream => |*s| s,
        .server => return try root.resultTuple(vm, .err, revo.core_atoms.data(.CannotSendOnServer)),
    };

    const handle = stream.socket.socket.handle;

    // if runtime async backend supports submit, offload to backend
    if (vm.runtime.async_backend) |backend| {
        const job = try vm.runtime.alloc.create(revo.async_backend.AsyncJob);
        job.* = .{
            .fiber_id = vm.sched.current_fiber,
            .kind = revo.async_backend.AsyncJobKind.socket_send,
            .handle = handle,
            .message_id = args[1].string, // store StringID as usize
            .offset = 0,
            .buffer = null,
            .max_bytes = 0,
        };
        _ = try revo.async_backend_posix.submit(backend, @ptrCast(vm), job);
        vm.sched.parkCurrent(.{ .io = .{ .wait_id = @intCast(handle) } });
        return .parked();
    }

    const flags: u32 = std.posix.MSG.DONTWAIT | std.posix.MSG.NOSIGNAL;
    const rc = std.c.send(handle, message.ptr, message.len, flags);
    switch (std.posix.errno(rc)) {
        .AGAIN => {
            const token_ptr = try vm.runtime.alloc.create(SendWaitToken);
            token_ptr.* = .{ .message = args[1].string, .offset = 0 };
            try vm.sched.parkCurrentForIo(
                vm.runtime.alloc,
                @intCast(handle),
                .write,
                @intFromPtr(token_ptr),
                onSendReady,
                deinitSendToken,
            );
            return .parked();
        },
        .SUCCESS => {},
        else => |err| return try root.resultTuple(vm, .err, try vm.dataAtom(@tagName(err))),
    }
    const sent: usize = @intCast(rc);
    if (sent >= message.len) return try .Ok(vm, Data.new.num(sent));
    const token_ptr = try vm.runtime.alloc.create(SendWaitToken);
    token_ptr.* = .{ .message = args[1].string, .offset = sent };
    try vm.sched.parkCurrentForIo(
        vm.runtime.alloc,
        @intCast(handle),
        .write,
        @intFromPtr(token_ptr),
        onSendReady,
        deinitSendToken,
    );
    return .parked();
}

fn parseRecvOptions(opts_data: Data, vm: *VM) !RecvWaitToken {
    var token: RecvWaitToken = .{};
    const opts = try vm.tables.get(opts_data.table);

    if (opts.getRaw(Data.new.atom(try vm.internAtom("max_bytes")))) |max_d| {
        if (max_d != .number) return error.TypeError;
        token.max_bytes = @as(usize, @intFromFloat(max_d.number));
    }
    if (token.max_bytes == 0) token.max_bytes = 1;

    if (opts.getRaw(Data.new.atom(try vm.internAtom("delimiter")))) |delim_d| {
        if (delim_d != .string) return error.TypeError;
        const s = vm.stringValue(delim_d.string);
        if (s.len == 0) return error.TypeError;
        token.delimiter = s[0];
    }

    if (opts.getRaw(Data.new.atom(try vm.internAtom("mode")))) |mode_d| {
        if (mode_d != .atom) return error.TypeError;
        const a = mode_d.atom;
        if (a == try vm.internAtom("read_some")) {
            token.mode = .read_some;
        } else if (a == try vm.internAtom("read_all")) {
            token.mode = .read_all;
        } else if (a == try vm.internAtom("read_line")) {
            token.mode = .read_line;
        } else {
            return error.TypeError;
        }
    }

    return token;
}

/// > socket:recv(opts: table) -> string
/// receives data according to opts.mode (:read_some | :read_all | :read_line)
fn recv(args: []const Data, vm: *VM) !NativeResult {
    const socket_data = Data{ .table = args[0].table };
    const opts_data = args[1];

    if (try isServer(socket_data, vm)) return try root.resultTuple(vm, .err, revo.core_atoms.data(.CannotRecvOnServer));

    const entry_ptr = try getEntryPtr(socket_data, vm);
    const stream = switch (entry_ptr.*) {
        .stream => |*s| s,
        .server => return try root.resultTuple(vm, .err, revo.core_atoms.data(.CannotRecvOnServer)),
    };

    var parsed = parseRecvOptions(opts_data, vm) catch return .errType(1, "recv opts table", @tagName(opts_data));
    parsed.entry_ptr = entry_ptr;

    const handle = stream.socket.socket.handle;
    const flags: u32 = std.posix.MSG.DONTWAIT | std.posix.MSG.NOSIGNAL;

    switch (parsed.mode) {
        .read_some => {
            if (stream.pending.len > 0) {
                const take = @min(parsed.max_bytes, stream.pending.len);
                const payload = try vm.ownDataString(stream.pending[0..take]);
                if (take < stream.pending.len) {
                    const rest = try vm.runtime.alloc.dupe(u8, stream.pending[take..]);
                    if (stream.pending.len > 0) vm.runtime.alloc.free(stream.pending);
                    stream.pending = rest;
                } else {
                    if (stream.pending.len > 0) vm.runtime.alloc.free(stream.pending);
                    stream.pending = &.{};
                }
                return try .Ok(vm, payload);
            }
            const recv_buf = try vm.runtime.alloc.alloc(u8, parsed.max_bytes);
            defer vm.runtime.alloc.free(recv_buf);
            const rc = std.c.recv(handle, recv_buf.ptr, recv_buf.len, flags);
            switch (std.posix.errno(rc)) {
                .AGAIN => {},
                .SUCCESS => {
                    const n: usize = @intCast(rc);
                    if (n == 0) return try root.resultTuple(vm, .err, revo.core_atoms.data(.SocketClosed));
                    return try .Ok(vm, try vm.ownDataString(recv_buf[0..n]));
                },
                else => |err| return try root.resultTuple(vm, .err, try vm.dataAtom(@tagName(err))),
            }
        },
        .read_line => {
            if (try tryExtractPendingDelimited(vm, stream, parsed.delimiter)) |line| return try .Ok(vm, line);
            while (true) {
                const recv_buf = try vm.runtime.alloc.alloc(u8, parsed.max_bytes);
                defer vm.runtime.alloc.free(recv_buf);
                const rc = std.c.recv(handle, recv_buf.ptr, recv_buf.len, flags);
                switch (std.posix.errno(rc)) {
                    .AGAIN => break,
                    .SUCCESS => {},
                    else => |err| return try root.resultTuple(vm, .err, try vm.dataAtom(@tagName(err))),
                }
                const n: usize = @intCast(rc);
                if (n == 0) {
                    if (stream.pending.len > 0) {
                        const payload = try vm.ownDataString(stream.pending);
                        if (stream.pending.len > 0) vm.runtime.alloc.free(stream.pending);
                        stream.pending = &.{};
                        return try .Ok(vm, payload);
                    }
                    return try root.resultTuple(vm, .err, revo.core_atoms.data(.SocketClosed));
                }
                try appendPending(vm.runtime.alloc, stream, recv_buf[0..n]);
                if (try tryExtractPendingDelimited(vm, stream, parsed.delimiter)) |line| return try .Ok(vm, line);
            }
        },
        .read_all => {
            while (true) {
                const recv_buf = try vm.runtime.alloc.alloc(u8, parsed.max_bytes);
                defer vm.runtime.alloc.free(recv_buf);
                const rc = std.c.recv(handle, recv_buf.ptr, recv_buf.len, flags);
                switch (std.posix.errno(rc)) {
                    .AGAIN => break,
                    .SUCCESS => {},
                    else => |err| return try root.resultTuple(vm, .err, try vm.dataAtom(@tagName(err))),
                }
                const n: usize = @intCast(rc);
                if (n == 0) {
                    if (stream.pending.len > 0) {
                        const payload = try vm.ownDataString(stream.pending);
                        if (stream.pending.len > 0) vm.runtime.alloc.free(stream.pending);
                        stream.pending = &.{};
                        return try .Ok(vm, payload);
                    }
                    return try root.resultTuple(vm, .err, revo.core_atoms.data(.SocketClosed));
                }
                try appendPending(vm.runtime.alloc, stream, recv_buf[0..n]);
            }
        },
    }

    const token_ptr = try vm.runtime.alloc.create(RecvWaitToken);
    token_ptr.* = parsed;
    try vm.sched.parkCurrentForIo(
        vm.runtime.alloc,
        @intCast(handle),
        .read,
        @intFromPtr(token_ptr),
        onRecvReady,
        deinitRecvToken,
    );
    return .parked();
}

/// > socket:close() -> atom
/// closes the socket
fn socket_close_fn(args: []const Data, vm: *VM) !NativeResult {
    const socket_data = Data{ .table = args[0].table };
    try closeEntry(socket_data, vm);
    return try .Ok(vm, revo.core_atoms.data(.nil));
}
