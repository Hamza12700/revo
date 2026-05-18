const std = @import("std");

const revo = @import("revo");
const Data = revo.Data;
const Instruction = revo.Instruction;
const Opcode = revo.opcode.Opcode;
const VM = revo.VM;
const UpvalueSpec = revo.functions.UpvalueSpec;
const LocalSlot = revo.LocalSlot;
const ProgramCounter = revo.ProgramCounter;
const Operand = revo.Operand;
const Register = revo.opcode.Register;

const ast = @import("../ast.zig");
const Node = ast.Node;
const Binding = ast.Binding;
const StructItem = ast.StructItem;
const expander = @import("../expander.zig");
const emit = @import("emit.zig");
const flow = @import("flow.zig");
const fold = @import("fold.zig");
const state_mod = @import("state.zig");
const values = @import("values.zig");

//
// compiler result types
//
pub const LowerErrorKind = enum {
    ParseError,
    UnsupportedSyntax,
    InvalidAssignmentTarget,
    IntegerOutOfRange,
};

pub const LowerFailure = struct {
    kind: LowerErrorKind,
    span: ast.Span,
    message: []const u8,
    source_name: ?[]const u8 = null,
};

pub const LowerResult = union(enum) {
    ok: []Instruction,
    err: LowerFailure,
};

pub const Artifact = struct {
    instructions: []Instruction,
    spans: []ast.Span,
};

pub const ArtifactResult = union(enum) {
    ok: Artifact,
    err: LowerFailure,
};

pub const LowerError = error{
    ParseError,
    UnsupportedSyntax,
    InvalidAssignmentTarget,
    IntegerOutOfRange,
} || std.mem.Allocator.Error || expander.ExpandError;

// w/ internal sentinel used to short-circuit after recording failure
const InternalLowerError = LowerError || error{LoweringFailed};

pub fn lowerExprArtifactReport(vm: *VM, expr: *const Node, test_mode: bool) !ArtifactResult {
    var compiler = try Compiler.init(vm, test_mode);
    defer compiler.deinit();

    compiler.compileRoot(expr) catch |err| switch (err) {
        error.LoweringFailed => return .{ .err = compiler.failure.? },
        else => return err,
    };
    return .{ .ok = try compiler.finishArtifact() };
}

const LoopScope = state_mod.LoopScope(Compiler);

//
// core compiler
//
pub const Compiler = struct {
    const LocalValueKind = state_mod.LocalValueKind;
    const LocalVar = state_mod.LocalVar;
    const FunctionState = state_mod.FunctionState;
    const Temps = state_mod.Temps;

    vm: *VM,
    comp_vm: *VM, // separate reference for compexpr execution during compilation
    alloc: std.mem.Allocator,
    test_mode: bool,
    instructions: std.ArrayList(Instruction),
    functions: std.ArrayList(FunctionState),
    slot_allocators: std.ArrayList(LocalSlot),
    temps: Temps = .{},
    /// flat list of break jump instruction indices for all enclosing inline loops
    /// each loop tracks its start index in this list; breaks append to it
    /// when a loop ends, it patches all jumps from its start index and shrinks the list
    break_jumps: std.ArrayList(usize),
    /// stack of result registers for inline loops (where break stores its value)
    loop_result_regs: std.ArrayList(usize),
    test_suite_names: std.ArrayList([]const u8),
    /// depth of inline loops for validating break
    in_loop_depth: usize = 0,
    failure: ?LowerFailure = null,
    spans: std.ArrayList(ast.Span),
    active_span: ast.Span = .{ .start = 0, .end = 0, .line = 1, .column = 1 },
    active_registers: usize = 0,
    max_registers: usize = 0,

    pub fn init(vm: *VM, test_mode: bool) !Compiler {
        return .{
            .vm = vm,
            .comp_vm = vm, // just use the same one for now
            .alloc = vm.runtime.alloc,
            .test_mode = test_mode,
            .instructions = try std.ArrayList(Instruction).initCapacity(vm.runtime.alloc, 32),
            .functions = try std.ArrayList(FunctionState).initCapacity(vm.runtime.alloc, 4),
            .slot_allocators = try std.ArrayList(LocalSlot).initCapacity(vm.runtime.alloc, 4),
            .spans = try std.ArrayList(ast.Span).initCapacity(vm.runtime.alloc, 32),
            .break_jumps = try std.ArrayList(usize).initCapacity(vm.runtime.alloc, 16),
            .loop_result_regs = try std.ArrayList(usize).initCapacity(vm.runtime.alloc, 8),
            .test_suite_names = try std.ArrayList([]const u8).initCapacity(vm.runtime.alloc, 4),
        };
    }

    pub fn deinit(self: *Compiler) void {
        // comp_vm is just a reference to vm, so its not deinitted
        for (self.functions.items) |*state| state.deinit(self.alloc);
        self.functions.deinit(self.alloc);
        self.slot_allocators.deinit(self.alloc);
        self.instructions.deinit(self.alloc);
        self.spans.deinit(self.alloc);
        self.break_jumps.deinit(self.alloc);
        self.loop_result_regs.deinit(self.alloc);
        self.test_suite_names.deinit(self.alloc);
    }

    /// pushes a new register onto the stack and returns it,
    /// then updates max_registers
    pub fn pushRegister(self: *Compiler) !Register {
        return state_mod.pushRegister(self);
    }

    /// pops the top register from the stack
    pub fn popRegister(self: *Compiler) void {
        state_mod.popRegister(self);
    }

    pub fn finishArtifact(self: *Compiler) !Artifact {
        return .{
            .instructions = try self.instructions.toOwnedSlice(self.alloc),
            .spans = try self.spans.toOwnedSlice(self.alloc),
        };
    }

    pub fn compile(self: *Compiler, expr: *const Node, keep: bool) InternalLowerError!void {
        // track source span so emitted instructions keep debug mapping
        const prev_span = self.active_span;
        self.active_span = expr.span;
        defer self.active_span = prev_span;
        try self.compileValue(expr);
        if (!keep) try emit.regRelease(self);
    }

    pub fn compileRoot(self: *Compiler, expr: *const Node) InternalLowerError!void {
        try self.compileFn(&.{}, expr, "__main", null);
        try emit.emit(self, .call, 0);
        try emit.emit(self, .halt, 0);
    }

    pub fn formatSuiteTestName(self: *Compiler, test_name: []const u8) ![]u8 {
        var out = try std.ArrayList(u8).initCapacity(self.alloc, test_name.len + 16);
        errdefer out.deinit(self.alloc);

        if (self.test_suite_names.items.len == 0) {
            try out.appendSlice(self.alloc, test_name);
            return out.toOwnedSlice(self.alloc);
        }

        try out.appendSlice(self.alloc, self.test_suite_names.items[0]);
        for (self.test_suite_names.items[1..]) |suite_name| {
            try out.appendSlice(self.alloc, "::");
            try out.appendSlice(self.alloc, suite_name);
        }
        try out.appendSlice(self.alloc, "::");
        try out.appendSlice(self.alloc, test_name);
        return out.toOwnedSlice(self.alloc);
    }

    pub fn compileValue(self: *Compiler, expr: *const Node) InternalLowerError!void {
        switch (expr.expr) {
            //
            // atoms & identifiers
            //
            .number => |n| {
                if (std.math.isFinite(n) and @floor(n) == n and
                    n >= @as(f64, @floatFromInt(std.math.minInt(i64))) and
                    n <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
                {
                    try emit.@"const"(self, Data.new.num(@as(i64, @intFromFloat(n))));
                } else {
                    try emit.@"const"(self, Data.new.num(n));
                }
            },
            .string => |s| try emit.@"const"(self, try self.vm.ownDataString(s)),
            .multiline_string => |s| try emit.@"const"(self, try self.vm.ownDataString(s)),
            .hash => |name| try emit.@"const"(self, Data{ .atom = try self.vm.internAtom(name) }),
            .nil => try emit.@"const"(self, Data{ .atom = try self.vm.internAtom("nil") }),
            .ident => |name| {
                if (state_mod.resolveLocal(self, name)) |slot| {
                    try emit.emit(self, .load_local, slot);
                } else if (try state_mod.resolveUpvalue(self, name)) |slot| {
                    try emit.emit(self, .load_upval, slot);
                } else {
                    try emit.emit(self, .load_global, try self.vm.internAtom(name));
                }
            },
            //
            // unary & binary
            //
            .unary => |u| {
                switch (u.op) {
                    .negate => {
                        try self.compile(u.expr, true);
                        try emit.emit(self, .negate, 0);
                    },
                    .not => {
                        try self.compile(u.expr, true);
                        try emit.emit(self, .not, 0);
                    },
                    .join => {
                        try self.compile(u.expr, true);
                        try emit.emit(self, .join, 0);
                    },
                    .yield => {
                        try emit.emit(self, .yield, 0);
                        try emit.nil(self);
                    },
                    .spawn => {
                        switch (u.expr.expr) {
                            .call => |call| {
                                try self.compile(call.callee, true);
                                if (call.implicit_self) switch (call.callee.expr) {
                                    .field => |field| try self.compile(field.object, true),
                                    .index => |index| try self.compile(index.object, true),
                                    else => {},
                                };
                                for (call.args) |arg| try self.compile(arg, true);
                                try emit.emit(self, .spawn, @intCast(call.args.len + @intFromBool(call.implicit_self)));
                            },
                            else => {
                                try self.compile(u.expr, true);
                                try emit.emit(self, .spawn, 0);
                            },
                        }
                    },
                }
            },
            .binary => |b| {
                if (try fold.maybeFoldConstBinary(self, b)) {
                    return;
                }
                try self.compile(b.left, true);
                try self.compile(b.right, true);
                //
                // isnt it really nice how opcode tag names line up with opcode names
                try emit.emit(self, switch (b.op) {
                    inline else => |tag| @field(Opcode, @tagName(tag)),
                }, 0);
            },
            .and_expr => |v| try flow.compileAnd(self, v.left, v.right),
            .or_expr => |v| try flow.compileOr(self, v.left, v.right),
            //
            // call & lookup
            //
            .call => |call| try self.compileCall(expr, call),
            .field => |field| {
                try self.compile(field.object, true);
                try emit.emit(self, .table_get_atom, try self.vm.internAtom(field.name));
            },
            .index => |index| {
                try self.compile(index.object, true);
                if (index.key.expr == .hash) {
                    try emit.emit(self, .table_get_atom, try self.vm.internAtom(index.key.expr.hash));
                } else if (state_mod.constTupleIndex(self, index)) |idx| {
                    try emit.emit(self, .tuple_get_const, idx);
                } else {
                    try self.compile(index.key, true);
                    try emit.emit(self, .table_get, 0);
                }
            },
            //
            // control flow & binding
            //
            .if_expr => |v| try flow.compileIf(self, v.condition, v.then_expr, v.else_expr),
            .con_expr => |binding| try self.compileBinding(binding, .con),
            .global => |binding| try self.compileBinding(binding, .global),
            .let_expr => |binding| try self.compileBinding(binding, .let),
            .assign_expr => |assign| try values.compileAssign(self, assign.target, assign.value),
            .block => |exprs| try self.compileBlock(exprs),
            .tuple => |items| try values.compileTuple(self, items),
            .table => |entries| try values.compileTable(self, entries),
            .struct_def => |def| try values.compileStruct(self, expr, def.name, def.items),
            .return_expr => |val| {
                if (val) |v| try self.compile(v, true) else try emit.nil(self);
                try emit.emit(self, .ret, 1);
            },
            .import_expr => |path| {
                try emit.emit(self, .load_global, try self.vm.internAtom("import"));
                try self.compile(path, true);
                try emit.emit(self, .call, 1);
            },
            .comp_block => |cb| try self.compileComp(cb.expr),
            //
            // core sugar
            //
            .pipe_expr => |pipe| try flow.compilePipe(self, pipe.left, pipe.right),
            .loop_expr => |v| try flow.compileLoop(self, v.body),
            .for_loop => |v| try flow.compileFor(self, v.params, v.body, v.iter),
            .while_loop => |v| try flow.compileWhile(self, v.predicate, v.body),
            .break_expr => |value| try flow.compileBreak(self, expr, value),
            .fn_expr => |fn_expr| try self.compileFn(fn_expr.params, fn_expr.body, "<fn>", null),
            .match_expr => |v| try flow.compileMatch(self, v.subject, v.arms),
            .tuple_pattern => return self.fail(
                .UnsupportedSyntax,
                expr,
                "tuple patterns do not compile as values",
            ),
            .range_literal => {
                return self.fail(
                    .UnsupportedSyntax,
                    expr,
                    "range literals only go in forloops for now",
                );
            },
            .try_expr => |expr_ptr| {
                // try unwrap checks if result is error tuple and returns early if so
                // otherwise unwraps (:ok, x) to x
                try self.compile(expr_ptr, true);
                try emit.emit(self, .unwrap_result, 0); // bx=0 for propagate errors
            },
            .orelse_expr => |v| {
                // compile left if it's error or nil use right
                try self.compile(v.left, true);
                const fail_jump = try emit.jump(self, .jump_if_not_nil_and_not_err);
                try self.compile(v.right, true);
                emit.patchJump(self, fail_jump);
                // unwrap (:ok, x) to x if it got here
                try emit.emit(self, .unwrap_result, 1); // bx=1 for dont propagate errors
            },
            .test_block => |block| {
                if (self.test_mode) {
                    if (!block.skip) {
                        const test_label = try self.formatSuiteTestName(block.name);
                        defer self.alloc.free(test_label);
                        try emit.emit(self, .load_global, try self.vm.internAtom("@dotest"));
                        try emit.@"const"(self, try self.vm.ownDataString(test_label));
                        try self.compile(block.body, true);
                        try emit.emit(self, .call, 2);
                        try emit.regRelease(self);
                    }
                }
                try emit.nil(self);
            },
            .test_suite => |suite| {
                if (self.test_mode) {
                    const suite_label = try self.formatSuiteTestName(suite.name);
                    defer self.alloc.free(suite_label);
                    try emit.emit(self, .load_global, try self.vm.internAtom("@dosuite"));
                    try emit.@"const"(self, try self.vm.ownDataString(suite_label));

                    // push for nested tests
                    try self.test_suite_names.append(self.alloc, suite.name);
                    defer _ = self.test_suite_names.pop();

                    try self.compile(suite.body, true);
                    try emit.emit(self, .call, 2);
                    try emit.regRelease(self);
                }
                try emit.nil(self);
            },
            //
            // tech debt
            //
            .macro_expr => return self.fail(.UnsupportedSyntax, expr, "syntax must be expanded before compilation"),
            .proc_macro => return self.fail(.UnsupportedSyntax, expr, "proc must be expanded before compilation"),
        }
    }

    pub fn compileCall(self: *Compiler, expr: *const Node, call: anytype) InternalLowerError!void {
        _ = expr;
        switch (call.callee.expr) {
            .field => |field| {
                try self.compile(field.object, true);
                try emit.@"const"(self, Data{ .atom = try self.vm.internAtom(field.name) });
                for (call.args) |arg| try self.compile(arg, true);
                const argc = call.args.len | (@as(usize, @intFromBool(call.implicit_self)) << 15);
                try emit.emit(self, .call_field, @intCast(argc));
            },
            .index => |index| {
                try self.compile(index.object, true);
                try self.compile(index.key, true);
                for (call.args) |arg| try self.compile(arg, true);
                const argc = call.args.len | (@as(usize, @intFromBool(call.implicit_self)) << 15);
                try emit.emit(self, .call_field, @intCast(argc));
            },
            else => {
                try self.compile(call.callee, true);
                for (call.args) |arg| try self.compile(arg, true);
                try emit.emit(self, .call, @intCast(call.args.len + @intFromBool(call.implicit_self)));
            },
        }
    }

    pub fn compileComp(self: *Compiler, expr: *Node) InternalLowerError!void {
        // implies shared runtime
        var temp_compiler = try Compiler.init(self.vm, self.test_mode);
        defer temp_compiler.deinit();

        temp_compiler.compileRoot(expr) catch |err| switch (err) {
            error.LoweringFailed => {
                if (temp_compiler.failure) |nested_failure| {
                    self.failure = nested_failure;
                } else {
                    std.debug.assert(false);
                    unreachable;
                }
                return error.LoweringFailed;
            },
            else => return err,
        };

        const artifact = try temp_compiler.finishArtifact();
        defer self.vm.runtime.alloc.free(artifact.instructions);
        defer self.vm.runtime.alloc.free(artifact.spans);

        const result = try VM.module.runCompiledModuleReport(
            self.comp_vm,
            "<comp>",
            artifact.instructions,
        );

        if (result == .err) {
            // not sure how recursive eval will fare here
            const eval_failure = result.err;
            self.failure = .{
                .kind = .ParseError,
                .span = eval_failure.span orelse expr.span,
                .message = eval_failure.message,
                .source_name = eval_failure.source_name,
            };
            return error.LoweringFailed;
        }

        const res = self.comp_vm.mainResult();
        try emit.@"const"(self, res);
    }

    pub fn compileBlock(self: *Compiler, exprs: []const *Node) InternalLowerError!void {
        if (exprs.len == 0)
            return emit.nil(self);

        var pushed_scope = false;
        if (state_mod.currentFunctionState(self) != null) {
            try state_mod.pushScope(self);
            pushed_scope = true;
            errdefer if (pushed_scope) state_mod.popScope(self);
            try state_mod.predeclareFunctionBindings(self, exprs);
        }

        for (exprs, 0..) |expr, idx| {
            try self.compile(expr, true);
            if (idx + 1 < exprs.len) try emit.regRelease(self);
        }

        if (pushed_scope) state_mod.popScope(self);
    }

    const BindingKind = values.BindingKind;
    pub fn compileBinding(self: *Compiler, binding: Binding, kind: BindingKind) InternalLowerError!void {
        // local bindings compile to local slots inside function scope
        // (all code is inside synthetic __main, so you're always in a function)
        if (binding.target.expr == .ident and kind != .global)
            return values.compileLocalBinding(self, binding.target.expr.ident, binding.value, kind != .con);

        if (binding.target.expr == .ident) {
            const name = binding.target.expr.ident;
            if (binding.value.expr == .fn_expr) {
                try self.compileFn(binding.value.expr.fn_expr.params, binding.value.expr.fn_expr.body, name, null);
            } else {
                try self.compile(binding.value, true);
            }
            if (ast.isDiscardName(name)) return;
            try emit.regDupe(self);
            try emit.emit(self, if (kind != .con) .store_global else .store_global_const, try self.vm.internAtom(name));
            return;
        }

        try self.compile(binding.value, true);
        const src_idx = self.active_registers - 1;
        try values.bindPattern(self, binding.target, src_idx, kind);
    }

    //
    // function & loop compilation, shared closure setup/teardown
    //

    pub fn compileFn(
        self: *Compiler,
        params: []const ast.FnParam,
        body: *const Node,
        name: []const u8,
        loop_sym: ?revo.AtomID,
    ) InternalLowerError!void {
        const jump_over = try emit.jump(self, .jump);
        const body_addr: ProgramCounter = @intCast(self.instructions.items.len);
        const caller_registers = self.active_registers;
        const caller_max_registers = self.max_registers;
        errdefer {
            self.active_registers = caller_registers;
            self.max_registers = caller_max_registers;
        }

        var state = try FunctionState.init(self.alloc);
        for (params, 0..) |param, idx| {
            const local: LocalVar = .{ .name = param.name, .slot = @intCast(idx), .mutable = true, .initialized = true };
            state.locals.append(self.alloc, local) catch |err| {
                state.deinit(self.alloc);
                return err;
            };
            state.all_locals.append(self.alloc, local) catch |err| {
                state.deinit(self.alloc);
                return err;
            };
        }
        const params_len: LocalSlot = @intCast(params.len);
        self.functions.append(self.alloc, state) catch |err| {
            state.deinit(self.alloc);
            return err;
        };
        self.slot_allocators.append(self.alloc, params_len) catch |err| {
            var leaked = self.functions.pop() orelse unreachable;
            leaked.deinit(self.alloc);
            return err;
        };

        var state_pushed = true;
        errdefer if (state_pushed) {
            var leaked = self.functions.pop() orelse unreachable;
            leaked.deinit(self.alloc);
            _ = self.slot_allocators.pop() orelse unreachable;
        };

        const prev_in_loop = self.in_loop_depth;
        self.in_loop_depth = 0;
        if (loop_sym != null) {
            self.in_loop_depth += 1;
        }
        defer self.in_loop_depth = prev_in_loop;

        self.active_registers = params.len;
        self.max_registers = params.len;

        try self.compile(body, true);
        if (loop_sym) |sym| {
            try flow.emitLoopRecurse(self, params.len, sym);
        } else {
            try emit.emit(self, .ret, 1);
        }

        const fn_register_count = self.max_registers;
        self.active_registers = caller_registers;
        self.max_registers = caller_max_registers;

        // SAFETY: functions was pushed in compileFn
        var finished = self.functions.pop() orelse unreachable;
        defer finished.deinit(self.alloc);
        _ = self.slot_allocators.pop() orelse unreachable;
        const const_locals = try state_mod.collectConstLocals(self, finished.all_locals.items);
        defer self.alloc.free(const_locals);

        emit.patchJump(self, jump_over);
        const proto_id = try self.vm.functions.createPrototype(.{
            .addr = body_addr,
            .arity = @intCast(params.len),
            .register_count = @intCast(fn_register_count),
            .name = name,
            .upvalue_specs = finished.upvalues.items,
            .const_locals = const_locals,
            .const_local_bits = &.{},
        });
        try emit.emit(self, .closure, proto_id);
        state_pushed = false;
    }

    pub fn fail(
        self: *Compiler,
        kind: LowerErrorKind,
        expr: *const Node,
        message: []const u8,
    ) error{LoweringFailed} {
        return emit.fail(self, kind, expr, message);
    }
};
