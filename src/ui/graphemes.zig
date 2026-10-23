//! Byte ↔ grapheme ↔ UTF-16 mapping over strictly validated UTF-8, backed by
//! the patched kb standalone segmentation (no font required). The caller owns
//! fixed-capacity boundary arrays sized to the edited buffer; rebuilds fill
//! them in place and capacity overflow is a recoverable, visible outcome.

const std = @import("std");

pub const Break = extern struct {
    position: c_int,
    flags: u32,
    direction: u32,
    paragraph_direction: u32,
    script: u32,
};

const direction_ltr: u32 = 1;
const japanese_style_normal: c_int = 0;
const grapheme_flag: u32 = 1 << 2;

extern "c" fn kbts_BreakEntireStringUtf8(
    direction: u32,
    japanese_line_break_style: c_int,
    config_flags: u32,
    utf8: [*]const u8,
    utf8_length: c_int,
    breaks: [*]Break,
    break_capacity: c_int,
    break_count: *c_int,
    break_flags: [*]u32,
    break_flag_capacity: c_int,
    break_flag_count: *c_int,
) void;

/// Strict validation: std UTF-8 rules plus an explicit surrogate sweep, so
/// kb (which accepts overlong/surrogate/out-of-range sequences) never sees
/// invalid bytes.
pub fn validateUtf8(bytes: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(bytes)) return false;
    var iterator = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint >= 0xD800 and codepoint <= 0xDFFF) return false;
    }
    return true;
}

/// Boundary tables over `bytes`; `boundaries`/`utf16` must each have at
/// least `bytes.len + 1` capacity and are truncated to the used length.
pub const Map = struct {
    bytes: []const u8,
    /// Sorted cluster-start byte offsets; first is 0, last is bytes.len.
    boundaries: []u32,
    /// UTF-16 code-unit offset at each boundary; same length as boundaries.
    utf16: []u32,

    pub fn clusterCount(self: *const Map) u32 {
        std.debug.assert(self.boundaries.len >= 1);
        return @intCast(self.boundaries.len - 1);
    }

    pub fn byteAt(self: *const Map, index: u32) u32 {
        std.debug.assert(index < self.boundaries.len);
        return self.boundaries[index];
    }

    /// Cluster index containing any byte offset up to len.
    pub fn indexOfByte(self: *const Map, offset: u32) u32 {
        std.debug.assert(offset <= self.bytes.len);
        const last = self.clusterCount();
        if (offset >= self.boundaries[last]) return last;
        var low: u32 = 0;
        var high: u32 = last;
        while (low + 1 < high) {
            const middle = low + (high - low) / 2;
            if (self.boundaries[middle] <= offset) low = middle else high = middle;
        }
        std.debug.assert(self.boundaries[low] <= offset);
        return low;
    }

    pub fn nextBoundary(self: *const Map, offset: u32) ?u32 {
        std.debug.assert(offset <= self.bytes.len);
        const index = self.indexOfByte(offset);
        if (offset == self.boundaries[index]) {
            return if (index + 1 < self.boundaries.len) self.boundaries[index + 1] else null;
        }
        return self.boundaries[index + 1];
    }

    pub fn prevBoundary(self: *const Map, offset: u32) ?u32 {
        std.debug.assert(offset <= self.bytes.len);
        const index = self.indexOfByte(offset);
        if (offset == self.boundaries[index]) {
            return if (index > 0) self.boundaries[index - 1] else null;
        }
        return self.boundaries[index];
    }

    /// Maps a UTF-16 code-unit offset to its cluster index and byte offset.
    pub fn fromUtf16(self: *const Map, utf16_offset: u32) struct { index: u32, byte: u32 } {
        const last: u32 = @intCast(self.utf16.len - 1);
        std.debug.assert(utf16_offset <= self.utf16[last]);
        if (utf16_offset >= self.utf16[last]) return .{ .index = last, .byte = self.boundaries[last] };
        var low: u32 = 0;
        var high: u32 = last;
        while (low + 1 < high) {
            const middle = low + (high - low) / 2;
            if (self.utf16[middle] <= utf16_offset) low = middle else high = middle;
        }
        return .{ .index = low, .byte = self.boundaries[low] };
    }

    pub fn utf16At(self: *const Map, index: u32) u32 {
        std.debug.assert(index < self.utf16.len);
        return self.utf16[index];
    }
};

pub const BuildError = error{ InvalidUtf8, CapacityExceeded, BoundaryMalformed };

/// Fills `boundaries`/`utf16` for `bytes`; the tables and `scratch_flags`
/// must each have capacity `bytes.len + 1`. O(1) allocations, bounded work,
/// no recursion.
pub fn build(bytes: []const u8, boundaries: []u32, utf16: []u32, scratch_flags: []u32) BuildError!Map {
    std.debug.assert(boundaries.len >= bytes.len + 1 and utf16.len >= bytes.len + 1);
    std.debug.assert(scratch_flags.len >= bytes.len + 1);
    if (!validateUtf8(bytes)) return error.InvalidUtf8;
    var scratch_breaks: [64]Break = undefined;
    var break_count: c_int = 0;
    var flag_count: c_int = 0;
    kbts_BreakEntireStringUtf8(
        direction_ltr,
        japanese_style_normal,
        0,
        bytes.ptr,
        @intCast(bytes.len),
        &scratch_breaks,
        scratch_breaks.len,
        &break_count,
        scratch_flags.ptr,
        @intCast(scratch_flags.len),
        &flag_count,
    );
    if (flag_count > bytes.len + 1) return error.CapacityExceeded;
    var used: u32 = 0;
    for (scratch_flags[0..@intCast(flag_count)], 0..) |flag, offset| {
        if (flag & grapheme_flag != 0) {
            if (used == boundaries.len) return error.CapacityExceeded;
            boundaries[used] = @intCast(offset);
            used += 1;
        }
    }
    if (used == 0 and bytes.len == 0) {
        boundaries[0] = 0;
        used = 1;
    }
    if (used < 2 and bytes.len != 0) return error.BoundaryMalformed;
    if (boundaries[0] != 0 or boundaries[used - 1] != bytes.len) return error.BoundaryMalformed;
    var previous: u32 = 0;
    for (boundaries[1..used]) |boundary| {
        if (boundary <= previous) return error.BoundaryMalformed;
        previous = boundary;
    }
    var utf16_offset: u32 = 0;
    for (boundaries[0..used], 0..) |boundary, index| {
        utf16[index] = utf16_offset;
        var cursor = boundary;
        const end: u32 = if (index + 1 < used) boundaries[index + 1] else @intCast(bytes.len);
        while (cursor < end) {
            const size = std.unicode.utf8ByteSequenceLength(bytes[cursor]) catch return error.BoundaryMalformed;
            if (cursor + size > end) return error.BoundaryMalformed;
            const codepoint = std.unicode.utf8Decode(bytes[cursor .. cursor + size]) catch return error.BoundaryMalformed;
            utf16_offset += if (codepoint >= 0x10000) @as(u32, 2) else 1;
            cursor += size;
        }
        if (cursor != end) return error.BoundaryMalformed;
    }
    return .{ .bytes = bytes, .boundaries = boundaries[0..used], .utf16 = utf16[0..used] };
}
