const std = @import("std");

pub const Span = struct { start: usize, end: usize };
pub const Declaration = struct { name: Span, source: Span };
pub const Document = struct { declarations: []Declaration, count: usize = 0, names: []u8, names_used: usize = 0 };
pub const Reason = enum { malformed_source, unsupported_declaration, duplicate_name, declaration_set_changed, declaration_order_changed, ambiguous_shell, resource_limit };
pub const Outcome = union(enum) { clean: usize, conflict: void, degraded: Reason };
pub const Workspace = struct {
    base: Document,
    left: Document,
    right: Document,
    scratch_memory: []u8,
    max_bytes: usize = 1 * 1024 * 1024,
    max_tokens: usize = 100_000,
    max_depth: usize = 512,
    max_work: usize = 32 * 1024 * 1024,
};
pub const Error = error{ AliasedBuffers, CapacityExceeded, InvalidWorkspace };

/// Merge existing named top-level fn/const/var declarations only; edits replace exact declaration token ranges.
pub fn merge(base: []const u8, left: []const u8, right: []const u8, output: []u8, workspace: *Workspace) Error!Outcome {
    if (aliases(output, base) or aliases(output, left) or aliases(output, right) or aliases(output, workspace.scratch_memory)) return error.AliasedBuffers;
    if (aliases(workspace.scratch_memory, base) or aliases(workspace.scratch_memory, left) or aliases(workspace.scratch_memory, right)) return error.AliasedBuffers;
    const docs = [_]Document{ workspace.base, workspace.left, workspace.right };
    const inputs = [_][]const u8{ base, left, right };
    for (docs, 0..) |doc, i| {
        if (aliases(output, std.mem.sliceAsBytes(doc.declarations)) or aliases(output, doc.names)) return error.AliasedBuffers;
        if (aliases(doc.names, workspace.scratch_memory) or aliases(std.mem.sliceAsBytes(doc.declarations), workspace.scratch_memory)) return error.AliasedBuffers;
        for (inputs) |input| if (aliases(doc.names, input) or aliases(std.mem.sliceAsBytes(doc.declarations), input)) return error.AliasedBuffers;
        for (docs[0..i]) |prior| if (aliases(doc.names, prior.names) or aliases(std.mem.sliceAsBytes(doc.declarations), std.mem.sliceAsBytes(prior.declarations)) or aliases(doc.names, std.mem.sliceAsBytes(prior.declarations)) or aliases(std.mem.sliceAsBytes(doc.declarations), prior.names)) return error.AliasedBuffers;
    }
    const total = std.math.add(usize, std.math.add(usize, base.len, left.len) catch return .{ .degraded = .resource_limit }, right.len) catch return .{ .degraded = .resource_limit };
    if (total > workspace.max_work) return .{ .degraded = .resource_limit };
    const parsed_base = parse(base, &workspace.base, workspace) catch |err| return parse_failure(err);
    const parsed_left = parse(left, &workspace.left, workspace) catch |err| return parse_failure(err);
    const parsed_right = parse(right, &workspace.right, workspace) catch |err| return parse_failure(err);
    _ = parsed_base;
    _ = parsed_left;
    _ = parsed_right;
    if (!same_set(workspace.base, workspace.left) or !same_set(workspace.base, workspace.right)) return .{ .degraded = .declaration_set_changed };
    if (!same_order(workspace.base, workspace.left) or !same_order(workspace.base, workspace.right)) return .{ .degraded = .declaration_order_changed };
    if (!same_shell(base, left, workspace.base, workspace.left) or !same_shell(base, right, workspace.base, workspace.right)) return .{ .degraded = .ambiguous_shell };
    return render(base, left, right, output, workspace);
}

fn parse_failure(err: anyerror) Outcome {
    return .{ .degraded = switch (err) {
        error.Malformed => .malformed_source,
        error.Unsupported => .unsupported_declaration,
        error.Duplicate => .duplicate_name,
        error.Limit => .resource_limit,
        else => .malformed_source,
    } };
}

fn parse(input: []const u8, doc: *Document, workspace: *Workspace) error{ Malformed, Unsupported, Duplicate, Limit }!void {
    doc.count = 0;
    doc.names_used = 0;
    if (input.len > workspace.max_bytes or std.mem.indexOfScalar(u8, input, 0) != null) return error.Malformed;
    if (input.len + 1 > workspace.scratch_memory.len) return error.Limit;
    var fixed = std.heap.FixedBufferAllocator.init(workspace.scratch_memory);
    const sentinel = fixed.allocator().allocSentinel(u8, input.len, 0) catch return error.Limit;
    @memcpy(sentinel, input);
    var tokenizer = std.zig.Tokenizer.init(sentinel);
    var token_count: usize = 0;
    var depth: usize = 0;
    while (true) {
        const token = tokenizer.next();
        token_count += 1;
        if (token_count > workspace.max_tokens) return error.Limit;
        if (token.tag == .eof) break;
        if (token.tag == .invalid) return error.Malformed;
        switch (token.tag) {
            .l_brace, .l_paren, .l_bracket => {
                depth += 1;
                if (depth > workspace.max_depth) return error.Limit;
            },
            .r_brace, .r_paren, .r_bracket => if (depth > 0) {
                depth -= 1;
            },
            else => {},
        }
    }
    // Token nesting is bounded before the AST allocator/parser runs.
    var tree = std.zig.Ast.parse(fixed.allocator(), sentinel, .{}) catch return error.Limit;
    defer tree.deinit(fixed.allocator());
    if (tree.errors.len != 0) return error.Malformed;
    const roots = tree.rootDecls();
    if (roots.len > doc.declarations.len) return error.Limit;
    for (roots) |node| {
        const tag = tree.nodeTag(node);
        var name_token: std.zig.Ast.TokenIndex = undefined;
        switch (tag) {
            .fn_decl => {
                var scratch: [1]std.zig.Ast.Node.Index = undefined;
                const proto = tree.fullFnProto(&scratch, node) orelse return error.Unsupported;
                name_token = proto.name_token orelse return error.Unsupported;
            },
            .global_var_decl, .simple_var_decl, .aligned_var_decl => {
                const decl = tree.fullVarDecl(node) orelse return error.Unsupported;
                name_token = decl.ast.mut_token + 1;
            },
            else => return error.Unsupported,
        }
        const raw_name = tree.tokenSlice(name_token);
        const name = normalize_name(raw_name) orelse return error.Unsupported;
        const first = tree.nodeMainToken(node);
        const last = tree.lastToken(node);
        const start = tree.tokenStart(first);
        const last_start = tree.tokenStart(last);
        const source_end = last_start + tree.tokenSlice(last).len;
        if (source_end > input.len or start >= source_end) return error.Malformed;
        if (doc.names_used + name.len > doc.names.len) return error.Limit;
        const name_span = Span{ .start = doc.names_used, .end = doc.names_used + name.len };
        @memcpy(doc.names[name_span.start..name_span.end], name);
        doc.names_used = name_span.end;
        for (doc.declarations[0..doc.count]) |existing| if (equal_name(doc.*, existing.name, name_span)) return error.Duplicate;
        doc.declarations[doc.count] = .{ .name = name_span, .source = .{ .start = start, .end = source_end } };
        doc.count += 1;
    }
}

fn normalize_name(raw: []const u8) ?[]const u8 {
    if (raw.len == 0) return null;
    if (raw[0] != '@') return raw;
    if (raw.len < 3 or raw[1] != '"' or raw[raw.len - 1] != '"') return null;
    const body = raw[2 .. raw.len - 1];
    if (std.mem.indexOfScalar(u8, body, '\\') != null or body.len == 0) return null;
    return body;
}

fn equal_name(a: Document, a_span: Span, b_span: Span) bool {
    return std.mem.eql(u8, a.names[a_span.start..a_span.end], a.names[b_span.start..b_span.end]);
}

fn same_set(base: Document, side: Document) bool {
    if (base.count != side.count) return false;
    for (base.declarations[0..base.count]) |item| {
        var found = false;
        for (side.declarations[0..side.count]) |candidate| {
            if (std.mem.eql(u8, base.names[item.name.start..item.name.end], side.names[candidate.name.start..candidate.name.end])) found = true;
        }
        if (!found) return false;
    }
    return true;
}

fn same_order(base: Document, side: Document) bool {
    if (base.count != side.count) return false;
    for (base.declarations[0..base.count], side.declarations[0..side.count]) |a, b| {
        if (!std.mem.eql(u8, base.names[a.name.start..a.name.end], side.names[b.name.start..b.name.end])) return false;
    }
    return true;
}

fn same_shell(base: []const u8, side: []const u8, base_doc: Document, side_doc: Document) bool {
    var bc: usize = 0;
    var sc: usize = 0;
    for (base_doc.declarations[0..base_doc.count], side_doc.declarations[0..side_doc.count]) |b, s| {
        if (!std.mem.eql(u8, base[bc..b.source.start], side[sc..s.source.start])) return false;
        bc = b.source.end;
        sc = s.source.end;
    }
    return std.mem.eql(u8, base[bc..], side[sc..]);
}

fn render(base: []const u8, left: []const u8, right: []const u8, output: []u8, workspace: *Workspace) Error!Outcome {
    var needed = base.len;
    for (workspace.base.declarations[0..workspace.base.count], workspace.left.declarations[0..workspace.left.count], workspace.right.declarations[0..workspace.right.count]) |b, l, r| {
        const choice = choose(base[b.source.start..b.source.end], left[l.source.start..l.source.end], right[r.source.start..r.source.end]) orelse return .conflict;
        needed = std.math.sub(usize, needed, b.source.end - b.source.start) catch return error.InvalidWorkspace;
        needed = std.math.add(usize, needed, choice.len) catch return error.InvalidWorkspace;
    }
    if (needed > output.len) return error.CapacityExceeded;
    var source_cursor: usize = 0;
    var target_cursor: usize = 0;
    for (workspace.base.declarations[0..workspace.base.count], workspace.left.declarations[0..workspace.left.count], workspace.right.declarations[0..workspace.right.count]) |b, l, r| {
        const selected = choose(base[b.source.start..b.source.end], left[l.source.start..l.source.end], right[r.source.start..r.source.end]).?;
        const gap = base[source_cursor..b.source.start];
        @memcpy(output[target_cursor .. target_cursor + gap.len], gap);
        target_cursor += gap.len;
        @memcpy(output[target_cursor .. target_cursor + selected.len], selected);
        target_cursor += selected.len;
        source_cursor = b.source.end;
    }
    @memcpy(output[target_cursor .. target_cursor + base.len - source_cursor], base[source_cursor..]);
    target_cursor += base.len - source_cursor;
    std.debug.assert(target_cursor == needed);
    return .{ .clean = target_cursor };
}

fn choose(base: []const u8, left: []const u8, right: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, left, base)) return right;
    if (std.mem.eql(u8, right, base)) return left;
    if (std.mem.eql(u8, left, right)) return left;
    return null;
}

fn aliases(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const ap = @intFromPtr(a.ptr);
    const bp = @intFromPtr(b.ptr);
    return if (ap <= bp) bp - ap < a.len else ap - bp < b.len;
}

test "separate named functions compose while preserving CRLF comments" {
    var bd: [4]Declaration = undefined;
    var ld: [4]Declaration = undefined;
    var rd: [4]Declaration = undefined;
    var bn: [64]u8 = undefined;
    var ln: [64]u8 = undefined;
    var rn: [64]u8 = undefined;
    var scratch: [8192]u8 = undefined;
    var workspace = Workspace{ .base = .{ .declarations = &bd, .names = &bn }, .left = .{ .declarations = &ld, .names = &ln }, .right = .{ .declarations = &rd, .names = &rn }, .scratch_memory = &scratch };
    const base = "// keep\r\npub fn alpha() u8 { return 1; }\r\npub fn beta() u8 { return 1; }\r\n";
    const left = "// keep\r\npub fn alpha() u8 { return 2; }\r\npub fn beta() u8 { return 1; }\r\n";
    const right = "// keep\r\npub fn alpha() u8 { return 1; }\r\npub fn beta() u8 { return 3; }\r\n";
    var output: [256]u8 = undefined;
    const result = try merge(base, left, right, &output, &workspace);
    try std.testing.expectEqualStrings("// keep\r\npub fn alpha() u8 { return 2; }\r\npub fn beta() u8 { return 3; }\r\n", output[0..result.clean]);
}

test "same-line declarations, quoted and UTF-8 names are matched semantically" {
    var bd: [8]Declaration = undefined;
    var ld: [8]Declaration = undefined;
    var rd: [8]Declaration = undefined;
    var bn: [128]u8 = undefined;
    var ln: [128]u8 = undefined;
    var rn: [128]u8 = undefined;
    var scratch: [8192]u8 = undefined;
    var workspace = Workspace{ .base = .{ .declarations = &bd, .names = &bn }, .left = .{ .declarations = &ld, .names = &ln }, .right = .{ .declarations = &rd, .names = &rn }, .scratch_memory = &scratch };
    const base = "fn alpha() u8 { return 0; } fn @\"quoted\"() u8 { return 0; } fn @\"café\"() u8 { return 0; }";
    const left = "fn alpha() u8 { return 1; } fn @\"quoted\"() u8 { return 0; } fn @\"café\"() u8 { return 0; }";
    const right = "fn alpha() u8 { return 0; } fn @\"quoted\"() u8 { return 2; } fn @\"café\"() u8 { return 3; }";
    var output: [256]u8 = undefined;
    const result = try merge(base, left, right, &output, &workspace);
    try std.testing.expectEqualStrings("fn alpha() u8 { return 1; } fn @\"quoted\"() u8 { return 2; } fn @\"café\"() u8 { return 3; }", output[0..result.clean]);
    const duplicate = try merge("fn @\"same\"() void {} fn same() void {}", "fn @\"same\"() void {} fn same() void {}", "fn @\"same\"() void {} fn same() void {}", &output, &workspace);
    try std.testing.expect(duplicate.degraded == .duplicate_name);
}

test "unsupported declarations and nested strings degrade without output writes" {
    var bd: [8]Declaration = undefined;
    var ld: [8]Declaration = undefined;
    var rd: [8]Declaration = undefined;
    var bn: [128]u8 = undefined;
    var ln: [128]u8 = undefined;
    var rn: [128]u8 = undefined;
    var scratch: [8192]u8 = undefined;
    var workspace = Workspace{ .base = .{ .declarations = &bd, .names = &bn }, .left = .{ .declarations = &ld, .names = &ln }, .right = .{ .declarations = &rd, .names = &rn }, .scratch_memory = &scratch };
    var output: [128]u8 = @splat(0xa5);
    const unsupported = try merge("test { }", "test { }", "test { }", &output, &workspace);
    try std.testing.expect(unsupported.degraded == .unsupported_declaration);
    const embedded = try merge("const text = \" } ) ] fn fake() {} \";", "const text = \" } ) ] fn fake() {} \";", "const text = \" } ) ] fn fake() {} \";", &output, &workspace);
    try std.testing.expectEqualStrings("const text = \" } ) ] fn fake() {} \";", output[0..embedded.clean]);
    try std.testing.expectEqual(@as(u8, 0xa5), output[embedded.clean]);
}

test "conflict, duplicates, malformed input and resource limits preserve output" {
    var bd: [4]Declaration = undefined;
    var ld: [4]Declaration = undefined;
    var rd: [4]Declaration = undefined;
    var bn: [64]u8 = undefined;
    var ln: [64]u8 = undefined;
    var rn: [64]u8 = undefined;
    var scratch: [8192]u8 = undefined;
    var workspace = Workspace{ .base = .{ .declarations = &bd, .names = &bn }, .left = .{ .declarations = &ld, .names = &ln }, .right = .{ .declarations = &rd, .names = &rn }, .scratch_memory = &scratch };
    var output: [128]u8 = @splat(0xa5);
    const conflict = try merge("const x = 1;", "const x = 2;", "const x = 3;", &output, &workspace);
    try std.testing.expect(conflict == .conflict);
    try std.testing.expectEqual(@as(u8, 0xa5), output[0]);
    const duplicate = try merge("const x=1; const x=2;", "const x=1; const x=2;", "const x=1; const x=2;", &output, &workspace);
    try std.testing.expect(duplicate.degraded == .duplicate_name);
    const malformed = try merge("const x = ;", "const x = ;", "const x = ;", &output, &workspace);
    try std.testing.expect(malformed.degraded == .malformed_source);
    workspace.max_depth = 1;
    const deep = try merge("fn x() void { if (true) {} }", "fn x() void { if (true) {} }", "fn x() void { if (true) {} }", &output, &workspace);
    try std.testing.expect(deep.degraded == .resource_limit);
    workspace.max_depth = 512;
    workspace.max_work = 0;
    const no_work = try merge("const x=1;", "const x=1;", "const x=1;", &output, &workspace);
    try std.testing.expect(no_work.degraded == .resource_limit);
    workspace.max_work = 32 * 1024 * 1024;
    const original_scratch = workspace.scratch_memory;
    workspace.scratch_memory = workspace.scratch_memory[0..8];
    const ast_limited = try merge("const x=1;", "const x=1;", "const x=1;", &output, &workspace);
    try std.testing.expect(ast_limited.degraded == .resource_limit);
    workspace.scratch_memory = original_scratch;
    workspace.max_tokens = 1;
    const limited = try merge("const x=1;", "const x=1;", "const x=1;", &output, &workspace);
    try std.testing.expect(limited.degraded == .resource_limit);
    try std.testing.expectEqual(@as(u8, 0xa5), output[0]);
}
