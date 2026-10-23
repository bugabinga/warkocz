const std = @import("std");
const diff = @import("diff.zig");

pub const ByteRange = diff.ByteRange;
pub const Hunk = diff.Hunk;
pub const Conflict = struct { base: ByteRange, left: ByteRange, right: ByteRange };
pub const Result = struct { written: usize, left_hunks: []const diff.Hunk, right_hunks: []const diff.Hunk };
pub const Outcome = union(enum) { clean: Result, conflict: []const Conflict };
pub const Error = diff.Error || error{ DestinationTooSmall, DestinationAliased, ConflictCapacity, OutputTooLarge, AmbiguousAlignment };

/// All workspace, hunk, conflict, and destination arrays must be mutually disjoint from inputs.
/// No allocation occurs; destination and conflicts stay unchanged on every error or non-clean outcome.
pub const Storage = struct {
    left: diff.Storage,
    right: diff.Storage,
    left_hunks: []diff.Hunk,
    right_hunks: []diff.Hunk,
};

/// Conservative three-way byte-line merge.
/// Disjoint edits compose; overlapping edits and same-position insertions become conflicts.
/// destination and conflicts remain unchanged for every error or conflict outcome.
pub fn merge(base: []const u8, left: []const u8, right: []const u8, storage: Storage, destination: []u8, conflicts: []Conflict, max_work: usize) Error!Outcome {
    if (aliases(destination, base) or aliases(destination, left) or aliases(destination, right)) return error.DestinationAliased;
    if (!merge_storage_is_disjoint(base, left, right, storage, destination, conflicts)) return error.StorageAliased;
    const left_result = try diff.diff(base, left, storage.left, storage.left_hunks, max_work);
    if (std.mem.eql(u8, left, right)) return write_identical(left, left_result.hunks, destination);
    const right_budget = max_work - left_result.work_used;
    const right_result = try diff.diff(base, right, storage.right, storage.right_hunks, right_budget);
    if (!std.mem.eql(u8, left, base) and !std.mem.eql(u8, right, base) and (left_result.alignment_ambiguous or right_result.alignment_ambiguous)) return error.AmbiguousAlignment;
    const conflict_count = count_conflicts(left_result.hunks, right_result.hunks);
    if (conflict_count > conflicts.len) return error.ConflictCapacity;
    if (conflict_count != 0) {
        emit_conflicts(left_result.hunks, right_result.hunks, conflicts[0..conflict_count]);
        return .{ .conflict = conflicts[0..conflict_count] };
    }
    const required = try output_length(base.len, left_result.hunks, right_result.hunks);
    if (required > destination.len) return error.DestinationTooSmall;
    write_clean(base, left, right, left_result.hunks, right_result.hunks, destination[0..required]);
    return .{ .clean = .{ .written = required, .left_hunks = left_result.hunks, .right_hunks = right_result.hunks } };
}

fn merge_storage_is_disjoint(base: []const u8, left: []const u8, right: []const u8, storage: Storage, destination: []u8, conflicts: []Conflict) bool {
    return input_disjoint(base, storage, destination, conflicts) and
        input_disjoint(left, storage, destination, conflicts) and
        input_disjoint(right, storage, destination, conflicts) and
        outputs_disjoint(storage, destination, conflicts) and
        workspaces_disjoint(storage);
}

fn input_disjoint(input: []const u8, storage: Storage, destination: []u8, conflicts: []Conflict) bool {
    return !overlap(u8, diff.Line, input, storage.left.base_lines) and !overlap(u8, diff.Line, input, storage.left.other_lines) and
        !overlap(u8, diff.Cell, input, storage.left.cells) and !overlap(u8, diff.Hunk, input, storage.left_hunks) and
        !overlap(u8, diff.Line, input, storage.right.base_lines) and !overlap(u8, diff.Line, input, storage.right.other_lines) and
        !overlap(u8, diff.Cell, input, storage.right.cells) and !overlap(u8, diff.Hunk, input, storage.right_hunks) and
        !overlap(u8, u8, input, destination) and !overlap(u8, Conflict, input, conflicts);
}

fn outputs_disjoint(storage: Storage, destination: []u8, conflicts: []Conflict) bool {
    return !overlap(u8, Conflict, destination, conflicts) and
        !overlap(u8, diff.Line, destination, storage.left.base_lines) and !overlap(u8, diff.Line, destination, storage.left.other_lines) and
        !overlap(u8, diff.Cell, destination, storage.left.cells) and !overlap(u8, diff.Hunk, destination, storage.left_hunks) and
        !overlap(u8, diff.Line, destination, storage.right.base_lines) and !overlap(u8, diff.Line, destination, storage.right.other_lines) and
        !overlap(u8, diff.Cell, destination, storage.right.cells) and !overlap(u8, diff.Hunk, destination, storage.right_hunks) and
        !overlap(Conflict, diff.Line, conflicts, storage.left.base_lines) and !overlap(Conflict, diff.Line, conflicts, storage.left.other_lines) and
        !overlap(Conflict, diff.Cell, conflicts, storage.left.cells) and !overlap(Conflict, diff.Hunk, conflicts, storage.left_hunks) and
        !overlap(Conflict, diff.Line, conflicts, storage.right.base_lines) and !overlap(Conflict, diff.Line, conflicts, storage.right.other_lines) and
        !overlap(Conflict, diff.Cell, conflicts, storage.right.cells) and !overlap(Conflict, diff.Hunk, conflicts, storage.right_hunks);
}

fn workspaces_disjoint(storage: Storage) bool {
    return !overlap(diff.Line, diff.Line, storage.left.base_lines, storage.right.base_lines) and !overlap(diff.Line, diff.Line, storage.left.base_lines, storage.right.other_lines) and
        !overlap(diff.Line, diff.Cell, storage.left.base_lines, storage.right.cells) and !overlap(diff.Line, diff.Hunk, storage.left.base_lines, storage.right_hunks) and
        !overlap(diff.Line, diff.Line, storage.left.other_lines, storage.right.base_lines) and !overlap(diff.Line, diff.Line, storage.left.other_lines, storage.right.other_lines) and
        !overlap(diff.Line, diff.Cell, storage.left.other_lines, storage.right.cells) and !overlap(diff.Line, diff.Hunk, storage.left.other_lines, storage.right_hunks) and
        !overlap(diff.Cell, diff.Line, storage.left.cells, storage.right.base_lines) and !overlap(diff.Cell, diff.Line, storage.left.cells, storage.right.other_lines) and
        !overlap(diff.Cell, diff.Cell, storage.left.cells, storage.right.cells) and !overlap(diff.Cell, diff.Hunk, storage.left.cells, storage.right_hunks) and
        !overlap(diff.Hunk, diff.Line, storage.left_hunks, storage.right.base_lines) and !overlap(diff.Hunk, diff.Line, storage.left_hunks, storage.right.other_lines) and
        !overlap(diff.Hunk, diff.Cell, storage.left_hunks, storage.right.cells) and !overlap(diff.Hunk, diff.Hunk, storage.left_hunks, storage.right_hunks);
}

fn overlap(comptime Left: type, comptime Right: type, left: []const Left, right: []const Right) bool {
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

fn write_identical(bytes: []const u8, hunks: []const diff.Hunk, destination: []u8) Error!Outcome {
    if (bytes.len > destination.len) return error.DestinationTooSmall;
    @memcpy(destination[0..bytes.len], bytes);
    return .{ .clean = .{ .written = bytes.len, .left_hunks = hunks, .right_hunks = hunks } };
}

fn aliases(destination: []const u8, input: []const u8) bool {
    if (destination.len == 0 or input.len == 0) return false;
    const destination_start = @intFromPtr(destination.ptr);
    const input_start = @intFromPtr(input.ptr);
    const destination_end = std.math.add(usize, destination_start, destination.len) catch return true;
    const input_end = std.math.add(usize, input_start, input.len) catch return true;
    std.debug.assert(destination_start < destination_end);
    std.debug.assert(input_start < input_end);
    return destination_start < input_end and input_start < destination_end;
}

fn count_conflicts(left_hunks: []const diff.Hunk, right_hunks: []const diff.Hunk) usize {
    var count: usize = 0;
    var left_index: usize = 0;
    var right_index: usize = 0;
    while (left_index < left_hunks.len and right_index < right_hunks.len) {
        if (hunks_conflict(left_hunks[left_index], right_hunks[right_index])) {
            count += 1;
            advance_pair(left_hunks, right_hunks, &left_index, &right_index);
        } else if (precedes(left_hunks[left_index], right_hunks[right_index])) left_index += 1 else right_index += 1;
    }
    return count;
}

fn emit_conflicts(left_hunks: []const diff.Hunk, right_hunks: []const diff.Hunk, output: []Conflict) void {
    var count: usize = 0;
    var left_index: usize = 0;
    var right_index: usize = 0;
    while (left_index < left_hunks.len and right_index < right_hunks.len) {
        const left = left_hunks[left_index];
        const right = right_hunks[right_index];
        if (hunks_conflict(left, right)) {
            output[count] = .{ .base = envelope(left.base, right.base), .left = left.other, .right = right.other };
            count += 1;
            advance_pair(left_hunks, right_hunks, &left_index, &right_index);
        } else if (precedes(left, right)) left_index += 1 else right_index += 1;
    }
    std.debug.assert(count == output.len);
}

fn hunks_conflict(left: diff.Hunk, right: diff.Hunk) bool {
    const left_insert = left.base.start == left.base.end;
    const right_insert = right.base.start == right.base.end;
    std.debug.assert(left.base.start <= left.base.end);
    std.debug.assert(right.base.start <= right.base.end);
    if (left_insert and right_insert) return left.base.start == right.base.start;
    if (left_insert) return right.base.start <= left.base.start and left.base.start <= right.base.end;
    if (right_insert) return left.base.start <= right.base.start and right.base.start <= left.base.end;
    return left.base.start < right.base.end and right.base.start < left.base.end;
}

fn precedes(left: diff.Hunk, right: diff.Hunk) bool {
    if (left.base.end != right.base.start) return left.base.end <= right.base.start;
    return left.base.start != right.base.start or left.base.end != left.base.start;
}

fn advance_pair(left_hunks: []const diff.Hunk, right_hunks: []const diff.Hunk, left_index: *usize, right_index: *usize) void {
    const left = left_hunks[left_index.*];
    const right = right_hunks[right_index.*];
    if (left.base.end <= right.base.end) left_index.* += 1;
    if (right.base.end <= left.base.end) right_index.* += 1;
}

fn envelope(left: ByteRange, right: ByteRange) ByteRange {
    std.debug.assert(left.start <= left.end);
    std.debug.assert(right.start <= right.end);
    return .{ .start = @min(left.start, right.start), .end = @max(left.end, right.end) };
}

fn output_length(base_len: usize, left_hunks: []const diff.Hunk, right_hunks: []const diff.Hunk) Error!usize {
    var removed: usize = 0;
    var added: usize = 0;
    for (left_hunks) |hunk| try accumulate_length(&removed, &added, hunk);
    for (right_hunks) |hunk| try accumulate_length(&removed, &added, hunk);
    if (removed > base_len) return error.OutputTooLarge;
    return std.math.add(usize, base_len - removed, added) catch error.OutputTooLarge;
}

fn accumulate_length(removed: *usize, added: *usize, hunk: diff.Hunk) Error!void {
    const removed_bytes = hunk.base.end - hunk.base.start;
    const added_bytes = hunk.other.end - hunk.other.start;
    removed.* = std.math.add(usize, removed.*, removed_bytes) catch return error.OutputTooLarge;
    added.* = std.math.add(usize, added.*, added_bytes) catch return error.OutputTooLarge;
    std.debug.assert(hunk.base.start <= hunk.base.end);
    std.debug.assert(hunk.other.start <= hunk.other.end);
}

fn write_clean(base: []const u8, left: []const u8, right: []const u8, left_hunks: []const diff.Hunk, right_hunks: []const diff.Hunk, destination: []u8) void {
    var base_offset: usize = 0;
    var written: usize = 0;
    var left_index: usize = 0;
    var right_index: usize = 0;
    while (left_index < left_hunks.len or right_index < right_hunks.len) {
        const take_left = right_index == right_hunks.len or (left_index < left_hunks.len and precedes(left_hunks[left_index], right_hunks[right_index]));
        const hunk = if (take_left) left_hunks[left_index] else right_hunks[right_index];
        const source = if (take_left) left else right;
        copy(destination, &written, base[base_offset..hunk.base.start]);
        copy(destination, &written, source[hunk.other.start..hunk.other.end]);
        base_offset = hunk.base.end;
        if (take_left) left_index += 1 else right_index += 1;
    }
    copy(destination, &written, base[base_offset..]);
    std.debug.assert(written == destination.len);
}

fn copy(destination: []u8, written: *usize, source: []const u8) void {
    std.debug.assert(written.* <= destination.len);
    std.debug.assert(source.len <= destination.len - written.*);
    @memcpy(destination[written.* .. written.* + source.len], source);
    written.* += source.len;
}

test "disjoint multi-hunk edits compose exact bytes" {
    var base_left: [5]diff.Line = undefined;
    var other_left: [5]diff.Line = undefined;
    var cells_left: [36]diff.Cell = undefined;
    var base_right: [5]diff.Line = undefined;
    var other_right: [5]diff.Line = undefined;
    var cells_right: [36]diff.Cell = undefined;
    var left_hunks: [4]diff.Hunk = undefined;
    var right_hunks: [4]diff.Hunk = undefined;
    var destination: [32]u8 = undefined;
    var conflict_output: [2]Conflict = undefined;
    const state = Storage{ .left = .{ .base_lines = &base_left, .other_lines = &other_left, .cells = &cells_left }, .right = .{ .base_lines = &base_right, .other_lines = &other_right, .cells = &cells_right }, .left_hunks = &left_hunks, .right_hunks = &right_hunks };
    const outcome = try merge("\xef\xbb\xbfa\r\nb\nc\n", "\xef\xbb\xbfA\r\nb\nc\n", "\xef\xbb\xbfa\r\nb\nC\n", state, &destination, &conflict_output, 200);
    try std.testing.expectEqualStrings("\xef\xbb\xbfA\r\nb\nC\n", destination[0..outcome.clean.written]);
    try std.testing.expectEqual(@as(usize, 1), outcome.clean.left_hunks.len);
    try std.testing.expectEqual(@as(usize, 1), outcome.clean.right_hunks.len);
}

test "same-position insertion and scalar overlap are conflicts without writes" {
    var base_left: [3]diff.Line = undefined;
    var other_left: [3]diff.Line = undefined;
    var cells_left: [16]diff.Cell = undefined;
    var base_right: [3]diff.Line = undefined;
    var other_right: [3]diff.Line = undefined;
    var cells_right: [16]diff.Cell = undefined;
    var left_hunks: [3]diff.Hunk = undefined;
    var right_hunks: [3]diff.Hunk = undefined;
    var destination: [16]u8 = @splat(0xaa);
    const before = destination;
    var output: [2]Conflict = undefined;
    const state = Storage{ .left = .{ .base_lines = &base_left, .other_lines = &other_left, .cells = &cells_left }, .right = .{ .base_lines = &base_right, .other_lines = &other_right, .cells = &cells_right }, .left_hunks = &left_hunks, .right_hunks = &right_hunks };
    var outcome = try merge("a\n", "L\na\n", "R\na\n", state, &destination, &output, 100);
    try std.testing.expectEqual(ByteRange{ .start = 0, .end = 0 }, outcome.conflict[0].base);
    try std.testing.expectEqualSlices(u8, &before, &destination);
    outcome = try merge("a\n", "L\n", "R\n", state, &destination, &output, 100);
    try std.testing.expectEqual(ByteRange{ .start = 0, .end = 2 }, outcome.conflict[0].base);
    try std.testing.expectEqualSlices(u8, &before, &destination);
    outcome = try merge("a\nb\n", "a\nL\nb\n", "a\nB\n", state, &destination, &output, 100);
    try std.testing.expectEqual(ByteRange{ .start = 2, .end = 4 }, outcome.conflict[0].base);
    try std.testing.expectEqualSlices(u8, &before, &destination);
}

test "identical sides are clean with retained hunk provenance" {
    var base_left: [2]diff.Line = undefined;
    var other_left: [2]diff.Line = undefined;
    var cells_left: [9]diff.Cell = undefined;
    var base_right: [2]diff.Line = undefined;
    var other_right: [2]diff.Line = undefined;
    var cells_right: [9]diff.Cell = undefined;
    var left_hunks: [2]diff.Hunk = undefined;
    var right_hunks: [2]diff.Hunk = undefined;
    var destination: [8]u8 = undefined;
    var conflict_output: [0]Conflict = .{};
    const state = Storage{ .left = .{ .base_lines = &base_left, .other_lines = &other_left, .cells = &cells_left }, .right = .{ .base_lines = &base_right, .other_lines = &other_right, .cells = &cells_right }, .left_hunks = &left_hunks, .right_hunks = &right_hunks };
    const outcome = try merge("a\n", "A\n", "A\n", state, &destination, &conflict_output, 100);
    try std.testing.expectEqualStrings("A\n", destination[0..outcome.clean.written]);
    try std.testing.expectEqual(@as(usize, 1), outcome.clean.left_hunks.len);
    try std.testing.expectEqual(@as(usize, 1), outcome.clean.right_hunks.len);
}

test "input and hunk-storage aliases preserve destination" {
    var base_left: [2]diff.Line = undefined;
    var other_left: [2]diff.Line = undefined;
    var cells_left: [9]diff.Cell = undefined;
    var base_right: [2]diff.Line = undefined;
    var other_right: [2]diff.Line = undefined;
    var cells_right: [9]diff.Cell = undefined;
    var shared_hunks: [2]diff.Hunk = undefined;
    var destination: [8]u8 = @splat(0xaa);
    const before = destination;
    const storage = Storage{ .left = .{ .base_lines = &base_left, .other_lines = &other_left, .cells = &cells_left }, .right = .{ .base_lines = &base_right, .other_lines = &other_right, .cells = &cells_right }, .left_hunks = &shared_hunks, .right_hunks = &shared_hunks };
    var conflicts: [1]Conflict = undefined;
    try std.testing.expectError(error.StorageAliased, merge("a\n", "A\n", "a\n", storage, &destination, &conflicts, 100));
    try std.testing.expectEqual(before, destination);
    var input = [_]u8{ 'a', '\n', 0xaa, 0xaa };
    try std.testing.expectError(error.DestinationAliased, merge(input[0..2], "A\n", input[0..2], storage, input[0..], &conflicts, 100));
    try std.testing.expectEqual(@as(u8, 'a'), input[0]);
    try std.testing.expectEqual(@as(u8, '\n'), input[1]);
}

test "repeated-line ambiguity degrades instead of claiming clean composition" {
    var base_left: [4]diff.Line = undefined;
    var other_left: [4]diff.Line = undefined;
    var cells_left: [25]diff.Cell = undefined;
    var base_right: [4]diff.Line = undefined;
    var other_right: [4]diff.Line = undefined;
    var cells_right: [25]diff.Cell = undefined;
    var left_hunks: [4]diff.Hunk = undefined;
    var right_hunks: [4]diff.Hunk = undefined;
    var destination: [16]u8 = @splat(0xaa);
    const before = destination;
    var conflicts: [2]Conflict = undefined;
    const storage = Storage{ .left = .{ .base_lines = &base_left, .other_lines = &other_left, .cells = &cells_left }, .right = .{ .base_lines = &base_right, .other_lines = &other_right, .cells = &cells_right }, .left_hunks = &left_hunks, .right_hunks = &right_hunks };
    try std.testing.expectError(error.AmbiguousAlignment, merge("a\na\nb\n", "a\nb\n", "a\na\nB\n", storage, &destination, &conflicts, 200));
    try std.testing.expectEqual(before, destination);
}

test "capacity errors roll back visible output" {
    var base_left: [2]diff.Line = undefined;
    var other_left: [2]diff.Line = undefined;
    var cells_left: [9]diff.Cell = undefined;
    var base_right: [2]diff.Line = undefined;
    var other_right: [2]diff.Line = undefined;
    var cells_right: [9]diff.Cell = undefined;
    var left_hunks: [2]diff.Hunk = undefined;
    var right_hunks: [2]diff.Hunk = undefined;
    var destination: [2]u8 = .{ 0xcc, 0xcc };
    const before = destination;
    var conflicts_output: [0]Conflict = .{};
    const state = Storage{ .left = .{ .base_lines = &base_left, .other_lines = &other_left, .cells = &cells_left }, .right = .{ .base_lines = &base_right, .other_lines = &other_right, .cells = &cells_right }, .left_hunks = &left_hunks, .right_hunks = &right_hunks };
    try std.testing.expectError(error.DestinationTooSmall, merge("a", "long", "a", state, &destination, &conflicts_output, 100));
    try std.testing.expectEqual(before, destination);
}
