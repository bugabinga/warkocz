const std = @import("std");

/// A source-byte replacement. Edits are applied in input order.
pub const Edit = struct {
    start: usize,
    end: usize,
    replacement: []const u8,
};

pub const ApplyError = error{
    InvalidEditRange,
    UnsortedOrOverlappingEdits,
    OutputTooSmall,
    ArithmeticOverflow,
    AliasedBuffers,
};

/// Applies sorted, non-overlapping source-byte edits into caller-owned storage.
/// Empty edits at one offset are allowed and emitted in input order.
/// Source, replacement, and edit-descriptor storage must not overlap destination.
pub fn apply(source: []const u8, edits: []const Edit, destination: []u8) ApplyError![]u8 {
    const output_len = try validate_edits(source, edits);
    if (output_len > destination.len) return error.OutputTooSmall;
    if (slices_overlap(source, destination)) return error.AliasedBuffers;
    if (slices_overlap(std.mem.sliceAsBytes(edits), destination)) return error.AliasedBuffers;
    for (edits) |edit| {
        if (slices_overlap(edit.replacement, destination)) return error.AliasedBuffers;
    }

    var source_offset: usize = 0;
    var destination_offset: usize = 0;
    for (edits) |edit| {
        std.debug.assert(source_offset <= edit.start);
        std.debug.assert(edit.start <= edit.end and edit.end <= source.len);
        std.debug.assert(destination_offset <= output_len);
        destination_offset = copy(destination, destination_offset, source[source_offset..edit.start]);
        destination_offset = copy(destination, destination_offset, edit.replacement);
        source_offset = edit.end;
    }
    std.debug.assert(source_offset <= source.len);
    destination_offset = copy(destination, destination_offset, source[source_offset..]);
    std.debug.assert(destination_offset == output_len);
    std.debug.assert(output_len <= destination.len);
    return destination[0..destination_offset];
}

fn validate_edits(source: []const u8, edits: []const Edit) ApplyError!usize {
    var output_len = source.len;
    var previous_end: usize = 0;
    var index: usize = 0;
    while (index < edits.len) : (index += 1) {
        std.debug.assert(previous_end <= source.len);
        std.debug.assert(output_len >= source.len - previous_end);
        const edit = edits[index];
        if (edit.start > edit.end or edit.end > source.len) return error.InvalidEditRange;
        if (index > 0 and edit.start < previous_end) return error.UnsortedOrOverlappingEdits;
        const removed_len = edit.end - edit.start;
        output_len = std.math.sub(usize, output_len, removed_len) catch return error.ArithmeticOverflow;
        output_len = std.math.add(usize, output_len, edit.replacement.len) catch return error.ArithmeticOverflow;
        previous_end = edit.end;
    }
    std.debug.assert(previous_end <= source.len);
    std.debug.assert(output_len >= source.len - previous_end);
    return output_len;
}

fn copy(destination: []u8, offset: usize, input: []const u8) usize {
    std.debug.assert(offset <= destination.len);
    std.debug.assert(input.len <= destination.len - offset);
    const end = offset + input.len;
    @memcpy(destination[offset..end], input);
    std.debug.assert(offset <= end and end <= destination.len);
    return end;
}

fn slices_overlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch return true;
    const right_end = std.math.add(usize, right_start, right.len) catch return true;
    std.debug.assert(left_start < left_end);
    std.debug.assert(right_start < right_end);
    return left_start < right_end and right_start < left_end;
}

pub const Bom = enum {
    none,
    utf8,
    utf16_little_endian,
    utf16_big_endian,
    utf32_little_endian,
    utf32_big_endian,
};

/// UTF-16 and UTF-32 BOMs are detected but not decoded or otherwise interpreted.
pub const Encoding = enum {
    byte_stream,
    utf8_bom,
    unsupported_utf16_little_endian,
    unsupported_utf16_big_endian,
    unsupported_utf32_little_endian,
    unsupported_utf32_big_endian,
};

pub const NewlineCounts = struct {
    lf: usize = 0,
    cr: usize = 0,
    crlf: usize = 0,
};

pub const Format = struct {
    bom: Bom,
    encoding: Encoding,
    utf8_valid: bool,
    newlines: NewlineCounts,
    has_final_newline: bool,
};

/// Inspects raw bytes without decoding, normalization, or allocation.
pub fn inspect(bytes: []const u8) Format {
    var newlines = NewlineCounts{};
    var index: usize = 0;
    while (index < bytes.len) {
        std.debug.assert(index < bytes.len);
        if (bytes[index] == '\r') {
            if (index + 1 < bytes.len and bytes[index + 1] == '\n') {
                newlines.crlf += 1;
                index += 2;
                continue;
            }
            newlines.cr += 1;
        } else if (bytes[index] == '\n') {
            newlines.lf += 1;
        }
        index += 1;
    }
    std.debug.assert(index == bytes.len);
    std.debug.assert(newlines.crlf <= bytes.len / 2);
    std.debug.assert(newlines.lf + newlines.cr + 2 * newlines.crlf <= bytes.len);
    const bom = detect_bom(bytes);
    return .{
        .bom = bom,
        .encoding = encoding_for_bom(bom),
        .utf8_valid = std.unicode.utf8ValidateSlice(bytes),
        .newlines = newlines,
        .has_final_newline = bytes.len > 0 and (bytes[bytes.len - 1] == '\r' or bytes[bytes.len - 1] == '\n'),
    };
}

fn detect_bom(bytes: []const u8) Bom {
    if (std.mem.startsWith(u8, bytes, "\xff\xfe\x00\x00")) return .utf32_little_endian;
    if (std.mem.startsWith(u8, bytes, "\x00\x00\xfe\xff")) return .utf32_big_endian;
    if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) return .utf8;
    if (std.mem.startsWith(u8, bytes, "\xff\xfe")) return .utf16_little_endian;
    if (std.mem.startsWith(u8, bytes, "\xfe\xff")) return .utf16_big_endian;
    return .none;
}

fn encoding_for_bom(bom: Bom) Encoding {
    return switch (bom) {
        .none => .byte_stream,
        .utf8 => .utf8_bom,
        .utf16_little_endian => .unsupported_utf16_little_endian,
        .utf16_big_endian => .unsupported_utf16_big_endian,
        .utf32_little_endian => .unsupported_utf32_little_endian,
        .utf32_big_endian => .unsupported_utf32_big_endian,
    };
}

pub const LineSpan = struct {
    start: usize,
    content_end: usize,
    end: usize,
};

/// Iterates exact source spans. `bytes[span.start..span.end]` includes terminators.
pub const LineIterator = struct {
    bytes: []const u8,
    next_offset: usize = 0,

    pub fn init(bytes: []const u8) LineIterator {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *LineIterator) ?LineSpan {
        std.debug.assert(self.next_offset <= self.bytes.len);
        if (self.next_offset == self.bytes.len) return null;
        const start = self.next_offset;
        var index = start;
        while (index < self.bytes.len and self.bytes[index] != '\r' and self.bytes[index] != '\n') : (index += 1) {}
        const content_end = index;
        if (index < self.bytes.len and self.bytes[index] == '\r' and index + 1 < self.bytes.len and self.bytes[index + 1] == '\n') index += 2 else if (index < self.bytes.len) index += 1;
        self.next_offset = index;
        std.debug.assert(start <= content_end);
        std.debug.assert(content_end <= self.next_offset and self.next_offset <= self.bytes.len);
        std.debug.assert(self.next_offset > start);
        return .{ .start = start, .content_end = content_end, .end = index };
    }
};

test "apply preserves untouched bytes and insertion order" {
    const source = "ab\r\ncd";
    const edits = [_]Edit{
        .{ .start = 1, .end = 1, .replacement = "X" },
        .{ .start = 1, .end = 1, .replacement = "Y" },
        .{ .start = 4, .end = 6, .replacement = "!" },
    };
    var destination: [16]u8 = undefined;
    const actual = try apply(source, &edits, &destination);
    try std.testing.expectEqualStrings("aXYb\r\n!", actual);
}

test "apply failures leave destination unchanged" {
    const source = "abcd";
    const invalid = [_]Edit{.{ .start = 3, .end = 2, .replacement = "x" }};
    var destination = [_]u8{ 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5 };
    try std.testing.expectError(error.InvalidEditRange, apply(source, &invalid, &destination));
    try std.testing.expectEqualSlices(u8, &([_]u8{ 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5 }), &destination);

    const too_large = [_]Edit{.{ .start = 0, .end = 0, .replacement = "123456" }};
    try std.testing.expectError(error.OutputTooSmall, apply(source, &too_large, destination[0..4]));
    try std.testing.expectEqualSlices(u8, &([_]u8{ 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5 }), &destination);
}

test "apply rejects disorder, overlap, and aliasing without writes" {
    const source = "abcd";
    const unordered = [_]Edit{ .{ .start = 3, .end = 4, .replacement = "x" }, .{ .start = 1, .end = 2, .replacement = "y" } };
    const overlapping = [_]Edit{ .{ .start = 1, .end = 3, .replacement = "x" }, .{ .start = 2, .end = 4, .replacement = "y" } };
    var destination: [8]u8 = .{ 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5 };
    const destination_before = destination;
    try std.testing.expectError(error.UnsortedOrOverlappingEdits, apply(source, &unordered, &destination));
    try std.testing.expectEqualSlices(u8, &destination_before, &destination);
    try std.testing.expectError(error.UnsortedOrOverlappingEdits, apply(source, &overlapping, &destination));
    try std.testing.expectEqualSlices(u8, &destination_before, &destination);

    var shared = [_]u8{ 'a', 'b', 'c', 'd', 0xa5, 0xa5, 0xa5, 0xa5 };
    const shared_before = shared;
    try std.testing.expectError(error.AliasedBuffers, apply(shared[0..4], &.{}, shared[2..]));
    try std.testing.expectEqualSlices(u8, shared_before[2..], shared[2..]);
}

test "apply rejects replacement and descriptor aliases without writes" {
    const source = "abcd";
    var destination = [_]u8{ 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5 };
    const destination_before = destination;
    const replacement_alias = [_]Edit{.{ .start = 1, .end = 2, .replacement = destination[2..4] }};
    try std.testing.expectError(error.AliasedBuffers, apply(source, &replacement_alias, &destination));
    try std.testing.expectEqualSlices(u8, &destination_before, &destination);

    var descriptor_alias = [_]Edit{.{ .start = 1, .end = 2, .replacement = "X" }};
    const descriptor_bytes = std.mem.sliceAsBytes(descriptor_alias[0..]);
    var descriptor_before: [@sizeOf(Edit)]u8 = undefined;
    @memcpy(descriptor_before[0..], descriptor_bytes);
    try std.testing.expectError(error.AliasedBuffers, apply(source, &descriptor_alias, descriptor_bytes));
    try std.testing.expectEqualSlices(u8, descriptor_before[0..], descriptor_bytes);
}

test "apply handles empty input and exact destination capacity" {
    var empty_destination: [0]u8 = .{};
    const empty = try apply("", &.{}, &empty_destination);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const insertion = [_]Edit{.{ .start = 0, .end = 0, .replacement = "xy" }};
    var inserted_destination: [2]u8 = undefined;
    try std.testing.expectEqualStrings("xy", try apply("", &insertion, &inserted_destination));

    const deletion = [_]Edit{.{ .start = 0, .end = 4, .replacement = "" }};
    try std.testing.expectEqual(@as(usize, 0), (try apply("abcd", &deletion, &empty_destination)).len);

    const source = "abcd";
    const edits = [_]Edit{
        .{ .start = 1, .end = 2, .replacement = "XY" },
        .{ .start = 3, .end = 4, .replacement = "!" },
    };
    var destination: [5]u8 = undefined;
    const actual = try apply(source, &edits, &destination);
    try std.testing.expectEqual(destination.len, actual.len);
    try std.testing.expectEqualStrings("aXYc!", actual);
}

test "apply generated multiple edits preserve byte partitions" {
    var source_memory: [32]u8 = undefined;
    for (&source_memory, 0..) |*byte, index| byte.* = @intCast(index);

    var state: u32 = 0x6d2b_79f5;
    var iteration: usize = 0;
    while (iteration < 256) : (iteration += 1) {
        state = state *% 1664525 +% 1013904223;
        const random: usize = @intCast(state);
        const source_len = 1 + random % source_memory.len;
        const first_start = (random >> 5) % (source_len + 1);
        const first_end = first_start + (random >> 10) % (source_len - first_start + 1);
        const second_start = first_end + (random >> 15) % (source_len - first_end + 1);
        const second_end = second_start + (random >> 20) % (source_len - second_start + 1);
        const first_replacement = "XYZ"[0 .. (random >> 25) % 4];
        const second_replacement = "pq"[0 .. (random >> 28) % 3];
        const edits = [_]Edit{
            .{ .start = first_start, .end = first_end, .replacement = first_replacement },
            .{ .start = second_start, .end = second_end, .replacement = second_replacement },
        };
        var destination: [40]u8 = undefined;
        const actual = try apply(source_memory[0..source_len], &edits, &destination);
        const middle_start = first_start + first_replacement.len;
        const second_output_start = middle_start + second_start - first_end;
        try std.testing.expectEqual(source_len - (first_end - first_start) - (second_end - second_start) + first_replacement.len + second_replacement.len, actual.len);
        try std.testing.expectEqualSlices(u8, source_memory[0..first_start], actual[0..first_start]);
        try std.testing.expectEqualSlices(u8, first_replacement, actual[first_start..middle_start]);
        try std.testing.expectEqualSlices(u8, source_memory[first_end..second_start], actual[middle_start..second_output_start]);
        try std.testing.expectEqualSlices(u8, second_replacement, actual[second_output_start .. second_output_start + second_replacement.len]);
        try std.testing.expectEqualSlices(u8, source_memory[second_end..source_len], actual[second_output_start + second_replacement.len ..]);
    }
}

test "apply generated single edits preserve byte partitions" {
    // Test fixture capacity only, not a product capacity.
    var source_memory: [32]u8 = undefined;
    for (&source_memory, 0..) |*byte, index| byte.* = @intCast(index);

    var source_len: usize = 0;
    while (source_len <= source_memory.len) : (source_len += 1) {
        var start: usize = 0;
        while (start <= source_len) : (start += 1) {
            var end = start;
            while (end <= source_len) : (end += 1) {
                const replacement = "XYZ"[0 .. (start + end) % 4];
                const edits = [_]Edit{.{ .start = start, .end = end, .replacement = replacement }};
                var destination: [40]u8 = undefined;
                const actual = try apply(source_memory[0..source_len], &edits, &destination);
                try std.testing.expectEqual(source_len - (end - start) + replacement.len, actual.len);
                try std.testing.expectEqualSlices(u8, source_memory[0..start], actual[0..start]);
                try std.testing.expectEqualSlices(u8, replacement, actual[start .. start + replacement.len]);
                try std.testing.expectEqualSlices(u8, source_memory[end..source_len], actual[start + replacement.len ..]);
            }
        }
    }
}

test "inspect reports byte format without conversion" {
    const format = inspect("a\r\nb\rc\n");
    try std.testing.expectEqual(Bom.none, format.bom);
    try std.testing.expectEqual(Encoding.byte_stream, format.encoding);
    try std.testing.expect(format.utf8_valid);
    try std.testing.expectEqual(@as(usize, 1), format.newlines.crlf);
    try std.testing.expectEqual(@as(usize, 1), format.newlines.cr);
    try std.testing.expectEqual(@as(usize, 1), format.newlines.lf);
    try std.testing.expect(format.has_final_newline);
    try std.testing.expect(!inspect("last").has_final_newline);
}

test "inspect detects BOM variants and counts unsupported encodings as raw bytes" {
    const cases = [_]struct { bytes: []const u8, bom: Bom, encoding: Encoding }{
        .{ .bytes = "\xef\xbb\xbf\r\n", .bom = .utf8, .encoding = .utf8_bom },
        .{ .bytes = "\xff\xfe\r\n", .bom = .utf16_little_endian, .encoding = .unsupported_utf16_little_endian },
        .{ .bytes = "\xfe\xff\r\n", .bom = .utf16_big_endian, .encoding = .unsupported_utf16_big_endian },
        .{ .bytes = "\xff\xfe\x00\x00\r\n", .bom = .utf32_little_endian, .encoding = .unsupported_utf32_little_endian },
        .{ .bytes = "\x00\x00\xfe\xff\r\n", .bom = .utf32_big_endian, .encoding = .unsupported_utf32_big_endian },
    };
    for (cases) |case| {
        const format = inspect(case.bytes);
        try std.testing.expectEqual(case.bom, format.bom);
        try std.testing.expectEqual(case.encoding, format.encoding);
        try std.testing.expectEqual(@as(usize, 1), format.newlines.crlf);
        try std.testing.expectEqual(@as(usize, 0), format.newlines.cr);
        try std.testing.expectEqual(@as(usize, 0), format.newlines.lf);
        try std.testing.expect(format.has_final_newline);
    }
}

test "utf8 validation accepts scalars and rejects invalid sequences" {
    const valid = [_][]const u8{ "", "plain", "\xc2\x80", "\xe0\xa0\x80", "\xed\x9f\xbf", "\xf4\x8f\xbf\xbf" };
    const invalid = [_][]const u8{ "\x80", "\xc0\x80", "\xe0\x80\x80", "\xed\xa0\x80", "\xf0\x80\x80\x80", "\xf4\x90\x80\x80", "\xe2\x82" };
    for (valid) |bytes| try std.testing.expect(inspect(bytes).utf8_valid);
    for (invalid) |bytes| try std.testing.expect(!inspect(bytes).utf8_valid);
}

test "line iterator spans CR LF and CRLF exactly" {
    const bytes = "a\r\nb\rc\nlast";
    const expected = [_][]const u8{ "a\r\n", "b\r", "c\n", "last" };
    var iterator = LineIterator.init(bytes);
    var reconstructed: [bytes.len]u8 = undefined;
    var offset: usize = 0;
    var index: usize = 0;
    while (iterator.next()) |span| {
        const line = bytes[span.start..span.end];
        @memcpy(reconstructed[offset..][0..line.len], line);
        offset += line.len;
        try std.testing.expectEqualStrings(expected[index], line);
        try std.testing.expect(span.start <= span.content_end);
        try std.testing.expect(span.content_end <= span.end);
        index += 1;
    }
    try std.testing.expectEqual(expected.len, index);
    try std.testing.expectEqualStrings(bytes, reconstructed[0..offset]);
}
