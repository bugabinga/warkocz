const std = @import("std");

/// Half-open byte range in an immutable merge input.
pub const ByteRange = struct {
    start: usize,
    end: usize,
};

/// Origin of an automatically produced result.
pub const Origin = enum {
    unchanged,
    left,
    right,
    identical,
    composed,
};

/// A single source edit used by a clean result.
pub const EditRange = struct {
    origin: Origin,
    base: ByteRange,
    source: ByteRange,
};

/// Caller-owned destination details and automatic-resolution provenance.
pub const Result = struct {
    origin: Origin,
    reviewed: bool = false,
    written: usize,
    edits: [2]EditRange,
    edit_count: u2,
};

/// Smallest base envelope and exact source edits requiring manual resolution.
pub const Conflict = struct {
    base: ByteRange,
    left: ByteRange,
    right: ByteRange,
};

pub const Outcome = union(enum) {
    clean: Result,
    conflict: Conflict,
};

pub const MergeError = error{
    DestinationAliased,
    DestinationTooSmall,
    OutputTooLarge,
};

const Edit = struct {
    base: ByteRange,
    replacement: []const u8,
    source: ByteRange,
};

/// Merges one whole-file contiguous edit per side without allocation.
/// Conflicts and errors leave destination bytes unchanged.
pub fn merge(base: []const u8, left: []const u8, right: []const u8, destination: []u8) MergeError!Outcome {
    if (aliases_input(destination, base) or aliases_input(destination, left) or aliases_input(destination, right)) {
        return error.DestinationAliased;
    }
    if (std.mem.eql(u8, left, base) and std.mem.eql(u8, right, base)) {
        return write_single(base, .unchanged, null, destination);
    }
    if (std.mem.eql(u8, left, base)) return write_single(right, .right, edit_for(base, right), destination);
    if (std.mem.eql(u8, right, base)) return write_single(left, .left, edit_for(base, left), destination);
    if (std.mem.eql(u8, left, right)) return write_single(left, .identical, edit_for(base, left), destination);

    const left_edit = edit_for(base, left);
    const right_edit = edit_for(base, right);
    if (edits_conflict(left_edit, right_edit) or
        edit_is_ambiguous(base, left, left_edit) or
        edit_is_ambiguous(base, right, right_edit))
    {
        return .{ .conflict = .{
            .base = conflict_range(left_edit.base, right_edit.base),
            .left = left_edit.source,
            .right = right_edit.source,
        } };
    }
    return write_composed(base, left_edit, right_edit, destination);
}

fn aliases_input(destination: []u8, input: []const u8) bool {
    if (destination.len == 0 or input.len == 0) return false;
    const destination_start = @intFromPtr(destination.ptr);
    const input_start = @intFromPtr(input.ptr);
    std.debug.assert(destination_start != 0);
    std.debug.assert(input_start != 0);
    if (destination_start <= input_start) return input_start - destination_start < destination.len;
    return destination_start - input_start < input.len;
}

fn edit_for(base: []const u8, version: []const u8) Edit {
    var prefix: usize = 0;
    while (prefix < base.len and prefix < version.len and base[prefix] == version[prefix]) : (prefix += 1) {}

    var suffix: usize = 0;
    while (suffix < base.len - prefix and suffix < version.len - prefix and
        base[base.len - suffix - 1] == version[version.len - suffix - 1]) : (suffix += 1)
    {}
    std.debug.assert(prefix + suffix <= base.len);
    std.debug.assert(prefix + suffix <= version.len);
    return .{
        .base = .{ .start = prefix, .end = base.len - suffix },
        .replacement = version[prefix .. version.len - suffix],
        .source = .{ .start = prefix, .end = version.len - suffix },
    };
}

fn edits_conflict(left: Edit, right: Edit) bool {
    const left_insertion = left.base.start == left.base.end;
    const right_insertion = right.base.start == right.base.end;
    std.debug.assert(left.base.start <= left.base.end);
    std.debug.assert(right.base.start <= right.base.end);
    if (left_insertion and right_insertion) return left.base.start == right.base.start;
    if (left_insertion) return right.base.start < left.base.start and left.base.start < right.base.end;
    if (right_insertion) return left.base.start < right.base.start and right.base.start < left.base.end;
    return left.base.start < right.base.end and right.base.start < left.base.end;
}

fn edit_is_ambiguous(base: []const u8, version: []const u8, edit: Edit) bool {
    const prefix = edit.base.start;
    const suffix = base.len - edit.base.end;
    std.debug.assert(prefix <= base.len);
    std.debug.assert(suffix <= base.len - prefix);
    // Any alternative minimal alignment extends the existing matching suffix.
    // Its first extra byte must match; shifting one byte is then sufficient.
    // Checking every longer suffix would rescan unchanged text quadratically.
    if (prefix == 0) return false;
    std.debug.assert(edit.base.end > 0 and edit.source.end > 0);
    std.debug.assert(edit.source.end <= version.len);
    return base[edit.base.end - 1] == version[edit.source.end - 1];
}

fn conflict_range(left: ByteRange, right: ByteRange) ByteRange {
    std.debug.assert(left.start <= left.end);
    std.debug.assert(right.start <= right.end);
    return .{
        .start = @min(left.start, right.start),
        .end = @max(left.end, right.end),
    };
}

fn write_single(bytes: []const u8, origin: Origin, edit: ?Edit, destination: []u8) MergeError!Outcome {
    if (bytes.len > destination.len) return error.DestinationTooSmall;
    std.debug.assert(bytes.len <= destination.len);
    std.mem.copyForwards(u8, destination[0..bytes.len], bytes);
    const empty_edit = EditRange{
        .origin = .unchanged,
        .base = .{ .start = 0, .end = 0 },
        .source = .{ .start = 0, .end = 0 },
    };
    var result = Result{
        .origin = origin,
        .written = bytes.len,
        .edits = .{ empty_edit, empty_edit },
        .edit_count = 0,
    };
    if (edit) |change| {
        result.edits[0] = .{ .origin = origin, .base = change.base, .source = change.source };
        result.edit_count = 1;
    }
    return .{ .clean = result };
}

fn write_composed(base: []const u8, left: Edit, right: Edit, destination: []u8) MergeError!Outcome {
    const first_is_left = left.base.start < right.base.start or
        (left.base.start == right.base.start and left.base.start == left.base.end);
    const first = if (first_is_left) left else right;
    const second = if (first_is_left) right else left;
    const required = try composed_length(base.len, first, second);
    if (required > destination.len) return error.DestinationTooSmall;
    std.debug.assert(first.base.end <= second.base.start);
    std.debug.assert(required <= destination.len);
    var written: usize = 0;
    copy_part(destination, &written, base[0..first.base.start]);
    copy_part(destination, &written, first.replacement);
    copy_part(destination, &written, base[first.base.end..second.base.start]);
    copy_part(destination, &written, second.replacement);
    copy_part(destination, &written, base[second.base.end..]);
    std.debug.assert(written == required);
    return .{ .clean = .{
        .origin = .composed,
        .written = written,
        .edits = .{
            .{ .origin = if (first_is_left) .left else .right, .base = first.base, .source = first.source },
            .{ .origin = if (first_is_left) .right else .left, .base = second.base, .source = second.source },
        },
        .edit_count = 2,
    } };
}

fn composed_length(base_length: usize, first: Edit, second: Edit) MergeError!usize {
    std.debug.assert(first.base.start <= first.base.end);
    std.debug.assert(second.base.start <= second.base.end);
    const removed = std.math.add(usize, first.base.end - first.base.start, second.base.end - second.base.start) catch return error.OutputTooLarge;
    const retained = base_length - removed;
    const replacements = std.math.add(usize, first.replacement.len, second.replacement.len) catch return error.OutputTooLarge;
    return std.math.add(usize, retained, replacements) catch error.OutputTooLarge;
}

fn copy_part(destination: []u8, written: *usize, source: []const u8) void {
    std.debug.assert(written.* <= destination.len);
    std.debug.assert(source.len <= destination.len - written.*);
    std.mem.copyForwards(u8, destination[written.* .. written.* + source.len], source);
    written.* += source.len;
    std.debug.assert(written.* <= destination.len);
}

test "preserves arbitrary bytes, BOM, and mixed newlines" {
    const base = "\xef\xbb\xbfzero\r\none\ntwo\r\n\x00\xff\x80";
    const left = "\xef\xbb\xbfzero\r\nLEFT\ntwo\r\n\x00\xff\x80";
    const right = "\xef\xbb\xbfzero\r\none\nTWO\r\n\x00\xff\x80";
    var destination: [64]u8 = undefined;
    const outcome = try merge(base, left, right, &destination);
    try std.testing.expectEqual(Origin.composed, outcome.clean.origin);
    try std.testing.expectEqualStrings("\xef\xbb\xbfzero\r\nLEFT\nTWO\r\n\x00\xff\x80", destination[0..outcome.clean.written]);
}

test "classifies unchanged, one-sided, and identical changes" {
    var destination: [32]u8 = undefined;
    var outcome = try merge("abc", "abc", "abc", &destination);
    try std.testing.expectEqual(Origin.unchanged, outcome.clean.origin);
    try std.testing.expectEqual(@as(u2, 0), outcome.clean.edit_count);
    outcome = try merge("abc", "axc", "abc", &destination);
    try std.testing.expectEqual(Origin.left, outcome.clean.origin);
    try std.testing.expectEqualStrings("axc", destination[0..outcome.clean.written]);
    outcome = try merge("abc", "axc", "axc", &destination);
    try std.testing.expectEqual(Origin.identical, outcome.clean.origin);
    try std.testing.expectEqual(@as(u2, 1), outcome.clean.edit_count);
}

test "combines adjacency, insertion, deletion, and edit" {
    var destination: [32]u8 = undefined;
    var outcome = try merge("abcd", "aXcd", "abcY", &destination);
    try std.testing.expectEqualStrings("aXcY", destination[0..outcome.clean.written]);
    outcome = try merge("abcd", "aXbcd", "acd", &destination);
    try std.testing.expectEqualStrings("aXcd", destination[0..outcome.clean.written]);
}

test "repeated sequences use bounded prefix and suffix edits" {
    var destination: [32]u8 = undefined;
    const outcome = try merge("ababab", "abXab", "ababYb", &destination);
    try std.testing.expectEqual(Origin.composed, outcome.clean.origin);
    try std.testing.expectEqualStrings("abXYb", destination[0..outcome.clean.written]);
}

test "reports whole conflict envelope and provenance without writing" {
    var destination: [16]u8 = @splat(0xaa);
    const expected: [16]u8 = @splat(0xaa);
    const outcome = try merge("abcdef", "aXef", "abYf", &destination);
    try std.testing.expectEqual(ByteRange{ .start = 1, .end = 5 }, outcome.conflict.base);
    try std.testing.expectEqual(ByteRange{ .start = 1, .end = 2 }, outcome.conflict.left);
    try std.testing.expectEqual(ByteRange{ .start = 2, .end = 3 }, outcome.conflict.right);
    try std.testing.expectEqualSlices(u8, &expected, &destination);
}

test "same-position insertions conflict and capacity preserves destination" {
    var destination: [4]u8 = @splat(0xcc);
    const expected: [4]u8 = @splat(0xcc);
    const insertion_conflict = try merge("ab", "aLb", "aRb", &destination);
    try std.testing.expectEqual(ByteRange{ .start = 1, .end = 1 }, insertion_conflict.conflict.base);
    try std.testing.expectEqualSlices(u8, &expected, &destination);
    try std.testing.expectError(error.DestinationTooSmall, merge("a", "longer", "a", &destination));
    try std.testing.expectEqualSlices(u8, &expected, &destination);
}

test "empty distinct insertions conflict symmetrically" {
    var destination: [4]u8 = @splat(0xee);
    const expected: [4]u8 = @splat(0xee);
    var outcome = try merge("", "L", "R", &destination);
    try std.testing.expectEqual(ByteRange{ .start = 0, .end = 0 }, outcome.conflict.base);
    try std.testing.expectEqual(ByteRange{ .start = 0, .end = 1 }, outcome.conflict.left);
    try std.testing.expectEqual(ByteRange{ .start = 0, .end = 1 }, outcome.conflict.right);
    outcome = try merge("", "R", "L", &destination);
    try std.testing.expectEqual(ByteRange{ .start = 0, .end = 0 }, outcome.conflict.base);
    try std.testing.expectEqualSlices(u8, &expected, &destination);
}

test "input alias is rejected without writing" {
    var storage = [_]u8{ 'a', 'b', 'c', 'd', 'e', 'f' };
    try std.testing.expectError(error.DestinationAliased, merge(storage[0..3], "axc", "abc", storage[1..4]));
    try std.testing.expectEqualStrings("abcdef", &storage);
}

test "rejects ambiguous repeated-byte composition" {
    var destination: [8]u8 = @splat(0xdd);
    const expected: [8]u8 = @splat(0xdd);
    const outcome = try merge("aaaa", "aaa", "aXaaa", &destination);
    try std.testing.expectEqual(ByteRange{ .start = 1, .end = 4 }, outcome.conflict.base);
    try std.testing.expectEqual(ByteRange{ .start = 3, .end = 3 }, outcome.conflict.left);
    try std.testing.expectEqual(ByteRange{ .start = 1, .end = 2 }, outcome.conflict.right);
    try std.testing.expectEqualSlices(u8, &expected, &destination);
}

test "shared-start insertion precedes replacement symmetrically" {
    var destination: [16]u8 = undefined;
    var outcome = try merge("abcd", "acd", "aXbcd", &destination);
    try std.testing.expectEqual(Origin.composed, outcome.clean.origin);
    try std.testing.expectEqual(Origin.right, outcome.clean.edits[0].origin);
    try std.testing.expectEqualStrings("aXcd", destination[0..outcome.clean.written]);
    outcome = try merge("abcd", "aXbcd", "acd", &destination);
    try std.testing.expectEqual(Origin.composed, outcome.clean.origin);
    try std.testing.expectEqual(Origin.left, outcome.clean.edits[0].origin);
    try std.testing.expectEqualStrings("aXcd", destination[0..outcome.clean.written]);
}

test "generated independent replacements retain side-order symmetry" {
    var destination: [64]u8 = undefined;
    var swapped_destination: [64]u8 = undefined;
    var state: u32 = 0x6d2b79f5;
    var index: usize = 0;
    while (index < 128) : (index += 1) {
        state = state *% 1664525 +% 1013904223;
        const left_byte: u8 = @intCast('A' + (state % 26));
        state = state *% 1664525 +% 1013904223;
        const right_byte: u8 = @intCast('a' + (state % 26));
        const left = [_]u8{ '0', left_byte, '2', '3' };
        const right = [_]u8{ '0', '1', '2', right_byte };
        const outcome = try merge("0123", &left, &right, &destination);
        const swapped = try merge("0123", &right, &left, &swapped_destination);
        try std.testing.expectEqual(Origin.composed, outcome.clean.origin);
        try std.testing.expectEqual(Origin.composed, swapped.clean.origin);
        try std.testing.expectEqualSlices(u8, destination[0..outcome.clean.written], swapped_destination[0..swapped.clean.written]);
        try std.testing.expectEqualSlices(u8, &[_]u8{ '0', left_byte, '2', right_byte }, destination[0..outcome.clean.written]);
    }
}

test "ambiguity predicate matches exhaustive minimal alignments" {
    var base_buffer: [5]u8 = undefined;
    var version_buffer: [5]u8 = undefined;
    for (0..6) |base_len| {
        for (0..(@as(usize, 1) << @intCast(base_len))) |base_bits| {
            for (base_buffer[0..base_len], 0..) |*byte, index| byte.* = 'a' + @as(u8, @intCast((base_bits >> @intCast(index)) & 1));
            const base = base_buffer[0..base_len];
            for (0..6) |version_len| {
                for (0..(@as(usize, 1) << @intCast(version_len))) |version_bits| {
                    for (version_buffer[0..version_len], 0..) |*byte, index| byte.* = 'a' + @as(u8, @intCast((version_bits >> @intCast(index)) & 1));
                    const version = version_buffer[0..version_len];
                    const edit = edit_for(base, version);
                    const retained = edit.base.start + base.len - edit.base.end;
                    var alternatives: usize = 0;
                    for (0..edit.base.start) |prefix| {
                        const suffix = retained - prefix;
                        if (std.mem.eql(u8, base[base.len - suffix ..], version[version.len - suffix ..])) alternatives += 1;
                    }
                    try std.testing.expectEqual(alternatives > 0, edit_is_ambiguous(base, version, edit));
                }
            }
        }
    }
}

test "empty, adjacent, deletion, and end changes compose symmetrically" {
    const Case = struct { base: []const u8, left: []const u8, right: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .base = "", .left = "", .right = "", .expected = "" },
        .{ .base = "", .left = "X", .right = "", .expected = "X" },
        .{ .base = "abcd", .left = "aXcd", .right = "abYd", .expected = "aXYd" },
        .{ .base = "abcd", .left = "bcd", .right = "abXcd", .expected = "bXcd" },
        .{ .base = "abcd", .left = "ad", .right = "abcY", .expected = "aY" },
        .{ .base = "abcd", .left = "abc", .right = "abcdY", .expected = "abcY" },
    };
    for (cases) |case| {
        var destination: [16]u8 = undefined;
        var swapped_destination: [16]u8 = undefined;
        const outcome = try merge(case.base, case.left, case.right, &destination);
        const swapped = try merge(case.base, case.right, case.left, &swapped_destination);
        try std.testing.expectEqualSlices(u8, case.expected, destination[0..outcome.clean.written]);
        try std.testing.expectEqualSlices(u8, case.expected, swapped_destination[0..swapped.clean.written]);
    }
}
