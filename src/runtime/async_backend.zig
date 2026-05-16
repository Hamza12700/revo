// an backend-owned job abstraction
// backend may keep its own payload types; job here is a minimal common payload

pub const AsyncTicket = usize;

const std = @import("std");

pub const AsyncJobKind = enum {
    socket_send,
    socket_recv,
    socket_accept,
};

pub const AsyncJob = struct {
    fiber_id: usize,
    kind: AsyncJobKind,
    handle: std.posix.fd_t,
    // message_id stores the VM string id as usize
    message_id: usize,
    offset: usize,
    // optional buffer for recv; allocated w runtime.alloc and owned by backend after submit
    buffer: ?[]u8,
    max_bytes: usize,
};

/// optional fn pointers: backend would provide implementations
pub const AsyncBackend = struct {
    // submit receives opaque vm pointer so implementations can pull VM data it needs
    submit: ?*const anyopaque,
    cancel: ?*const anyopaque,
    // vm_ptr is an opaque pointer to VM; backend implementations should cast to actual VM type
    poll: ?*const anyopaque,
    shutdown: ?*const anyopaque,
    // backend-private state pointer (opaque)
    // this also means you can swap out backends on the fly
    data: ?*anyopaque,
};
