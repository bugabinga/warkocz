const std = @import("std");

/// Half-open byte range, preserving every original byte within its bounds.
pub const ByteRange = struct { start: usize, end: usize };

/// Exact source line, including its CR, LF, or CRLF terminator when present.
pub const Line = struct { start: usize, end: usize };

/// One ordered replacement from base bytes to other bytes.
pub const Hunk = struct { base: ByteRange, other: ByteRange };

/// Caller-owned dynamic-programming state. It is scratch and may change on failure.
pub const Cell = struct { score: usize = 0, step: Step = .done };
pub const Step = enum { diagonal, down, right, done };

/// Every workspace and hunk-output array must be mutually disjoint and disjoint from inputs.
/// Workspace is scratch and may change on failure; hunk output is unchanged on every error.
pub const Storage = struct {
    base_lines: []Line,
    other_lines: []Line,
    cells: []Cell,
};

pub const Result = struct { hunks: []const Hunk, work_used: usize, alignment_ambiguous: bool };
pub const Error = error{ LineCapacity, MatrixCapacity, HunkCapacity, WorkExhausted, ArithmeticOverflow, StorageAliased };

/// Produces ordered exact line hunks with O(base_lines × other_lines) bounded caller storage.
/// max_work bounds byte scans and line-byte comparisons; hunk output stays unchanged on failure.
pub fn diff(base: []const u8, other: []const u8, storage: Storage, hunks: []Hunk, max_work: usize) Error!Result {
    if (!storage_is_disjoint(base, other, storage, hunks)) return error.StorageAliased;
    var work = Work{ .remaining = max_work };
    const base_count = try split_lines(base, storage.base_lines, &work);
    const other_count = try split_lines(other, storage.other_lines, &work);
    const width = std.math.add(usize, other_count, 1) catch return error.ArithmeticOverflow;
    const rows = std.math.add(usize, base_count, 1) catch return error.ArithmeticOverflow;
    const cells_needed = std.math.mul(usize, width, rows) catch return error.ArithmeticOverflow;
    if (cells_needed > storage.cells.len) return error.MatrixCapacity;
    fill_matrix(base, other, storage.base_lines[0..base_count], storage.other_lines[0..other_count], storage.cells[0..cells_needed], width, &work) catch |err| return err;
    const trace = trace_hunks(storage.cells[0..cells_needed], base_count, other_count, width);
    if (trace.count > hunks.len) return error.HunkCapacity;
    emit_hunks(storage.cells[0..cells_needed], base_count, other_count, width, storage.base_lines[0..base_count], storage.other_lines[0..other_count], hunks[0..trace.count]);
    return .{ .hunks = hunks[0..trace.count], .work_used = max_work - work.remaining, .alignment_ambiguous = trace.alignment_ambiguous };
}

fn storage_is_disjoint(base: []const u8, other: []const u8, storage: Storage, hunks: []Hunk) bool {
    return !slices_overlap(u8, Line, base, storage.base_lines) and
        !slices_overlap(u8, Line, base, storage.other_lines) and
        !slices_overlap(u8, Cell, base, storage.cells) and
        !slices_overlap(u8, Hunk, base, hunks) and
        !slices_overlap(u8, Line, other, storage.base_lines) and
        !slices_overlap(u8, Line, other, storage.other_lines) and
        !slices_overlap(u8, Cell, other, storage.cells) and
        !slices_overlap(u8, Hunk, other, hunks) and
        !slices_overlap(Line, Line, storage.base_lines, storage.other_lines) and
        !slices_overlap(Line, Cell, storage.base_lines, storage.cells) and
        !slices_overlap(Line, Hunk, storage.base_lines, hunks) and
        !slices_overlap(Line, Cell, storage.other_lines, storage.cells) and
        !slices_overlap(Line, Hunk, storage.other_lines, hunks) and
        !slices_overlap(Cell, Hunk, storage.cells, hunks);
}

fn slices_overlap(comptime Left: type, comptime Right: type, left: []const Left, right: []const Right) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_bytes = std.math.mul(usize, left.len, @sizeOf(Left)) catch return true;
    const right_bytes = std.math.mul(usize, right.len, @sizeOf(Right)) catch return true;
    const left_end = std.math.add(usize, left_start, left_bytes) catch return true;
    const right_end = std.math.add(usize, right_start, right_bytes) catch return true;
    std.debug.assert(left_start < left_end and right_start < right_end);
    return left_start < right_end and right_start < left_end;
}

const Work = struct {
    remaining: usize,

    fn spend(self: *Work, amount: usize) Error!void {
        if (amount > self.remaining) return error.WorkExhausted;
        self.remaining -= amount;
    }
};

fn split_lines(bytes: []const u8, lines: []Line, work: *Work) Error!usize {
    var count: usize = 0;
    var start: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) {
        try work.spend(1);
        if (bytes[index] != '\r' and bytes[index] != '\n') {
            index += 1;
            continue;
        }
        if (count == lines.len) return error.LineCapacity;
        index += 1;
        if (bytes[index - 1] == '\r' and index < bytes.len and bytes[index] == '\n') {
            try work.spend(1);
            index += 1;
        }
        lines[count] = .{ .start = start, .end = index };
        count += 1;
        start = index;
    }
    if (start < bytes.len) {
        if (count == lines.len) return error.LineCapacity;
        lines[count] = .{ .start = start, .end = bytes.len };
        count += 1;
    }
    std.debug.assert(count <= lines.len);
    std.debug.assert(start <= bytes.len);
    return count;
}

fn fill_matrix(base: []const u8, other: []const u8, base_lines: []const Line, other_lines: []const Line, cells: []Cell, width: usize, work: *Work) Error!void {
    const boundary_writes = std.math.add(usize, base_lines.len, other_lines.len) catch return error.ArithmeticOverflow;
    try work.spend(cells.len);
    try work.spend(boundary_writes);
    for (cells) |*cell| cell.* = .{};
    for (0..other_lines.len) |other_index| cells[cell_index(base_lines.len, other_index, width)].step = .right;
    for (0..base_lines.len) |base_index| cells[cell_index(base_index, other_lines.len, width)].step = .down;
    var base_index = base_lines.len;
    while (base_index > 0) {
        base_index -= 1;
        var other_index = other_lines.len;
        while (other_index > 0) {
            other_index -= 1;
            try work.spend(1);
            const index = cell_index(base_index, other_index, width);
            if (try lines_equal(base, base_lines[base_index], other, other_lines[other_index], work)) {
                const score = std.math.add(usize, cells[cell_index(base_index + 1, other_index + 1, width)].score, 1) catch return error.ArithmeticOverflow;
                cells[index] = .{ .score = score, .step = .diagonal };
            } else if (cells[cell_index(base_index + 1, other_index, width)].score >= cells[cell_index(base_index, other_index + 1, width)].score) {
                cells[index] = .{ .score = cells[cell_index(base_index + 1, other_index, width)].score, .step = .down };
            } else cells[index] = .{ .score = cells[cell_index(base_index, other_index + 1, width)].score, .step = .right };
        }
    }
}

fn lines_equal(base: []const u8, base_line: Line, other: []const u8, other_line: Line, work: *Work) Error!bool {
    const base_bytes = base[base_line.start..base_line.end];
    const other_bytes = other[other_line.start..other_line.end];
    if (base_bytes.len != other_bytes.len) return false;
    try work.spend(base_bytes.len);
    return std.mem.eql(u8, base_bytes, other_bytes);
}

fn cell_index(base_index: usize, other_index: usize, width: usize) usize {
    std.debug.assert(other_index < width);
    return base_index * width + other_index;
}

const Trace = struct { count: usize, alignment_ambiguous: bool };

fn trace_hunks(cells: []const Cell, base_count: usize, other_count: usize, width: usize) Trace {
    var trace = Trace{ .count = 0, .alignment_ambiguous = false };
    var active = false;
    var base_index: usize = 0;
    var other_index: usize = 0;
    while (base_index < base_count or other_index < other_count) {
        const step = cells[cell_index(base_index, other_index, width)].step;
        trace.alignment_ambiguous = trace.alignment_ambiguous or ambiguous_step(cells, base_count, other_count, width, base_index, other_index);
        if (step == .diagonal) active = false else if (!active) {
            trace.count += 1;
            active = true;
        }
        advance(step, &base_index, &other_index);
    }
    std.debug.assert(base_index == base_count and other_index == other_count);
    return trace;
}

fn ambiguous_step(cells: []const Cell, base_count: usize, other_count: usize, width: usize, base_index: usize, other_index: usize) bool {
    const cell = cells[cell_index(base_index, other_index, width)];
    if (cell.step != .diagonal or cell.score == 0) return false;
    if (base_index < base_count and cells[cell_index(base_index + 1, other_index, width)].score == cell.score) return true;
    if (other_index < other_count and cells[cell_index(base_index, other_index + 1, width)].score == cell.score) return true;
    return false;
}

fn emit_hunks(cells: []const Cell, base_count: usize, other_count: usize, width: usize, base_lines: []const Line, other_lines: []const Line, hunks: []Hunk) void {
    var hunk_count: usize = 0;
    var active = false;
    var base_index: usize = 0;
    var other_index: usize = 0;
    var base_start: usize = 0;
    var other_start: usize = 0;
    while (base_index < base_count or other_index < other_count) {
        const step = cells[cell_index(base_index, other_index, width)].step;
        if (step != .diagonal and !active) {
            active = true;
            base_start = base_index;
            other_start = other_index;
        }
        if (step == .diagonal and active) {
            hunks[hunk_count] = hunk(base_lines, other_lines, base_start, base_index, other_start, other_index);
            hunk_count += 1;
            active = false;
        }
        advance(step, &base_index, &other_index);
    }
    if (active) {
        hunks[hunk_count] = hunk(base_lines, other_lines, base_start, base_index, other_start, other_index);
        hunk_count += 1;
    }
    std.debug.assert(hunk_count == hunks.len);
}

fn advance(step: Step, base_index: *usize, other_index: *usize) void {
    switch (step) {
        .diagonal => {
            base_index.* += 1;
            other_index.* += 1;
        },
        .down => base_index.* += 1,
        .right => other_index.* += 1,
        .done => unreachable,
    }
}

fn hunk(base_lines: []const Line, other_lines: []const Line, base_start: usize, base_end: usize, other_start: usize, other_end: usize) Hunk {
    return .{ .base = range_for(base_lines, base_start, base_end), .other = range_for(other_lines, other_start, other_end) };
}

fn range_for(lines: []const Line, start: usize, end: usize) ByteRange {
    std.debug.assert(start <= end and end <= lines.len);
    const offset = if (start == lines.len) end_offset(lines) else lines[start].start;
    const range_end = if (end == lines.len) end_offset(lines) else lines[end].start;
    std.debug.assert(offset <= range_end);
    return .{ .start = offset, .end = range_end };
}

fn end_offset(lines: []const Line) usize {
    if (lines.len == 0) return 0;
    std.debug.assert(lines[lines.len - 1].start <= lines[lines.len - 1].end);
    return lines[lines.len - 1].end;
}

test "diff preserves CRLF BOM binary bytes and final newline ranges" {
    const base = "\xef\xbb\xbfzero\r\none\n\x00\xff";
    const other = "\xef\xbb\xbfzero\r\nTWO\n\x00\xff";
    var base_lines: [4]Line = undefined;
    var other_lines: [4]Line = undefined;
    var cells: [25]Cell = undefined;
    var hunks: [2]Hunk = undefined;
    const result = try diff(base, other, .{ .base_lines = &base_lines, .other_lines = &other_lines, .cells = &cells }, &hunks, 100);
    try std.testing.expectEqual(@as(usize, 1), result.hunks.len);
    try std.testing.expectEqual(ByteRange{ .start = 9, .end = 13 }, result.hunks[0].base);
    try std.testing.expectEqualStrings("one\n", base[result.hunks[0].base.start..result.hunks[0].base.end]);
    try std.testing.expectEqualStrings("TWO\n", other[result.hunks[0].other.start..result.hunks[0].other.end]);
}

test "diff handles empty add delete repeated lines and capacity rollback" {
    var lines_a: [4]Line = undefined;
    var lines_b: [4]Line = undefined;
    var cells: [25]Cell = undefined;
    var output = [_]Hunk{
        .{ .base = .{ .start = 99, .end = 99 }, .other = .{ .start = 99, .end = 99 } },
        .{ .base = .{ .start = 99, .end = 99 }, .other = .{ .start = 99, .end = 99 } },
    };
    const add = try diff("", "x", .{ .base_lines = &lines_a, .other_lines = &lines_b, .cells = &cells }, &output, 30);
    try std.testing.expectEqual(ByteRange{ .start = 0, .end = 0 }, add.hunks[0].base);
    try std.testing.expectEqual(ByteRange{ .start = 0, .end = 1 }, add.hunks[0].other);
    const delete = try diff("x", "", .{ .base_lines = &lines_a, .other_lines = &lines_b, .cells = &cells }, &output, 30);
    try std.testing.expectEqual(ByteRange{ .start = 0, .end = 1 }, delete.hunks[0].base);
    try std.testing.expectEqual(@as(usize, 0), delete.hunks[0].other.end);
    const before_capacity_error = output;
    try std.testing.expectError(error.HunkCapacity, diff("a\na\n", "b\nb\n", .{ .base_lines = &lines_a, .other_lines = &lines_b, .cells = &cells }, output[0..0], 100));
    try std.testing.expectEqual(before_capacity_error, output);
}

fn apply_hunks(base: []const u8, other: []const u8, hunks: []const Hunk, destination: []u8) []const u8 {
    var base_offset: usize = 0;
    var written: usize = 0;
    for (hunks) |change| {
        @memcpy(destination[written .. written + change.base.start - base_offset], base[base_offset..change.base.start]);
        written += change.base.start - base_offset;
        @memcpy(destination[written .. written + change.other.end - change.other.start], other[change.other.start..change.other.end]);
        written += change.other.end - change.other.start;
        base_offset = change.base.end;
    }
    @memcpy(destination[written .. written + base.len - base_offset], base[base_offset..]);
    return destination[0 .. written + base.len - base_offset];
}

test "generated round trips retain exact bytes for repeated and ambiguous lines" {
    const Case = struct { base: []const u8, other: []const u8 };
    const cases = [_]Case{
        .{ .base = "a\na\na\n", .other = "a\nb\na\n" },
        .{ .base = "x\r\nx\r\ny", .other = "x\r\ny\r\nx\r\ny" },
        .{ .base = "\x00\xff\nq", .other = "\x00\xff\nQ" },
        .{ .base = "", .other = "\xef\xbb\xbf\r\n" },
    };
    for (cases) |case| {
        var base_lines: [8]Line = undefined;
        var other_lines: [8]Line = undefined;
        var cells: [81]Cell = undefined;
        var hunks: [8]Hunk = undefined;
        var destination: [64]u8 = undefined;
        const result = try diff(case.base, case.other, .{ .base_lines = &base_lines, .other_lines = &other_lines, .cells = &cells }, &hunks, 500);
        try std.testing.expectEqualStrings(case.other, apply_hunks(case.base, case.other, result.hunks, &destination));
    }
}

test "diff charges initialization and every unequal cell" {
    var base_lines: [2]Line = undefined;
    var other_lines: [2]Line = undefined;
    var cells: [9]Cell = undefined;
    var output = [_]Hunk{.{ .base = .{ .start = 7, .end = 8 }, .other = .{ .start = 9, .end = 10 } }};
    const before = output;
    const storage = Storage{ .base_lines = &base_lines, .other_lines = &other_lines, .cells = &cells };
    try std.testing.expectError(error.WorkExhausted, diff("", "", storage, &output, 0));
    try std.testing.expectError(error.WorkExhausted, diff("a", "b", storage, &output, 9));
    try std.testing.expectEqual(before, output);
    const result = try diff("a", "b", storage, &output, 10);
    try std.testing.expectEqual(@as(usize, 10), result.work_used);
}

test "diff rejects aliased workspace without changing hunk output" {
    var lines: [2]Line = undefined;
    var cells: [9]Cell = undefined;
    var output = [_]Hunk{.{ .base = .{ .start = 7, .end = 8 }, .other = .{ .start = 9, .end = 10 } }};
    const before = output;
    try std.testing.expectError(error.StorageAliased, diff("a", "b", .{ .base_lines = &lines, .other_lines = &lines, .cells = &cells }, &output, 100));
    try std.testing.expectEqual(before, output);
}

fn line_fixture(buffer: *[6]u8, count: usize, bits: usize) []const u8 {
    std.debug.assert(count <= 3);
    var index: usize = 0;
    for (0..count) |line| {
        buffer[index] = if ((bits >> @intCast(line)) & 1 == 0) 'a' else 'b';
        buffer[index + 1] = '\n';
        index += 2;
    }
    return buffer[0..index];
}

test "diff exhaustively reconstructs binary line sequences" {
    for (0..4) |base_count| for (0..4) |other_count| {
        for (0..(@as(usize, 1) << @intCast(base_count))) |base_bits| for (0..(@as(usize, 1) << @intCast(other_count))) |other_bits| {
            var base_buffer: [6]u8 = undefined;
            var other_buffer: [6]u8 = undefined;
            const base = line_fixture(&base_buffer, base_count, base_bits);
            const other = line_fixture(&other_buffer, other_count, other_bits);
            var base_lines: [3]Line = undefined;
            var other_lines: [3]Line = undefined;
            var cells: [16]Cell = undefined;
            var hunks: [4]Hunk = undefined;
            var destination: [12]u8 = undefined;
            const result = try diff(base, other, .{ .base_lines = &base_lines, .other_lines = &other_lines, .cells = &cells }, &hunks, 100);
            try std.testing.expectEqualStrings(other, apply_hunks(base, other, result.hunks, &destination));
            for (result.hunks) |change| {
                try std.testing.expect(change.base.start <= change.base.end and change.base.end <= base.len);
                try std.testing.expect(change.other.start <= change.other.end and change.other.end <= other.len);
            }
        };
    };
}
