// stdlib lookups for the LSP. delegates to `revo.std_lib.api` so
// the runtime and lsp share one table.

const std = @import("std");
const revo = @import("revo");

const api = revo.std_lib.api;

pub const find = api.find;
pub const all_specs = api.all_specs;

/// return the doc string for a stdlib name, or null if unknown
/// or undocumented. useful for completion item docs.
pub fn docFor(name: []const u8) ?[]const u8 {
    const spec = find(name) orelse return null;
    if (spec.doc.len == 0) return null;
    return spec.doc;
}
