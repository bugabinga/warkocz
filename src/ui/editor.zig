const std = @import("std");

pub const Direction = enum { left, right, home, end };
pub const State = struct {
    cursor: usize = 0,
    anchor: usize = 0,

    pub fn init(source: []const u8) ?State {
        if (!editable_source_allowed(source)) return null;
        return .{ .cursor = source.len, .anchor = source.len };
    }

    pub fn selection_start(self: State) usize {
        std.debug.assert(self.cursor <= std.math.maxInt(usize));
        return @min(self.cursor, self.anchor);
    }

    pub fn selection_end(self: State) usize {
        std.debug.assert(self.anchor <= std.math.maxInt(usize));
        return @max(self.cursor, self.anchor);
    }

    pub fn has_selection(self: State) bool {
        return self.cursor != self.anchor;
    }

    pub fn clamp(self: *State, source: []const u8) void {
        self.cursor = normalize_boundary(source, @min(self.cursor, source.len));
        self.anchor = normalize_boundary(source, @min(self.anchor, source.len));
        std.debug.assert(self.cursor <= source.len and self.anchor <= source.len);
    }

    pub fn move(self: *State, source: []const u8, direction: Direction, extend: bool) void {
        self.clamp(source);
        const target = switch (direction) {
            .left => previous_boundary(source, self.cursor),
            .right => next_boundary(source, self.cursor),
            .home => line_start(source, self.cursor),
            .end => line_end(source, self.cursor),
        };
        self.cursor = target;
        if (!extend) self.anchor = target;
        std.debug.assert(self.cursor <= source.len and self.anchor <= source.len);
    }

    pub fn select_all(self: *State, source: []const u8) void {
        self.anchor = 0;
        self.cursor = source.len;
        std.debug.assert(self.selection_end() == source.len);
    }

    pub fn replacement_range(self: State, source: []const u8) struct { start: usize, end: usize } {
        const cursor = normalize_boundary(source, @min(self.cursor, source.len));
        const anchor = normalize_boundary(source, @min(self.anchor, source.len));
        return .{ .start = @min(cursor, anchor), .end = @max(cursor, anchor) };
    }
};

pub fn editable_source_allowed(source: []const u8) bool {
    for (source) |byte| if (byte != '\t' and byte != '\r' and byte != '\n' and (byte < 0x20 or byte > 0x7e)) return false;
    return true;
}

pub fn column_for_offset(source: []const u8, line_start_offset: usize, offset: usize) usize {
    std.debug.assert(line_start_offset <= offset and offset <= source.len);
    var index = line_start_offset;
    var column: usize = 0;
    while (index < offset and source[index] != '\r' and source[index] != '\n') : (index += 1) {
        column += if (source[index] == '\t') 4 - column % 4 else 1;
    }
    std.debug.assert(index == offset or source[index] == '\r' or source[index] == '\n');
    return column;
}

pub fn offset_for_column(source: []const u8, line_start_offset: usize, target_column: usize) usize {
    std.debug.assert(line_start_offset <= source.len);
    var index = line_start_offset;
    var column: usize = 0;
    while (index < source.len and source[index] != '\r' and source[index] != '\n') {
        const width: usize = if (source[index] == '\t') 4 - column % 4 else 1;
        if (target_column < column + width) return index;
        column += width;
        index += 1;
    }
    return index;
}

pub fn insertion_allowed(text: []const u8) bool {
    return text.len != 0 and editable_source_allowed(text);
}

pub fn previous_boundary(source: []const u8, offset: usize) usize {
    std.debug.assert(offset <= source.len);
    const boundary = normalize_boundary(source, offset);
    if (boundary == 0) return 0;
    if (boundary >= 2 and source[boundary - 2] == '\r' and source[boundary - 1] == '\n') return boundary - 2;
    return boundary - 1;
}

pub fn next_boundary(source: []const u8, offset: usize) usize {
    std.debug.assert(offset <= source.len);
    const boundary = normalize_boundary(source, offset);
    if (boundary == source.len) return source.len;
    if (boundary + 1 < source.len and source[boundary] == '\r' and source[boundary + 1] == '\n') return boundary + 2;
    return boundary + 1;
}

pub fn line_end(source: []const u8, offset: usize) usize {
    std.debug.assert(offset <= source.len);
    var index = normalize_boundary(source, offset);
    while (index < source.len and source[index] != '\r' and source[index] != '\n') index = next_boundary(source, index);
    return index;
}

fn normalize_boundary(source: []const u8, offset: usize) usize {
    std.debug.assert(offset <= source.len);
    if (offset > 0 and offset < source.len and source[offset - 1] == '\r' and source[offset] == '\n') return offset - 1;
    return offset;
}

fn line_start(source: []const u8, offset: usize) usize {
    std.debug.assert(offset <= source.len);
    var index = normalize_boundary(source, offset);
    while (index > 0) {
        const previous = previous_boundary(source, index);
        if (source[previous] == '\n' or source[previous] == '\r') break;
        index = previous;
    }
    return index;
}

test "ASCII editor boundaries retain CRLF as one newline" {
    const source = "a\r\nb\n";
    var state = State.init(source).?;
    state.cursor = 1;
    state.anchor = 1;
    state.move(source, .right, false);
    try std.testing.expectEqual(@as(usize, 3), state.cursor);
    state.move(source, .left, false);
    try std.testing.expectEqual(@as(usize, 1), state.cursor);
    state.move(source, .end, false);
    try std.testing.expectEqual(@as(usize, 1), state.cursor);
    state.move(source, .home, false);
    try std.testing.expectEqual(@as(usize, 0), state.cursor);
}

test "selection is bounded and editable source matches insertion policy" {
    var state = State.init("abc").?;
    state.move("abc", .left, true);
    try std.testing.expect(state.has_selection());
    try std.testing.expectEqual(@as(usize, 2), state.replacement_range("abc").start);
    state.select_all("abc");
    try std.testing.expectEqual(@as(usize, 3), state.replacement_range("abc").end);
    try std.testing.expect(editable_source_allowed("a\t\r\n"));
    try std.testing.expect(State.init("a\t\r\n") != null);
    for ([_][]const u8{ "\x00", "\x1b", "\x1f", "\x7f", "\xc3\xa9" }) |unsupported| {
        try std.testing.expect(!editable_source_allowed(unsupported));
        try std.testing.expect(State.init(unsupported) == null);
        try std.testing.expect(!insertion_allowed(unsupported));
    }
    try std.testing.expect(insertion_allowed("a\t\r\n"));
    try std.testing.expect(State.init("") != null);
    try std.testing.expect(!insertion_allowed(""));
}

test "editor columns preserve tabs and CRLF boundaries" {
    const source = "a\tb\r\nc";
    try std.testing.expectEqual(@as(usize, 5), column_for_offset(source, 0, 3));
    try std.testing.expectEqual(@as(usize, 1), offset_for_column(source, 0, 2));
    try std.testing.expectEqual(@as(usize, 3), offset_for_column(source, 0, 5));
}

test "CRLF interior offsets normalize before selection or navigation" {
    const source = "a\r\nb\rc\n";
    var state = State.init(source).?;
    state.cursor = 2;
    state.anchor = 2;
    state.clamp(source);
    try std.testing.expectEqual(@as(usize, 1), state.cursor);
    try std.testing.expectEqual(@as(usize, 1), state.replacement_range(source).end);
    try std.testing.expectEqual(@as(usize, 3), next_boundary(source, 2));
    try std.testing.expectEqual(@as(usize, 0), previous_boundary(source, 2));
    try std.testing.expectEqual(@as(usize, 1), line_end(source, 0));
    try std.testing.expectEqual(@as(usize, 4), line_end(source, 3));
}
