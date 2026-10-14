const std = @import("std");
const bytes = @import("bytes.zig");
const text_merge = @import("engine/text_merge.zig");

/// Borrowed immutable versions of one logical file.
pub const Inputs = struct { base: []const u8, left: []const u8, right: []const u8 };
pub const InputIdentity = struct { base: [32]u8, left: [32]u8, right: [32]u8 };
pub const Engine = struct { name: []const u8, version: []const u8 };
pub const Identity = struct { inputs: InputIdentity, engine: Engine, generation: u64 };

pub const Origin = enum { automatic_unchanged, automatic_left, automatic_right, automatic_identical, automatic_composed, conflict, manual_base, manual_left, manual_right, manual_both_left_right, manual_both_right_left, edited };
pub const Choice = enum { base, left, right, both_left_right, both_right_left };

/// Caller-owned history metadata. Its associated result bytes live in Storage.history.
pub const Record = struct { start: usize, len: usize, origin: Origin, reviewed: bool, unresolved: bool };
/// Each backing region must remain exclusively owned and stable for Session's lifetime.
/// Regions must not overlap inputs or each other; do not reinitialize or reuse them while readers retain Session views.
pub const Storage = struct { result: []u8, scratch: []u8, history: []u8, records: []Record };
pub const State = struct { origin: Origin, reviewed: bool, unresolved: bool, written: usize };

pub const Error = error{
    AliasedStorage,
    ScratchTooSmall,
    ResultTooSmall,
    HistoryFull,
    HistoryBytesFull,
    StaleGeneration,
    ChangedInput,
    GenerationExhausted,
    NoUndo,
    NoRedo,
} || bytes.ApplyError || text_merge.MergeError;

/// Bounded in-memory state only. It neither persists drafts, saves files, nor completes operations.
/// Input hashing is synchronous O(base + left + right) at open and before every mutation.
/// Callers must schedule this core API away from latency-sensitive UI work.
pub const Session = struct {
    inputs: Inputs,
    input_identity: InputIdentity,
    storage: Storage,
    conflict: ?text_merge.Conflict,
    state: State,
    record_count: usize,
    cursor: usize,
    history_used: usize,
    generation: u64 = 1,

    pub const engine = Engine{ .name = "text_merge", .version = "1" };

    /// Opens one file with conservative automatic text merge.
    pub fn init(inputs: Inputs, storage: Storage) Error!Session {
        try validate_storage(inputs, storage);
        var session = Session{ .inputs = inputs, .input_identity = hash_inputs(inputs), .storage = storage, .conflict = null, .state = undefined, .record_count = 0, .cursor = 0, .history_used = 0 };
        const outcome = text_merge.merge(inputs.base, inputs.left, inputs.right, storage.scratch) catch |err| return err;
        switch (outcome) {
            .clean => |clean| session.state = .{ .origin = automatic_origin(clean.origin), .reviewed = clean.reviewed, .unresolved = false, .written = clean.written },
            .conflict => |conflict| {
                if (inputs.base.len > storage.scratch.len) return error.ScratchTooSmall;
                @memcpy(storage.scratch[0..inputs.base.len], inputs.base);
                session.conflict = conflict;
                session.state = .{ .origin = .conflict, .reviewed = false, .unresolved = true, .written = inputs.base.len };
            },
        }
        try session.commit_candidate(session.state);
        std.debug.assert(session.record_count == 1);
        std.debug.assert(session.cursor == 0);
        std.debug.assert(session.history_used == session.storage.records[0].len);
        std.debug.assert(session.generation == 1);
        return session;
    }

    pub fn identity(self: *const Session) Identity {
        std.debug.assert(self.record_count > 0);
        std.debug.assert(self.cursor < self.record_count);
        return .{ .inputs = self.input_identity, .engine = engine, .generation = self.generation };
    }

    pub fn result(self: *const Session) []const u8 {
        std.debug.assert(self.state.written <= self.storage.result.len);
        std.debug.assert(self.record_count > 0);
        return self.storage.result[0..self.state.written];
    }

    pub fn current_state(self: *const Session) State {
        std.debug.assert(self.state.written <= self.storage.result.len);
        std.debug.assert(self.state.unresolved or self.state.origin != .conflict);
        return self.state;
    }

    /// Selects a complete input. Both is explicitly a byte composition, not correctness.
    pub fn choose(self: *Session, expected_generation: u64, choice: Choice) Error!void {
        try self.prepare(expected_generation);
        const candidate = switch (choice) {
            .base => self.inputs.base,
            .left => self.inputs.left,
            .right => self.inputs.right,
            .both_left_right, .both_right_left => try self.compose_both(choice),
        };
        if (choice != .both_left_right and choice != .both_right_left) {
            if (candidate.len > self.storage.scratch.len) return error.ScratchTooSmall;
            @memcpy(self.storage.scratch[0..candidate.len], candidate);
        }
        try self.commit_candidate(.{ .origin = choice_origin(choice), .reviewed = false, .unresolved = false, .written = candidate.len });
        std.debug.assert(self.state.origin == choice_origin(choice));
        std.debug.assert(self.state.written == candidate.len);
    }

    /// Applies exact byte edits to current result; source inputs remain immutable.
    /// Editing never resolves an existing conflict, including an empty edit list.
    pub fn apply_edits(self: *Session, expected_generation: u64, edits: []const bytes.Edit) Error!void {
        try self.prepare(expected_generation);
        const candidate = try bytes.apply(self.result(), edits, self.storage.scratch);
        try self.commit_candidate(.{ .origin = .edited, .reviewed = false, .unresolved = self.state.unresolved, .written = candidate.len });
    }

    /// Records explicit in-memory conflict resolution; it neither saves nor completes an operation.
    pub fn mark_resolved(self: *Session, expected_generation: u64) Error!void {
        try self.prepare(expected_generation);
        if (self.state.written > self.storage.scratch.len) return error.ScratchTooSmall;
        @memcpy(self.storage.scratch[0..self.state.written], self.result());
        var next = self.state;
        next.unresolved = false;
        try self.commit_candidate(next);
    }

    pub fn set_reviewed(self: *Session, expected_generation: u64, reviewed: bool) Error!void {
        try self.prepare(expected_generation);
        if (self.state.written > self.storage.scratch.len) return error.ScratchTooSmall;
        @memcpy(self.storage.scratch[0..self.state.written], self.result());
        var next = self.state;
        next.reviewed = reviewed;
        try self.commit_candidate(next);
    }

    /// Restores original automatic decision or original explicit conflict state.
    pub fn reset_original(self: *Session, expected_generation: u64) Error!void {
        try self.prepare(expected_generation);
        const original = self.storage.records[0];
        std.debug.assert(original.start == 0);
        std.debug.assert(original.len <= self.history_used);
        if (original.len > self.storage.scratch.len) return error.ScratchTooSmall;
        @memcpy(self.storage.scratch[0..original.len], self.storage.history[original.start..][0..original.len]);
        try self.commit_candidate(.{ .origin = original.origin, .reviewed = original.reviewed, .unresolved = original.unresolved, .written = original.len });
    }

    pub fn undo(self: *Session, expected_generation: u64) Error!void {
        try self.prepare(expected_generation);
        if (self.cursor == 0) return error.NoUndo;
        try self.advance_generation();
        self.cursor -= 1;
        self.restore(self.storage.records[self.cursor]);
        std.debug.assert(self.cursor < self.record_count);
        std.debug.assert(self.storage.records[self.cursor].len == self.state.written);
    }

    pub fn redo(self: *Session, expected_generation: u64) Error!void {
        try self.prepare(expected_generation);
        if (self.cursor + 1 >= self.record_count) return error.NoRedo;
        try self.advance_generation();
        self.cursor += 1;
        self.restore(self.storage.records[self.cursor]);
        std.debug.assert(self.cursor < self.record_count);
        std.debug.assert(self.storage.records[self.cursor].len == self.state.written);
    }

    fn prepare(self: *const Session, expected_generation: u64) Error!void {
        try validate_storage(self.inputs, self.storage);
        if (!std.meta.eql(self.input_identity, hash_inputs(self.inputs))) return error.ChangedInput;
        if (expected_generation != self.generation) return error.StaleGeneration;
        std.debug.assert(self.record_count > 0);
        std.debug.assert(self.record_count <= self.storage.records.len);
        std.debug.assert(self.cursor < self.record_count);
        std.debug.assert(self.history_used <= self.storage.history.len);
        const first = self.storage.records[0];
        std.debug.assert(first.start == 0);
        std.debug.assert(first.len <= self.history_used);
        const current = self.storage.records[self.cursor];
        std.debug.assert(current.start <= self.history_used);
        std.debug.assert(current.len <= self.history_used - current.start);
        std.debug.assert(current.len == self.state.written);
        std.debug.assert(current.origin == self.state.origin and current.reviewed == self.state.reviewed and current.unresolved == self.state.unresolved);
        std.debug.assert(self.state.written <= self.storage.result.len);
    }

    fn compose_both(self: *Session, choice: Choice) Error![]const u8 {
        const first = if (choice == .both_left_right) self.inputs.left else self.inputs.right;
        const second = if (choice == .both_left_right) self.inputs.right else self.inputs.left;
        const total = std.math.add(usize, first.len, second.len) catch return error.ScratchTooSmall;
        if (total > self.storage.scratch.len) return error.ScratchTooSmall;
        @memcpy(self.storage.scratch[0..first.len], first);
        @memcpy(self.storage.scratch[first.len..total], second);
        return self.storage.scratch[0..total];
    }

    fn commit_candidate(self: *Session, next: State) Error!void {
        const reservation = try self.reserve(next.written);
        if (self.record_count > 0) try self.advance_generation();
        self.record_count = reservation.record_count;
        self.history_used = reservation.history_used;
        @memcpy(self.storage.result[0..next.written], self.storage.scratch[0..next.written]);
        const record = Record{ .start = self.history_used, .len = next.written, .origin = next.origin, .reviewed = next.reviewed, .unresolved = next.unresolved };
        std.debug.assert(record.start <= self.storage.history.len);
        std.debug.assert(record.len <= self.storage.history.len - record.start);
        @memcpy(self.storage.history[record.start..][0..record.len], self.storage.scratch[0..record.len]);
        self.storage.records[self.record_count] = record;
        self.history_used += record.len;
        self.record_count += 1;
        self.cursor = self.record_count - 1;
        self.state = next;
        const current = self.storage.records[self.cursor];
        std.debug.assert(current.start + current.len == self.history_used);
        std.debug.assert(current.len == self.state.written);
        std.debug.assert(current.origin == self.state.origin and current.reviewed == self.state.reviewed and current.unresolved == self.state.unresolved);
        std.debug.assert(self.history_used <= self.storage.history.len);
    }

    const Reservation = struct { record_count: usize, history_used: usize };

    fn reserve(self: *const Session, length: usize) Error!Reservation {
        if (length > self.storage.result.len) return error.ResultTooSmall;
        if (length > self.storage.scratch.len) return error.ScratchTooSmall;
        if (self.record_count == 0) {
            std.debug.assert(self.history_used == 0);
            if (self.storage.records.len == 0) return error.HistoryFull;
            if (length > self.storage.history.len) return error.HistoryBytesFull;
            return .{ .record_count = 0, .history_used = 0 };
        }
        std.debug.assert(self.cursor < self.record_count);
        std.debug.assert(self.record_count <= self.storage.records.len);
        const retained_count = if (self.cursor < self.record_count - 1) self.cursor + 1 else self.record_count;
        const retained_used = if (retained_count < self.record_count) blk: {
            const previous = self.storage.records[self.cursor];
            std.debug.assert(previous.start <= self.history_used);
            std.debug.assert(previous.len <= self.history_used - previous.start);
            break :blk previous.start + previous.len;
        } else self.history_used;
        std.debug.assert(retained_used <= self.storage.history.len);
        if (retained_count >= self.storage.records.len) return error.HistoryFull;
        if (length > self.storage.history.len - retained_used) return error.HistoryBytesFull;
        return .{ .record_count = retained_count, .history_used = retained_used };
    }

    fn restore(self: *Session, record: Record) void {
        std.debug.assert(record.len <= self.storage.result.len);
        std.debug.assert(record.start <= self.history_used);
        std.debug.assert(record.len <= self.history_used - record.start);
        @memcpy(self.storage.result[0..record.len], self.storage.history[record.start..][0..record.len]);
        self.state = .{ .origin = record.origin, .reviewed = record.reviewed, .unresolved = record.unresolved, .written = record.len };
        std.debug.assert(self.state.written == record.len);
        std.debug.assert(self.state.origin == record.origin and self.state.reviewed == record.reviewed and self.state.unresolved == record.unresolved);
    }

    fn advance_generation(self: *Session) Error!void {
        if (self.generation == std.math.maxInt(u64)) return error.GenerationExhausted;
        const generation = self.generation;
        self.generation += 1;
        std.debug.assert(self.generation == generation + 1);
        std.debug.assert(self.generation != 0);
    }
};

fn automatic_origin(origin: text_merge.Origin) Origin {
    return switch (origin) {
        .unchanged => .automatic_unchanged,
        .left => .automatic_left,
        .right => .automatic_right,
        .identical => .automatic_identical,
        .composed => .automatic_composed,
    };
}

fn choice_origin(choice: Choice) Origin {
    return switch (choice) {
        .base => .manual_base,
        .left => .manual_left,
        .right => .manual_right,
        .both_left_right => .manual_both_left_right,
        .both_right_left => .manual_both_right_left,
    };
}

fn hash_inputs(inputs: Inputs) InputIdentity {
    var identity: InputIdentity = undefined;
    std.crypto.hash.sha2.Sha256.hash(inputs.base, &identity.base, .{});
    std.crypto.hash.sha2.Sha256.hash(inputs.left, &identity.left, .{});
    std.crypto.hash.sha2.Sha256.hash(inputs.right, &identity.right, .{});
    return identity;
}

fn validate_storage(inputs: Inputs, storage: Storage) Error!void {
    const areas = [_][]const u8{ storage.result, storage.scratch, storage.history, std.mem.sliceAsBytes(storage.records), inputs.base, inputs.left, inputs.right };
    var first: usize = 0;
    while (first < 4) : (first += 1) {
        var second = first + 1;
        while (second < areas.len) : (second += 1) if (overlaps(areas[first], areas[second])) return error.AliasedStorage;
    }
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch return true;
    const right_end = std.math.add(usize, right_start, right.len) catch return true;
    return left_start < right_end and right_start < left_end;
}

test "automatic provenance, identity, manual composition, and reset" {
    var result: [32]u8 = undefined;
    var scratch: [32]u8 = undefined;
    var history: [128]u8 = undefined;
    var records: [8]Record = undefined;
    var session = try Session.init(.{ .base = "abcd", .left = "aXcd", .right = "abcY" }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records });
    try std.testing.expectEqual(Origin.automatic_composed, session.current_state().origin);
    try std.testing.expectEqualStrings("aXcY", session.result());
    const opened = session.identity();
    try session.choose(opened.generation, .both_left_right);
    try std.testing.expectEqual(Origin.manual_both_left_right, session.current_state().origin);
    try std.testing.expectEqualStrings("aXcdabcY", session.result());
    try session.reset_original(session.identity().generation);
    try std.testing.expectEqualStrings("aXcY", session.result());
    try std.testing.expect(session.identity().generation > opened.generation);
}

test "conflict edits require explicit in-memory resolution and undo redo preserve it" {
    var result: [16]u8 = undefined;
    var scratch: [16]u8 = undefined;
    var history: [128]u8 = undefined;
    var records: [8]Record = undefined;
    var session = try Session.init(.{ .base = "abc", .left = "aXc", .right = "aYc" }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records });
    try std.testing.expect(session.current_state().unresolved);
    try std.testing.expect(session.conflict != null);
    try session.apply_edits(session.identity().generation, &.{});
    try std.testing.expect(session.current_state().unresolved);
    const edit = [_]bytes.Edit{.{ .start = 1, .end = 2, .replacement = "Z" }};
    try session.apply_edits(session.identity().generation, &edit);
    try std.testing.expectEqualStrings("aZc", session.result());
    try std.testing.expect(session.current_state().unresolved);
    try session.mark_resolved(session.identity().generation);
    try std.testing.expect(!session.current_state().unresolved);
    try session.set_reviewed(session.identity().generation, true);
    try session.undo(session.identity().generation);
    try std.testing.expect(!session.current_state().reviewed);
    try session.undo(session.identity().generation);
    try std.testing.expect(session.current_state().unresolved);
    try session.redo(session.identity().generation);
    try std.testing.expect(!session.current_state().unresolved);
    try session.redo(session.identity().generation);
    try std.testing.expect(session.current_state().reviewed);
}

test "branching undo preserves record zero and reset" {
    var result: [16]u8 = undefined;
    var scratch: [16]u8 = undefined;
    var history: [128]u8 = undefined;
    var records: [8]Record = undefined;
    var session = try Session.init(.{ .base = "abc", .left = "aXc", .right = "aYc" }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records });
    const original = session.storage.records[0];
    try session.choose(session.identity().generation, .left);
    try session.choose(session.identity().generation, .right);
    try session.undo(session.identity().generation);
    try session.choose(session.identity().generation, .base);
    try std.testing.expectEqual(original, session.storage.records[0]);
    try session.reset_original(session.identity().generation);
    try std.testing.expectEqualStrings("abc", session.result());
    try std.testing.expect(session.current_state().unresolved);
}

test "history records cover every committed result byte range" {
    var result: [16]u8 = undefined;
    var scratch: [16]u8 = undefined;
    var history: [64]u8 = undefined;
    var records: [5]Record = undefined;
    var session = try Session.init(.{ .base = "abc", .left = "aXc", .right = "aYc" }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records });
    try session.choose(session.identity().generation, .left);
    try session.choose(session.identity().generation, .right);
    try std.testing.expectEqual(@as(usize, 3), session.record_count);
    try std.testing.expectEqual(@as(usize, 0), session.storage.records[0].start);
    try std.testing.expectEqual(session.storage.records[0].len, session.storage.records[1].start);
    try std.testing.expectEqual(session.storage.records[1].start + session.storage.records[1].len, session.storage.records[2].start);
    try std.testing.expectEqual(session.storage.records[2].start + session.storage.records[2].len, session.history_used);
    try std.testing.expectEqualSlices(u8, "abc", session.storage.history[session.storage.records[0].start..][0..session.storage.records[0].len]);
    try std.testing.expectEqualSlices(u8, "aXc", session.storage.history[session.storage.records[1].start..][0..session.storage.records[1].len]);
    try std.testing.expectEqualSlices(u8, "aYc", session.storage.history[session.storage.records[2].start..][0..session.storage.records[2].len]);
}

test "failures preserve result decisions and generation" {
    var result: [8]u8 = undefined;
    var scratch: [8]u8 = undefined;
    var history: [8]u8 = undefined;
    var records: [2]Record = undefined;
    var session = try Session.init(.{ .base = "abc", .left = "abc", .right = "abc" }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records });
    const opened = session.identity();
    try std.testing.expectError(error.StaleGeneration, session.choose(opened.generation + 1, .left));
    try session.choose(opened.generation, .left);
    const before = session.identity();
    const state = session.current_state();
    try std.testing.expectError(error.HistoryFull, session.choose(before.generation, .left));
    try std.testing.expectEqualStrings("abc", session.result());
    try std.testing.expectEqual(state, session.current_state());
    try std.testing.expectEqual(before.generation, session.identity().generation);
}

test "failed branch mutation preserves redo history and generation exhaustion preserves state" {
    var result: [16]u8 = undefined;
    var scratch: [16]u8 = undefined;
    var history: [11]u8 = undefined;
    var records: [4]Record = undefined;
    var session = try Session.init(.{ .base = "abc", .left = "aXc", .right = "aYc" }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records });
    try session.choose(session.identity().generation, .left);
    try session.choose(session.identity().generation, .right);
    try session.undo(session.identity().generation);
    const before = session.identity();
    const history_before = history;
    const records_before = records;
    try std.testing.expectError(error.HistoryBytesFull, session.choose(before.generation, .both_left_right));
    try std.testing.expectEqual(before.generation, session.identity().generation);
    try std.testing.expectEqualSlices(u8, &history_before, &history);
    try std.testing.expectEqualSlices(Record, &records_before, &records);
    try std.testing.expectEqualStrings("aXc", session.result());
    try session.redo(session.identity().generation);
    try std.testing.expectEqualStrings("aYc", session.result());

    session.generation = std.math.maxInt(u64);
    const exhausted = session.current_state();
    try std.testing.expectError(error.GenerationExhausted, session.undo(session.generation));
    try std.testing.expectEqual(exhausted, session.current_state());
    try std.testing.expectEqual(std.math.maxInt(u64), session.identity().generation);
}

test "edits, aliasing, changed input, and redo exhaustion are safe" {
    var result: [16]u8 = undefined;
    var scratch: [16]u8 = undefined;
    var history: [64]u8 = undefined;
    var records: [5]Record = undefined;
    var input = [_]u8{ 'a', 'b', 'c' };
    var session = try Session.init(.{ .base = &input, .left = &input, .right = &input }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records });
    const edit = [_]bytes.Edit{.{ .start = 1, .end = 2, .replacement = "X" }};
    try session.apply_edits(session.identity().generation, &edit);
    try std.testing.expectEqualStrings("aXc", session.result());
    try session.undo(session.identity().generation);
    try session.redo(session.identity().generation);
    input[0] = 'z';
    const before = session.identity();
    try std.testing.expectError(error.ChangedInput, session.set_reviewed(before.generation, true));
    try std.testing.expectEqual(before.generation, session.identity().generation);

    var shared: [32]u8 = undefined;
    try std.testing.expectError(error.AliasedStorage, Session.init(.{ .base = "a", .left = "a", .right = "a" }, .{ .result = shared[0..8], .scratch = shared[4..12], .history = history[0..], .records = &records }));
}

test "storage and edit descriptors cannot alias scratch or inputs" {
    var result: [32]u8 = undefined;
    var scratch: [32]u8 = undefined;
    var history: [64]u8 = undefined;
    var records: [4]Record = undefined;
    try std.testing.expectError(error.AliasedStorage, Session.init(.{ .base = result[0..1], .left = result[0..1], .right = result[0..1] }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records }));
    try std.testing.expectError(error.AliasedStorage, Session.init(.{ .base = scratch[0..1], .left = scratch[0..1], .right = scratch[0..1] }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records }));
    try std.testing.expectError(error.AliasedStorage, Session.init(.{ .base = history[0..1], .left = history[0..1], .right = history[0..1] }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records }));
    var shared_history: [32]u8 = undefined;
    try std.testing.expectError(error.AliasedStorage, Session.init(.{ .base = "a", .left = "a", .right = "a" }, .{ .result = shared_history[0..8], .scratch = &scratch, .history = shared_history[4..], .records = &records }));

    var backing: [128]u8 align(@alignOf(bytes.Edit)) = undefined;
    var descriptor_session = try Session.init(.{ .base = "abc", .left = "abc", .right = "abc" }, .{ .result = &result, .scratch = &backing, .history = &history, .records = &records });
    const edits = std.mem.bytesAsSlice(bytes.Edit, backing[0..@sizeOf(bytes.Edit)]);
    edits[0] = .{ .start = 1, .end = 2, .replacement = "X" };
    const before = descriptor_session.identity();
    try std.testing.expectError(error.AliasedBuffers, descriptor_session.apply_edits(before.generation, edits));
    try std.testing.expectEqual(before.generation, descriptor_session.identity().generation);
    try std.testing.expectEqualStrings("abc", descriptor_session.result());

    var input_records = [_]Record{.{ .start = 0, .len = 0, .origin = .conflict, .reviewed = false, .unresolved = true }};
    const input_bytes = std.mem.sliceAsBytes(input_records[0..]);
    try std.testing.expectError(error.AliasedStorage, Session.init(.{ .base = input_bytes, .left = input_bytes, .right = input_bytes }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &input_records }));
}
