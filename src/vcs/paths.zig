const std = @import("std");

/// Target namespace rules applied by this lexical preflight.
pub const Target = enum {
    posix,
    windows,
};

/// A byte range in the immutable source path, half-open: `[start, end)`.
pub const Span = struct {
    start: usize,
    end: usize,
};

pub const Reason = enum {
    empty_path,
    absolute_path,
    drive_qualified,
    unc_path,
    nul_byte,
    invalid_utf8,
    traversal,
    empty_component,
    forbidden_character,
    trailing_dot_or_space,
    reserved_device_name,
};

pub const Violation = struct {
    reason: Reason,
    span: Span,
};

pub const Result = union(enum) {
    lexically_valid,
    rejected: Violation,
};

/// Checks only repository-relative path spelling.
/// `lexically_valid` does not establish filesystem, collision, symlink, or
/// Unicode-normalization safety; mutation still requires native validation.
pub fn preflight_repository_relative(path: []const u8, target: Target) Result {
    if (path.len == 0) return reject(.empty_path, 0, 0);
    std.debug.assert(path.len > 0);
    if (target == .windows) {
        if (invalid_utf8_span(path)) |span| return .{ .rejected = .{ .reason = .invalid_utf8, .span = span } };
    }
    if (target == .windows and path.len >= 2 and is_separator(path[0], target) and is_separator(path[1], target)) {
        return reject(.unc_path, 0, 2);
    }
    if (is_separator(path[0], target)) return reject(.absolute_path, 0, 1);
    if (target == .windows and is_ascii_letter(path[0]) and path.len >= 2 and path[1] == ':') {
        return reject(.drive_qualified, 0, 2);
    }

    var component_start: usize = 0;
    for (path, 0..) |byte, index| {
        std.debug.assert(component_start <= index and index < path.len);
        if (!is_separator(byte, target)) continue;
        if (component_violation(path, component_start, index, target)) |found| {
            std.debug.assert(component_start <= found.span.start and found.span.end <= index);
            return .{ .rejected = found };
        }
        component_start = index + 1;
    }
    std.debug.assert(component_start <= path.len);
    if (component_violation(path, component_start, path.len, target)) |found| {
        std.debug.assert(component_start <= found.span.start and found.span.end <= path.len);
        return .{ .rejected = found };
    }
    return .lexically_valid;
}

fn invalid_utf8_span(bytes: []const u8) ?Span {
    var start: usize = 0;
    while (start < bytes.len) {
        std.debug.assert(start < bytes.len);
        const byte = bytes[start];
        if (byte <= 0x7f) {
            start += 1;
            continue;
        }
        const sequence = utf8_sequence(byte) orelse return .{ .start = start, .end = start + 1 };
        std.debug.assert(sequence.len >= 2 and sequence.len <= 4);
        std.debug.assert(sequence.first_min <= sequence.first_max);
        if (sequence.len > bytes.len - start) return .{ .start = start, .end = bytes.len };
        if (bytes[start + 1] < sequence.first_min or bytes[start + 1] > sequence.first_max) {
            return .{ .start = start + 1, .end = start + 2 };
        }
        var offset: usize = 2;
        while (offset < sequence.len) : (offset += 1) {
            const continuation_index = start + offset;
            std.debug.assert(continuation_index < bytes.len);
            if (bytes[continuation_index] < 0x80 or bytes[continuation_index] > 0xbf) return .{ .start = continuation_index, .end = continuation_index + 1 };
        }
        start += sequence.len;
    }
    std.debug.assert(start == bytes.len);
    return null;
}

fn utf8_sequence(byte: u8) ?struct { len: usize, first_min: u8, first_max: u8 } {
    return switch (byte) {
        0xc2...0xdf => .{ .len = 2, .first_min = 0x80, .first_max = 0xbf },
        0xe0 => .{ .len = 3, .first_min = 0xa0, .first_max = 0xbf },
        0xe1...0xec, 0xee...0xef => .{ .len = 3, .first_min = 0x80, .first_max = 0xbf },
        0xed => .{ .len = 3, .first_min = 0x80, .first_max = 0x9f },
        0xf0 => .{ .len = 4, .first_min = 0x90, .first_max = 0xbf },
        0xf1...0xf3 => .{ .len = 4, .first_min = 0x80, .first_max = 0xbf },
        0xf4 => .{ .len = 4, .first_min = 0x80, .first_max = 0x8f },
        else => null,
    };
}

fn component_violation(path: []const u8, start: usize, end: usize, target: Target) ?Violation {
    std.debug.assert(start <= end);
    std.debug.assert(end <= path.len);
    if (start == end) return violation(.empty_component, start, end);
    const component = path[start..end];
    std.debug.assert(component.len > 0);
    std.debug.assert(component.len == end - start);
    if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return violation(.traversal, start, end);

    for (component, 0..) |byte, offset| {
        std.debug.assert(offset < component.len);
        std.debug.assert(start + offset < end);
        if (byte == 0) return violation(.nul_byte, start + offset, start + offset + 1);
        if (target == .windows and is_windows_forbidden(byte)) {
            return violation(.forbidden_character, start + offset, start + offset + 1);
        }
    }
    std.debug.assert(component.len - 1 < component.len);
    if (target == .windows and (component[component.len - 1] == '.' or component[component.len - 1] == ' ')) {
        return violation(.trailing_dot_or_space, end - 1, end);
    }
    if (target == .windows) {
        if (reserved_device_prefix_len(component)) |prefix_len| return violation(.reserved_device_name, start, start + prefix_len);
    }
    return null;
}

fn reject(reason: Reason, start: usize, end: usize) Result {
    std.debug.assert(start <= end);
    return .{ .rejected = .{ .reason = reason, .span = .{ .start = start, .end = end } } };
}

fn violation(reason: Reason, start: usize, end: usize) Violation {
    std.debug.assert(start <= end);
    return .{ .reason = reason, .span = .{ .start = start, .end = end } };
}

fn is_separator(byte: u8, target: Target) bool {
    return byte == '/' or (target == .windows and byte == '\\');
}

fn is_ascii_letter(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z');
}

fn is_windows_forbidden(byte: u8) bool {
    return byte < 32 or switch (byte) {
        '<', '>', ':', '"', '/', '\\', '|', '?', '*' => true,
        else => false,
    };
}

fn reserved_device_prefix_len(component: []const u8) ?usize {
    const component_end = trim_windows_suffix(component);
    std.debug.assert(component_end <= component.len);
    const extension_start = std.mem.indexOfScalar(u8, component[0..component_end], '.') orelse component_end;
    std.debug.assert(extension_start <= component_end);
    const base_end = trim_windows_suffix(component[0..extension_start]);
    std.debug.assert(base_end <= extension_start);
    const base = component[0..base_end];
    std.debug.assert(base.len == base_end);
    if (ascii_equal(base, "CON") or ascii_equal(base, "PRN") or ascii_equal(base, "AUX") or ascii_equal(base, "NUL")) return base_end;
    if (ascii_equal(base, "CONIN$") or ascii_equal(base, "CONOUT$")) return base_end;
    if (base.len == 4 and (ascii_equal(base[0..3], "COM") or ascii_equal(base[0..3], "LPT")) and is_ascii_device_digit(base[3])) return base_end;
    if (base.len == 5 and (ascii_equal(base[0..3], "COM") or ascii_equal(base[0..3], "LPT")) and is_superscript_device_digit(base[3..5])) return base_end;
    return null;
}

fn trim_windows_suffix(component: []const u8) usize {
    var end = component.len;
    while (end > 0 and (component[end - 1] == '.' or component[end - 1] == ' ')) end -= 1;
    std.debug.assert(end <= component.len);
    std.debug.assert(end == 0 or (component[end - 1] != '.' and component[end - 1] != ' '));
    return end;
}

fn ascii_equal(actual: []const u8, expected: []const u8) bool {
    if (actual.len != expected.len) return false;
    std.debug.assert(actual.len == expected.len);
    for (actual, expected, 0..) |byte, expected_byte, index| {
        std.debug.assert(index < actual.len);
        if (ascii_upper(byte) != expected_byte) return false;
    }
    return true;
}

fn ascii_upper(byte: u8) u8 {
    if (byte >= 'a' and byte <= 'z') return byte - ('a' - 'A');
    return byte;
}

fn is_ascii_device_digit(byte: u8) bool {
    return byte >= '1' and byte <= '9';
}

fn is_superscript_device_digit(bytes: []const u8) bool {
    return bytes.len == 2 and bytes[0] == 0xc2 and (bytes[1] == 0xb9 or bytes[1] == 0xb2 or bytes[1] == 0xb3);
}

test "repository-relative lexical preflight table" {
    const Case = struct {
        path: []const u8,
        target: Target,
        expected: ?Violation,
    };
    const cases = [_]Case{
        .{ .path = "notes/readme", .target = .posix, .expected = null },
        .{ .path = "notes\\readme", .target = .posix, .expected = null },
        .{ .path = "notes\\readme", .target = .windows, .expected = null },
        .{ .path = "", .target = .posix, .expected = .{ .reason = .empty_path, .span = .{ .start = 0, .end = 0 } } },
        .{ .path = "/etc/passwd", .target = .posix, .expected = .{ .reason = .absolute_path, .span = .{ .start = 0, .end = 1 } } },
        .{ .path = "\\rooted", .target = .windows, .expected = .{ .reason = .absolute_path, .span = .{ .start = 0, .end = 1 } } },
        .{ .path = "//server/share", .target = .windows, .expected = .{ .reason = .unc_path, .span = .{ .start = 0, .end = 2 } } },
        .{ .path = "C:relative", .target = .windows, .expected = .{ .reason = .drive_qualified, .span = .{ .start = 0, .end = 2 } } },
        .{ .path = "a/../b", .target = .posix, .expected = .{ .reason = .traversal, .span = .{ .start = 2, .end = 4 } } },
        .{ .path = "a//b", .target = .posix, .expected = .{ .reason = .empty_component, .span = .{ .start = 2, .end = 2 } } },
        .{ .path = "a/", .target = .windows, .expected = .{ .reason = .empty_component, .span = .{ .start = 2, .end = 2 } } },
        .{ .path = "a\x00b", .target = .posix, .expected = .{ .reason = .nul_byte, .span = .{ .start = 1, .end = 2 } } },
        .{ .path = "\xc0\x80", .target = .windows, .expected = .{ .reason = .invalid_utf8, .span = .{ .start = 0, .end = 1 } } },
        .{ .path = "x\xe2(\xa1", .target = .windows, .expected = .{ .reason = .invalid_utf8, .span = .{ .start = 2, .end = 3 } } },
        .{ .path = "x\xe2\x82", .target = .windows, .expected = .{ .reason = .invalid_utf8, .span = .{ .start = 1, .end = 3 } } },
        .{ .path = "\xff", .target = .posix, .expected = null },
        .{ .path = "x\xc3\xa9", .target = .windows, .expected = null },
        .{ .path = "a?b", .target = .windows, .expected = .{ .reason = .forbidden_character, .span = .{ .start = 1, .end = 2 } } },
        .{ .path = "name. ", .target = .windows, .expected = .{ .reason = .trailing_dot_or_space, .span = .{ .start = 5, .end = 6 } } },
        .{ .path = "aux.log", .target = .windows, .expected = .{ .reason = .reserved_device_name, .span = .{ .start = 0, .end = 3 } } },
        .{ .path = "NUL .txt", .target = .windows, .expected = .{ .reason = .reserved_device_name, .span = .{ .start = 0, .end = 3 } } },
        .{ .path = "CONIN$.txt", .target = .windows, .expected = .{ .reason = .reserved_device_name, .span = .{ .start = 0, .end = 6 } } },
        .{ .path = "dir/CONOUT$", .target = .windows, .expected = .{ .reason = .reserved_device_name, .span = .{ .start = 4, .end = 11 } } },
        .{ .path = "dir/NuL.txt", .target = .windows, .expected = .{ .reason = .reserved_device_name, .span = .{ .start = 4, .end = 7 } } },
        .{ .path = "COM\xc2\xb9.txt", .target = .windows, .expected = .{ .reason = .reserved_device_name, .span = .{ .start = 0, .end = 5 } } },
        .{ .path = "COM\xc2\xb4.txt", .target = .windows, .expected = null },
    };

    for (cases) |case| {
        const original = case.path;
        const result = preflight_repository_relative(case.path, case.target);
        try std.testing.expectEqualSlices(u8, original, case.path);
        if (case.expected) |expected| {
            try expect_rejected(result, expected);
        } else {
            try std.testing.expectEqual(Result.lexically_valid, result);
        }
    }
}

test "all Windows device digits and deterministic generated names are rejected or lexically valid" {
    var digit: u8 = '1';
    while (digit <= '9') : (digit += 1) {
        const com = [8]u8{ 'C', 'o', 'M', digit, '.', 't', 'x', 't' };
        const lpt = [8]u8{ 'l', 'P', 't', digit, '.', 't', 'x', 't' };
        try expect_rejected(preflight_repository_relative(&com, .windows), .{ .reason = .reserved_device_name, .span = .{ .start = 0, .end = 4 } });
        try expect_rejected(preflight_repository_relative(&lpt, .windows), .{ .reason = .reserved_device_name, .span = .{ .start = 0, .end = 4 } });
    }

    var state: u32 = 0x5eed_1234;
    var iteration: usize = 0;
    while (iteration < 256) : (iteration += 1) {
        state = state *% 1664525 +% 1013904223;
        var name = [4]u8{ 'a', 'a', 'a', 'a' };
        for (&name, 0..) |*byte, index| byte.* = 'a' + @as(u8, @truncate(state >> @intCast(index * 5))) % 26;
        const original = name;
        try std.testing.expectEqual(Result.lexically_valid, preflight_repository_relative(&name, .windows));
        try std.testing.expectEqualSlices(u8, &original, &name);
        name[2] = '?';
        try expect_rejected(preflight_repository_relative(&name, .windows), .{ .reason = .forbidden_character, .span = .{ .start = 2, .end = 3 } });
        try std.testing.expectEqual(Result.lexically_valid, preflight_repository_relative(&name, .posix));
    }
}

test "Windows generated component ranges accept names and reject every forbidden byte" {
    var name: [32]u8 = undefined;
    var length: usize = 1;
    while (length <= name.len) : (length += 1) {
        for (name[0..length], 0..) |*byte, index| byte.* = 'a' + @as(u8, @intCast(index % 26));
        const original = name;
        try std.testing.expectEqual(Result.lexically_valid, preflight_repository_relative(original[0..length], .windows));

        var offset: usize = 0;
        while (offset < length) : (offset += 1) {
            name[offset] = '?';
            try expect_rejected(preflight_repository_relative(name[0..length], .windows), .{
                .reason = .forbidden_character,
                .span = .{ .start = offset, .end = offset + 1 },
            });
            name[offset] = original[offset];
        }
        try std.testing.expectEqualSlices(u8, original[0..length], name[0..length]);
    }
}

fn expect_rejected(result: Result, expected: Violation) !void {
    switch (result) {
        .lexically_valid => return error.ExpectedRejectedPath,
        .rejected => |actual| {
            try std.testing.expectEqual(expected.reason, actual.reason);
            try std.testing.expectEqual(expected.span.start, actual.span.start);
            try std.testing.expectEqual(expected.span.end, actual.span.end);
        },
    }
}
