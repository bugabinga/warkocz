const std = @import("std");

pub const Span = struct { start: usize, end: usize };
pub const Member = struct { key: Span, value: Span };
pub const Document = struct { members: []Member, count: usize = 0, keys: []u8, keys_used: usize = 0 };
pub const Reason = enum { malformed_json, unsupported_root, duplicate_key, member_set_changed, member_order_changed, ambiguous_formatting, resource_limit };
pub const Outcome = union(enum) { clean: usize, conflict: void, degraded: Reason };
pub const Workspace = struct { base: Document, left: Document, right: Document, scanner_memory: []u8, max_work: usize = 256 * 1024 * 1024 };
pub const Error = error{ AliasedBuffers, CapacityExceeded, InvalidWorkspace };

/// Three-way merge root-object values. Only existing fields in identical order are supported.
/// scanner_memory is fixed backing for std.json.Scanner nesting; all other storage is caller-owned.
pub fn merge(base: []const u8, left: []const u8, right: []const u8, output: []u8, workspace: *Workspace) Error!Outcome {
    if (aliases(output, base) or aliases(output, left) or aliases(output, right) or aliases(output, workspace.scanner_memory) or aliases(output, std.mem.sliceAsBytes(workspace.base.members)) or aliases(output, std.mem.sliceAsBytes(workspace.left.members)) or aliases(output, std.mem.sliceAsBytes(workspace.right.members)) or aliases(output, workspace.base.keys) or aliases(output, workspace.left.keys) or aliases(output, workspace.right.keys)) return error.AliasedBuffers;
    const workspaces = [_][]const u8{
        std.mem.sliceAsBytes(workspace.base.members), std.mem.sliceAsBytes(workspace.left.members), std.mem.sliceAsBytes(workspace.right.members),
        workspace.base.keys,                          workspace.left.keys,                          workspace.right.keys,
        workspace.scanner_memory,
    };
    const inputs = [_][]const u8{ base, left, right };
    for (workspaces, 0..) |work, index| {
        for (inputs) |input| if (aliases(work, input)) return error.AliasedBuffers;
        for (workspaces[0..index]) |prior| if (aliases(work, prior)) return error.AliasedBuffers;
    }
    const input_bytes = std.math.add(usize, std.math.add(usize, base.len, left.len) catch return .{ .degraded = .resource_limit }, right.len) catch return .{ .degraded = .resource_limit };
    // 24x bounds scanner tokenization, span discovery, value comparisons, planning, and copies.
    const linear_work = std.math.mul(usize, input_bytes, 24) catch return .{ .degraded = .resource_limit };
    if (linear_work > workspace.max_work) return .{ .degraded = .resource_limit };
    const base_parsed = parse(base, &workspace.base, workspace.scanner_memory) catch |err| return parse_failure(err);
    const left_parsed = parse(left, &workspace.left, workspace.scanner_memory) catch |err| return parse_failure(err);
    const right_parsed = parse(right, &workspace.right, workspace.scanner_memory) catch |err| return parse_failure(err);
    const comparison_work = worst_case_comparison_work(workspace.base, workspace.left, workspace.right) orelse return .{ .degraded = .resource_limit };
    const total_work = std.math.add(usize, linear_work, comparison_work) catch return .{ .degraded = .resource_limit };
    if (total_work > workspace.max_work) return .{ .degraded = .resource_limit };
    if (!same_members(workspace.base, workspace.left) or !same_members(workspace.base, workspace.right)) return .{ .degraded = .member_set_changed };
    if (!same_order(workspace.base, workspace.left) or !same_order(workspace.base, workspace.right)) return .{ .degraded = .member_order_changed };
    if (!same_shell(base, left, workspace.base, workspace.left) or !same_shell(base, right, workspace.base, workspace.right)) return .{ .degraded = .ambiguous_formatting };
    _ = base_parsed;
    _ = left_parsed;
    _ = right_parsed;
    return render(base, left, right, output, workspace);
}

fn worst_case_comparison_work(base: Document, left: Document, right: Document) ?usize {
    const max_count = @max(base.count, @max(left.count, right.count));
    var max_key_len: usize = 0;
    for ([_]Document{ base, left, right }) |document| {
        for (document.members[0..document.count]) |member| max_key_len = @max(max_key_len, member.key.end - member.key.start);
    }
    const pairs = std.math.mul(usize, max_count, max_count) catch return null;
    const comparison_work = std.math.mul(usize, std.math.mul(usize, pairs, max_key_len) catch return null, 4) catch return null;
    const render_work = std.math.mul(usize, max_count, max_key_len) catch return null;
    return std.math.add(usize, comparison_work, render_work) catch null;
}

fn parse_failure(err: anyerror) Outcome {
    return .{ .degraded = switch (err) {
        error.InvalidJson => .malformed_json,
        error.UnsupportedRoot => .unsupported_root,
        error.DuplicateKey => .duplicate_key,
        error.CapacityExceeded => .resource_limit,
        else => .malformed_json,
    } };
}

fn parse(input: []const u8, document: *Document, scanner_memory: []u8) error{ InvalidJson, UnsupportedRoot, DuplicateKey, CapacityExceeded }!void {
    document.count = 0;
    document.keys_used = 0;
    var fixed = std.heap.FixedBufferAllocator.init(scanner_memory);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), input);
    defer scanner.deinit();
    const first = scanner.next() catch |err| return if (err == error.OutOfMemory) error.CapacityExceeded else error.InvalidJson;
    if (first != .object_begin) return error.UnsupportedRoot;
    while (true) {
        var key_start = scanner.cursor;
        skip_space(input, &key_start);
        if (key_start < input.len and input[key_start] == ',') key_start += 1;
        skip_space(input, &key_start);
        const token = scanner.next() catch |err| return if (err == error.OutOfMemory) error.CapacityExceeded else error.InvalidJson;
        if (token == .object_end) break;
        if (document.count == document.members.len) return error.CapacityExceeded;
        if (key_start >= input.len or input[key_start] != '"') return error.InvalidJson;
        var key_end = key_start + 1;
        while (key_end < input.len) : (key_end += 1) {
            if (input[key_end] == '\\') {
                key_end += 1;
                continue;
            }
            if (input[key_end] == '"') {
                key_end += 1;
                break;
            }
        }
        if (key_end > input.len or input[key_end - 1] != '"') return error.InvalidJson;
        var key_complete = token == .string;
        while (!key_complete) {
            const part = scanner.next() catch |err| return if (err == error.OutOfMemory) error.CapacityExceeded else error.InvalidJson;
            key_complete = switch (part) {
                .string => true,
                .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => false,
                else => return error.InvalidJson,
            };
        }
        const raw_key = Span{ .start = key_start + 1, .end = key_end - 1 };
        const key_offset = document.keys_used;
        try decode_key(input[raw_key.start..raw_key.end], document.keys, &document.keys_used);
        const key_span = Span{ .start = key_offset, .end = document.keys_used };
        var prior: usize = 0;
        while (prior < document.count) : (prior += 1) if (key_equal(document.keys, document.members[prior].key, document.keys, key_span)) return error.DuplicateKey;
        var value_start = key_end;
        while (value_start < input.len and input[value_start] != ':') : (value_start += 1) {}
        if (value_start == input.len) return error.InvalidJson;
        value_start += 1;
        skip_space(input, &value_start);
        const value_token = scanner.next() catch |err| return if (err == error.OutOfMemory) error.CapacityExceeded else error.InvalidJson;
        if (value_token == .object_begin or value_token == .array_begin) try consume_container(&scanner, value_token);
        if (value_token == .partial_string or value_token == .partial_string_escaped_1 or value_token == .partial_string_escaped_2 or value_token == .partial_string_escaped_3 or value_token == .partial_string_escaped_4) try consume_string(&scanner);
        const value_end = scanner.cursor;
        document.members[document.count] = .{ .key = key_span, .value = .{ .start = value_start, .end = value_end } };
        document.count += 1;
    }
    skip_space(input, &scanner.cursor);
    const final_token = scanner.next() catch |err| return if (err == error.OutOfMemory) error.CapacityExceeded else error.InvalidJson;
    if (final_token != .end_of_document) return error.InvalidJson;
}

fn consume_string(scanner: *std.json.Scanner) error{ InvalidJson, CapacityExceeded }!void {
    while (true) {
        const token = scanner.next() catch |err| return if (err == error.OutOfMemory) error.CapacityExceeded else error.InvalidJson;
        switch (token) {
            .string => return,
            .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => {},
            else => return error.InvalidJson,
        }
    }
}

fn consume_container(scanner: *std.json.Scanner, initial: std.json.Token) error{ InvalidJson, CapacityExceeded }!void {
    var depth: usize = 1;
    _ = initial;
    while (depth > 0) {
        const token = scanner.next() catch |err| return if (err == error.OutOfMemory) error.CapacityExceeded else error.InvalidJson;
        switch (token) {
            .object_begin, .array_begin => depth += 1,
            .object_end, .array_end => depth -= 1,
            .end_of_document => return error.InvalidJson,
            else => {},
        }
    }
}

fn skip_space(input: []const u8, cursor: *usize) void {
    while (cursor.* < input.len and (input[cursor.*] == ' ' or input[cursor.*] == '\t' or input[cursor.*] == '\r' or input[cursor.*] == '\n')) : (cursor.* += 1) {}
}

fn decode_key(raw: []const u8, destination: []u8, used: *usize) error{CapacityExceeded}!void {
    var index: usize = 0;
    while (index < raw.len) {
        if (raw[index] != '\\') {
            try push_byte(destination, used, raw[index]);
            index += 1;
            continue;
        }
        index += 1;
        if (index >= raw.len) return error.CapacityExceeded;
        const escape = raw[index];
        index += 1;
        const plain: ?u8 = switch (escape) {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'b' => 8,
            'f' => 12,
            'n' => 10,
            'r' => 13,
            't' => 9,
            else => null,
        };
        if (plain) |byte| {
            try push_byte(destination, used, byte);
            continue;
        }
        if (escape != 'u' or raw.len - index < 4) return error.CapacityExceeded;
        const codepoint = parse_hex4(raw[index .. index + 4]) orelse return error.CapacityExceeded;
        index += 4;
        if (codepoint >= 0xd800 and codepoint <= 0xdbff) {
            if (raw.len - index < 6 or raw[index] != '\\' or raw[index + 1] != 'u') return error.CapacityExceeded;
            const low = parse_hex4(raw[index + 2 .. index + 6]) orelse return error.CapacityExceeded;
            if (low < 0xdc00 or low > 0xdfff) return error.CapacityExceeded;
            index += 6;
            try push_codepoint(destination, used, 0x10000 + (@as(u21, codepoint - 0xd800) << 10) + @as(u21, low - 0xdc00));
        } else if (codepoint >= 0xdc00 and codepoint <= 0xdfff) return error.CapacityExceeded else try push_codepoint(destination, used, codepoint);
    }
}

fn push_byte(destination: []u8, used: *usize, byte: u8) error{CapacityExceeded}!void {
    if (used.* == destination.len) return error.CapacityExceeded;
    destination[used.*] = byte;
    used.* += 1;
}

fn push_codepoint(destination: []u8, used: *usize, codepoint: u21) error{CapacityExceeded}!void {
    var encoded: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &encoded) catch return error.CapacityExceeded;
    if (length > destination.len - used.*) return error.CapacityExceeded;
    @memcpy(destination[used.* .. used.* + length], encoded[0..length]);
    used.* += length;
}

fn parse_hex4(bytes: []const u8) ?u16 {
    if (bytes.len != 4) return null;
    var value: u16 = 0;
    for (bytes) |byte| value = (value << 4) | (switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => return null,
    });
    return value;
}

fn key_equal(left_bytes: []const u8, left: Span, right_bytes: []const u8, right: Span) bool {
    return std.mem.eql(u8, left_bytes[left.start..left.end], right_bytes[right.start..right.end]);
}

fn same_members(base: Document, side: Document) bool {
    if (base.count != side.count) return false;
    for (base.members[0..base.count]) |member| {
        var found = false;
        for (side.members[0..side.count]) |candidate| if (key_equal(base.keys, member.key, side.keys, candidate.key)) {
            found = true;
            break;
        };
        if (!found) return false;
    }
    return true;
}

fn same_order(base: Document, side: Document) bool {
    if (base.count != side.count) return false;
    for (base.members[0..base.count], side.members[0..side.count]) |left_member, right_member| if (!key_equal(base.keys, left_member.key, side.keys, right_member.key)) return false;
    return true;
}

fn same_shell(base: []const u8, side: []const u8, base_doc: Document, side_doc: Document) bool {
    var base_cursor: usize = 0;
    var side_cursor: usize = 0;
    for (base_doc.members[0..base_doc.count], side_doc.members[0..side_doc.count]) |base_member, side_member| {
        const base_gap = base[base_cursor..base_member.value.start];
        const side_gap = side[side_cursor..side_member.value.start];
        if (!std.mem.eql(u8, base_gap, side_gap)) return false;
        base_cursor = base_member.value.end;
        side_cursor = side_member.value.end;
    }
    return std.mem.eql(u8, base[base_cursor..], side[side_cursor..]);
}

fn render(base: []const u8, left: []const u8, right: []const u8, output: []u8, workspace: *Workspace) Error!Outcome {
    var required = base.len;
    for (workspace.base.members[0..workspace.base.count], workspace.left.members[0..workspace.left.count], workspace.right.members[0..workspace.right.count]) |b, l, r| {
        const bv = base[b.value.start..b.value.end];
        const lv = left[l.value.start..l.value.end];
        const rv = right[r.value.start..r.value.end];
        const chosen = choose(bv, lv, rv) orelse return .conflict;
        required = std.math.sub(usize, required, bv.len) catch return error.InvalidWorkspace;
        required = std.math.add(usize, required, chosen.len) catch return error.InvalidWorkspace;
    }
    if (required > output.len) return error.CapacityExceeded;
    var source_cursor: usize = 0;
    var target_cursor: usize = 0;
    for (workspace.base.members[0..workspace.base.count], workspace.left.members[0..workspace.left.count], workspace.right.members[0..workspace.right.count]) |b, l, r| {
        const chosen = choose(base[b.value.start..b.value.end], left[l.value.start..l.value.end], right[r.value.start..r.value.end]).?;
        const gap = base[source_cursor..b.value.start];
        @memcpy(output[target_cursor .. target_cursor + gap.len], gap);
        target_cursor += gap.len;
        @memcpy(output[target_cursor .. target_cursor + chosen.len], chosen);
        target_cursor += chosen.len;
        source_cursor = b.value.end;
    }
    @memcpy(output[target_cursor .. target_cursor + base.len - source_cursor], base[source_cursor..]);
    target_cursor += base.len - source_cursor;
    std.debug.assert(target_cursor == required);
    return .{ .clean = target_cursor };
}

fn choose(base: []const u8, left: []const u8, right: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, left, base)) return right;
    if (std.mem.eql(u8, right, base)) return left;
    if (std.mem.eql(u8, left, right)) return left;
    return null;
}

fn aliases(output: []const u8, input: []const u8) bool {
    if (output.len == 0 or input.len == 0) return false;
    const a = @intFromPtr(output.ptr);
    const b = @intFromPtr(input.ptr);
    return if (a <= b) b - a < output.len else a - b < input.len;
}

test "distinct root fields compose and preserve base bytes" {
    const base = "{\r\n  \"a\": 1,\r\n  \"b\": {\"x\":true}\r\n}";
    const left = "{\r\n  \"a\": 2,\r\n  \"b\": {\"x\":true}\r\n}";
    const right = "{\r\n  \"a\": 1,\r\n  \"b\": {\"x\":false}\r\n}";
    var base_members: [4]Member = undefined;
    var left_members: [4]Member = undefined;
    var right_members: [4]Member = undefined;
    var base_keys: [64]u8 = undefined;
    var left_keys: [64]u8 = undefined;
    var right_keys: [64]u8 = undefined;
    var scanner: [256]u8 = undefined;
    var workspace = Workspace{ .base = .{ .members = &base_members, .keys = &base_keys }, .left = .{ .members = &left_members, .keys = &left_keys }, .right = .{ .members = &right_members, .keys = &right_keys }, .scanner_memory = &scanner };
    var output: [128]u8 = undefined;
    const outcome = try merge(base, left, right, &output, &workspace);
    try std.testing.expectEqualStrings("{\r\n  \"a\": 2,\r\n  \"b\": {\"x\":false}\r\n}", output[0..outcome.clean]);
}

test "exhaustive two-field scalar-map permutations" {
    var bm: [4]Member = undefined;
    var lm: [4]Member = undefined;
    var rm: [4]Member = undefined;
    var bk: [64]u8 = undefined;
    var lk: [64]u8 = undefined;
    var rk: [64]u8 = undefined;
    var stack: [256]u8 = undefined;
    var workspace = Workspace{ .base = .{ .members = &bm, .keys = &bk }, .left = .{ .members = &lm, .keys = &lk }, .right = .{ .members = &rm, .keys = &rk }, .scanner_memory = &stack };
    var base: [64]u8 = undefined;
    var left: [64]u8 = undefined;
    var right: [64]u8 = undefined;
    var output: [64]u8 = undefined;
    var la: usize = 0;
    while (la < 3) : (la += 1) {
        var lb: usize = 0;
        while (lb < 3) : (lb += 1) {
            var ra: usize = 0;
            while (ra < 3) : (ra += 1) {
                var rb: usize = 0;
                while (rb < 3) : (rb += 1) {
                    const b = try std.fmt.bufPrint(&base, "{{\"a\":0,\"b\":0}}", .{});
                    const l = try std.fmt.bufPrint(&left, "{{\"a\":{d},\"b\":{d}}}", .{ la, lb });
                    const r = try std.fmt.bufPrint(&right, "{{\"a\":{d},\"b\":{d}}}", .{ ra, rb });
                    const outcome = try merge(b, l, r, &output, &workspace);
                    const conflict_a = la != 0 and ra != 0 and la != ra;
                    const conflict_b = lb != 0 and rb != 0 and lb != rb;
                    try std.testing.expectEqual(conflict_a or conflict_b, outcome == .conflict);
                    if (outcome == .clean) {
                        const expected_a = if (la == 0) ra else la;
                        const expected_b = if (lb == 0) rb else lb;
                        const expected = try std.fmt.bufPrint(&base, "{{\"a\":{d},\"b\":{d}}}", .{ expected_a, expected_b });
                        try std.testing.expectEqualStrings(expected, output[0..outcome.clean]);
                    }
                }
            }
        }
    }
}

test "competing values conflict without output mutation; identical sides succeed" {
    const base = "{\"a\":1}";
    const left = "{\"a\":2}";
    const right = "{\"a\":3}";
    var bm: [2]Member = undefined;
    var lm: [2]Member = undefined;
    var rm: [2]Member = undefined;
    var bk: [32]u8 = undefined;
    var lk: [32]u8 = undefined;
    var rk: [32]u8 = undefined;
    var stack: [256]u8 = undefined;
    var workspace = Workspace{ .base = .{ .members = &bm, .keys = &bk }, .left = .{ .members = &lm, .keys = &lk }, .right = .{ .members = &rm, .keys = &rk }, .scanner_memory = &stack };
    var output: [32]u8 = @splat(0xa5);
    try std.testing.expect((try merge(base, left, right, &output, &workspace)) == .conflict);
    try std.testing.expectEqual(@as(u8, 0xa5), output[0]);
    const identical = try merge(base, left, left, &output, &workspace);
    try std.testing.expectEqualStrings(left, output[0..identical.clean]);
}

test "decoded escaped duplicate keys and unicode keys are semantic" {
    const base = "{\"a\":1,\"\\u0061\":2}";
    var bm: [4]Member = undefined;
    var lm: [4]Member = undefined;
    var rm: [4]Member = undefined;
    var bk: [32]u8 = undefined;
    var lk: [32]u8 = undefined;
    var rk: [32]u8 = undefined;
    var stack: [256]u8 = undefined;
    var workspace = Workspace{ .base = .{ .members = &bm, .keys = &bk }, .left = .{ .members = &lm, .keys = &lk }, .right = .{ .members = &rm, .keys = &rk }, .scanner_memory = &stack };
    var output: [64]u8 = undefined;
    const result = try merge(base, base, base, &output, &workspace);
    try std.testing.expect(result.degraded == .duplicate_key);
    const unicode = "{\"\\u00e9\":1}";
    const unicode_result = try merge(unicode, unicode, unicode, &output, &workspace);
    try std.testing.expectEqualStrings(unicode, output[0..unicode_result.clean]);
}

test "output alias rejected before bytes change" {
    var shared = [_]u8{ '{', '}', 0xa5, 0xa5 };
    var bm: [2]Member = undefined;
    var lm: [2]Member = undefined;
    var rm: [2]Member = undefined;
    var bk: [16]u8 = undefined;
    var lk: [16]u8 = undefined;
    var rk: [16]u8 = undefined;
    var stack: [256]u8 = undefined;
    var workspace = Workspace{ .base = .{ .members = &bm, .keys = &bk }, .left = .{ .members = &lm, .keys = &lk }, .right = .{ .members = &rm, .keys = &rk }, .scanner_memory = &stack };
    const before = shared;
    try std.testing.expectError(error.AliasedBuffers, merge(shared[0..2], "{}", "{}", shared[1..], &workspace));
    try std.testing.expectEqualSlices(u8, &before, &shared);
    workspace.base.keys = shared[0..2];
    try std.testing.expectError(error.AliasedBuffers, merge("{}", "{}", "{}", shared[1..], &workspace));
    try std.testing.expectEqualSlices(u8, &before, &shared);
}

test "format-only source changes degrade instead of disappearing" {
    var bm: [2]Member = undefined;
    var lm: [2]Member = undefined;
    var rm: [2]Member = undefined;
    var bk: [16]u8 = undefined;
    var lk: [16]u8 = undefined;
    var rk: [16]u8 = undefined;
    var stack: [256]u8 = undefined;
    var workspace = Workspace{ .base = .{ .members = &bm, .keys = &bk }, .left = .{ .members = &lm, .keys = &lk }, .right = .{ .members = &rm, .keys = &rk }, .scanner_memory = &stack };
    var output: [32]u8 = undefined;
    const outcome = try merge("{\"a\":1}", "{ \"a\":1}", "{\"a\":1}", &output, &workspace);
    try std.testing.expect(outcome.degraded == .ambiguous_formatting);
}

test "resource precharge preserves output on exhaustion" {
    var bm: [2]Member = undefined;
    var lm: [2]Member = undefined;
    var rm: [2]Member = undefined;
    var bk: [16]u8 = undefined;
    var lk: [16]u8 = undefined;
    var rk: [16]u8 = undefined;
    var stack: [256]u8 = undefined;
    var workspace = Workspace{ .base = .{ .members = &bm, .keys = &bk }, .left = .{ .members = &lm, .keys = &lk }, .right = .{ .members = &rm, .keys = &rk }, .scanner_memory = &stack, .max_work = 0 };
    var output: [16]u8 = @splat(0xa5);
    const outcome = try merge("{}", "{}", "{}", &output, &workspace);
    try std.testing.expect(outcome.degraded == .resource_limit);
    try std.testing.expectEqual(@as(u8, 0xa5), output[0]);
}

test "partial scanner numbers and escaped strings retain complete source spans" {
    const source = "{\"n\":1234567890123456789012345678901234567890,\"s\":\"escaped \\\\n and unicode \\\\u00e9\"}";
    var bm: [4]Member = undefined;
    var lm: [4]Member = undefined;
    var rm: [4]Member = undefined;
    var bk: [64]u8 = undefined;
    var lk: [64]u8 = undefined;
    var rk: [64]u8 = undefined;
    var stack: [256]u8 = undefined;
    var workspace = Workspace{ .base = .{ .members = &bm, .keys = &bk }, .left = .{ .members = &lm, .keys = &lk }, .right = .{ .members = &rm, .keys = &rk }, .scanner_memory = &stack };
    var output: [256]u8 = undefined;
    const outcome = try merge(source, source, source, &output, &workspace);
    try std.testing.expectEqualStrings(source, output[0..outcome.clean]);
}

test "malformed trailing bytes BOM and capacity fail safely" {
    var bm: [2]Member = undefined;
    var lm: [2]Member = undefined;
    var rm: [2]Member = undefined;
    var bk: [16]u8 = undefined;
    var lk: [16]u8 = undefined;
    var rk: [16]u8 = undefined;
    var stack: [256]u8 = undefined;
    var workspace = Workspace{ .base = .{ .members = &bm, .keys = &bk }, .left = .{ .members = &lm, .keys = &lk }, .right = .{ .members = &rm, .keys = &rk }, .scanner_memory = &stack };
    var output: [16]u8 = @splat(0xa5);
    const malformed = try merge("{\"a\":1}x", "{\"a\":1}x", "{\"a\":1}x", &output, &workspace);
    try std.testing.expect(malformed.degraded == .malformed_json);
    const bom = try merge("\xef\xbb\xbf{}", "\xef\xbb\xbf{}", "\xef\xbb\xbf{}", &output, &workspace);
    try std.testing.expect(bom.degraded == .malformed_json or bom.degraded == .unsupported_root);
    try std.testing.expectError(error.CapacityExceeded, merge("{}", "{}", "{}", output[0..1], &workspace));
    try std.testing.expectEqual(@as(u8, 0xa5), output[0]);
}
