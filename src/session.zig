const std = @import("std");
const bytes = @import("bytes.zig");
const text_merge = @import("engine/text_merge.zig");
const multihunk = @import("engine/multihunk.zig");
const json_merge = @import("engine/json_merge.zig");
const zig_merge = @import("engine/zig_merge.zig");

pub const Mode = enum { two_way, three_way };
/// Borrowed immutable versions of one logical file.
/// In two-way mode, base is an unused empty storage placeholder, not an ancestor.
pub const Inputs = struct { base: []const u8, left: []const u8, right: []const u8 };
pub const InputIdentity = struct { base: ?[32]u8, left: [32]u8, right: [32]u8 };
pub const Engine = struct { name: []const u8, version: []const u8 };
pub const DegradedReason = enum { resource_limited, ambiguous_alignment, json_malformed, json_unsupported_root, json_duplicate_key, json_member_set_changed, json_member_order_changed, json_ambiguous_formatting, zig_malformed_source, zig_unsupported_declaration, zig_duplicate_name, zig_declaration_set_changed, zig_declaration_order_changed, zig_ambiguous_shell };
pub const Identity = struct { mode: Mode, inputs: InputIdentity, engine: Engine, generation: u64 };

pub const Origin = enum { two_way_right, automatic_unchanged, automatic_left, automatic_right, automatic_identical, automatic_composed, conflict, manual_base, manual_left, manual_right, manual_both_left_right, manual_both_right_left, edited };
pub const Choice = enum { base, left, right, both_left_right, both_right_left };

/// Caller-owned history metadata. Its associated result bytes live in Storage.history.
pub const Record = struct { start: usize, len: usize, origin: Origin, reviewed: bool, unresolved: bool };
/// Each backing region must remain exclusively owned and stable for Session's lifetime.
/// Regions must not overlap inputs or each other; do not reinitialize or reuse them while readers retain Session views.
pub const Storage = struct {
    result: []u8,
    scratch: []u8,
    history: []u8,
    records: []Record,
    multi_storage: ?multihunk.Storage = null,
    multi_conflicts: []multihunk.Conflict = &.{},
    multi_max_work: usize = 0,
    /// Present only for source paths explicitly selected as JSON by the caller.
    json_workspace: ?*json_merge.Workspace = null,
    /// Present only for source paths explicitly selected as Zig by the caller.
    zig_workspace: ?*zig_merge.Workspace = null,
};
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
    NoBase,
} || bytes.ApplyError || text_merge.MergeError || multihunk.Error || json_merge.Error || zig_merge.Error;

/// Bounded in-memory state only. It neither persists drafts, saves files, nor completes operations.
/// Input hashing is synchronous O(base + left + right) at open and before every mutation.
/// Callers must schedule this core API away from latency-sensitive UI work.
pub const Session = struct {
    mode: Mode,
    inputs: Inputs,
    input_identity: InputIdentity,
    storage: Storage,
    conflict: ?text_merge.Conflict,
    state: State,
    record_count: usize,
    cursor: usize,
    history_used: usize,
    generation: u64 = 1,
    engine_used: Engine = engine,
    degraded_reason: ?DegradedReason = null,
    left_changes: []const multihunk.Hunk = &.{},
    right_changes: []const multihunk.Hunk = &.{},

    pub const engine = Engine{ .name = "text_merge", .version = "1" };
    pub const multi_hunk_engine = Engine{ .name = "multihunk", .version = "1" };
    pub const degraded_byte_review_engine = Engine{ .name = "byte_review", .version = "1" };
    pub const json_engine = Engine{ .name = "json_root_object_merge", .version = "1" };
    pub const zig_engine = Engine{ .name = "zig_declaration_merge", .version = "1" };

    /// Opens one file with conservative automatic text merge.
    pub fn init(inputs: Inputs, storage: Storage) Error!Session {
        var session = try init_storage(inputs, .three_way, storage);
        if (storage.json_workspace) |workspace| {
            try init_json(&session, workspace);
        } else if (storage.zig_workspace) |workspace| {
            try init_zig(&session, workspace);
        } else if (storage.multi_storage) |multi_storage| {
            init_multihunk(&session, multi_storage, storage.multi_conflicts, storage.multi_max_work) catch |err| {
                const reason = degraded_reason_for(err) orelse return err;
                try init_degraded_byte_review(&session, reason);
            };
        } else {
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
        }
        try session.commit_candidate(session.state);
        std.debug.assert(session.record_count == 1);
        std.debug.assert(session.cursor == 0);
        std.debug.assert(session.history_used == session.storage.records[0].len);
        std.debug.assert(session.generation == 1);
        return session;
    }

    /// Opens explicit sides without an ancestor or automatic merge; result starts at right.
    pub fn init_two_way(left: []const u8, right: []const u8, storage: Storage) Error!Session {
        var session = try init_storage(.{ .base = "", .left = left, .right = right }, .two_way, storage);
        if (right.len > storage.scratch.len) return error.ScratchTooSmall;
        @memcpy(storage.scratch[0..right.len], right);
        try session.commit_candidate(.{ .origin = .two_way_right, .reviewed = false, .unresolved = false, .written = right.len });
        std.debug.assert(session.conflict == null);
        std.debug.assert(session.record_count == 1 and session.cursor == 0);
        std.debug.assert(session.generation == 1);
        return session;
    }

    fn init_storage(inputs: Inputs, mode: Mode, storage: Storage) Error!Session {
        try validate_storage(inputs, storage);
        std.debug.assert(mode != .two_way or inputs.base.len == 0);
        const input_identity = hash_inputs(inputs, mode);
        std.debug.assert((mode == .three_way) == (input_identity.base != null));
        return .{ .mode = mode, .inputs = inputs, .input_identity = input_identity, .storage = storage, .conflict = null, .state = undefined, .record_count = 0, .cursor = 0, .history_used = 0 };
    }

    pub fn identity(self: *const Session) Identity {
        std.debug.assert(self.record_count > 0);
        std.debug.assert(self.cursor < self.record_count);
        return .{ .mode = self.mode, .inputs = self.input_identity, .engine = self.engine_used, .generation = self.generation };
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

    pub fn degradation(self: *const Session) ?DegradedReason {
        std.debug.assert(self.record_count > 0);
        std.debug.assert(self.degraded_reason == null or self.state.unresolved);
        return self.degraded_reason;
    }

    /// Verifies caller-owned input bytes before a save snapshot leaves memory.
    pub fn preflight_save(self: *const Session, expected_generation: u64) Error!void {
        try self.prepare(expected_generation);
        std.debug.assert(expected_generation == self.generation);
        std.debug.assert(!self.state.unresolved);
    }

    /// Selects a complete input. Both is explicitly a byte composition, not correctness.
    pub fn choose(self: *Session, expected_generation: u64, choice: Choice) Error!void {
        try self.prepare(expected_generation);
        const candidate = switch (choice) {
            .base => if (self.mode == .two_way) return error.NoBase else self.inputs.base,
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

    /// Applies decrypted recovery bytes only after the newly opened originals match
    /// their recorded identities.  Recovery never claims replayed provenance or resolution.
    pub fn restore_recovered(self: *Session, expected_generation: u64, recorded_identity: InputIdentity, recovered_result: []const u8) Error!void {
        try self.prepare(expected_generation);
        if (!std.meta.eql(self.input_identity, recorded_identity)) return error.ChangedInput;
        if (recovered_result.len > self.storage.scratch.len) return error.ScratchTooSmall;
        @memcpy(self.storage.scratch[0..recovered_result.len], recovered_result);
        try self.commit_candidate(.{ .origin = .edited, .reviewed = false, .unresolved = true, .written = recovered_result.len });
        std.debug.assert(self.state.unresolved and !self.state.reviewed);
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

    /// Restores original two-way right, automatic decision, or explicit conflict state.
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
        if (!std.meta.eql(self.input_identity, hash_inputs(self.inputs, self.mode))) return error.ChangedInput;
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

fn degraded_reason_for(err: Error) ?DegradedReason {
    return switch (err) {
        error.LineCapacity, error.MatrixCapacity, error.HunkCapacity, error.WorkExhausted, error.DestinationTooSmall, error.ConflictCapacity, error.OutputTooLarge => .resource_limited,
        error.AmbiguousAlignment => .ambiguous_alignment,
        else => null,
    };
}

fn init_degraded_byte_review(session: *Session, reason: DegradedReason) Error!void {
    if (session.inputs.base.len > session.storage.scratch.len) return error.ScratchTooSmall;
    @memcpy(session.storage.scratch[0..session.inputs.base.len], session.inputs.base);
    session.engine_used = Session.degraded_byte_review_engine;
    session.degraded_reason = reason;
    session.state = .{ .origin = .conflict, .reviewed = false, .unresolved = true, .written = session.inputs.base.len };
    std.debug.assert(session.state.written == session.inputs.base.len);
    std.debug.assert(session.degraded_reason != null and session.state.unresolved);
}

fn init_json(active: *Session, workspace: *json_merge.Workspace) Error!void {
    const outcome = json_merge.merge(active.inputs.base, active.inputs.left, active.inputs.right, active.storage.scratch, workspace) catch |err| switch (err) {
        error.CapacityExceeded => {
            try init_degraded_byte_review(active, .resource_limited);
            return;
        },
        else => return err,
    };
    active.engine_used = Session.json_engine;
    switch (outcome) {
        .clean => |written| active.state = .{ .origin = json_origin(active.inputs), .reviewed = false, .unresolved = false, .written = written },
        .conflict => {
            if (active.inputs.base.len > active.storage.scratch.len) return error.ScratchTooSmall;
            @memcpy(active.storage.scratch[0..active.inputs.base.len], active.inputs.base);
            active.state = .{ .origin = .conflict, .reviewed = false, .unresolved = true, .written = active.inputs.base.len };
        },
        .degraded => |reason| try init_degraded_byte_review(active, json_reason(reason)),
    }
}

fn init_zig(active: *Session, workspace: *zig_merge.Workspace) Error!void {
    const outcome = zig_merge.merge(active.inputs.base, active.inputs.left, active.inputs.right, active.storage.scratch, workspace) catch |err| switch (err) {
        error.CapacityExceeded => {
            try init_degraded_byte_review(active, .resource_limited);
            return;
        },
        else => return err,
    };
    active.engine_used = Session.zig_engine;
    switch (outcome) {
        .clean => |written| active.state = .{ .origin = multi_origin(active.inputs), .reviewed = false, .unresolved = false, .written = written },
        .conflict => {
            if (active.inputs.base.len > active.storage.scratch.len) return error.ScratchTooSmall;
            @memcpy(active.storage.scratch[0..active.inputs.base.len], active.inputs.base);
            active.state = .{ .origin = .conflict, .reviewed = false, .unresolved = true, .written = active.inputs.base.len };
        },
        .degraded => |reason| try init_degraded_byte_review(active, zig_reason(reason)),
    }
}

fn zig_reason(reason: zig_merge.Reason) DegradedReason {
    return switch (reason) {
        .malformed_source => .zig_malformed_source,
        .unsupported_declaration => .zig_unsupported_declaration,
        .duplicate_name => .zig_duplicate_name,
        .declaration_set_changed => .zig_declaration_set_changed,
        .declaration_order_changed => .zig_declaration_order_changed,
        .ambiguous_shell => .zig_ambiguous_shell,
        .resource_limit => .resource_limited,
    };
}

fn json_origin(inputs: Inputs) Origin {
    if (std.mem.eql(u8, inputs.left, inputs.right)) return .automatic_identical;
    if (std.mem.eql(u8, inputs.left, inputs.base)) return .automatic_right;
    if (std.mem.eql(u8, inputs.right, inputs.base)) return .automatic_left;
    return .automatic_composed;
}

fn json_reason(reason: json_merge.Reason) DegradedReason {
    return switch (reason) {
        .malformed_json => .json_malformed,
        .unsupported_root => .json_unsupported_root,
        .duplicate_key => .json_duplicate_key,
        .member_set_changed => .json_member_set_changed,
        .member_order_changed => .json_member_order_changed,
        .ambiguous_formatting => .json_ambiguous_formatting,
        .resource_limit => .resource_limited,
    };
}

fn init_multihunk(session: *Session, storage: multihunk.Storage, conflicts: []multihunk.Conflict, max_work: usize) Error!void {
    if (max_work == 0) return error.WorkExhausted;
    const outcome = try multihunk.merge(session.inputs.base, session.inputs.left, session.inputs.right, storage, session.storage.scratch, conflicts, max_work);
    session.engine_used = Session.multi_hunk_engine;
    switch (outcome) {
        .clean => |clean| {
            session.left_changes = clean.left_hunks;
            session.right_changes = clean.right_hunks;
            session.state = .{ .origin = multi_origin(session.inputs), .reviewed = false, .unresolved = false, .written = clean.written };
        },
        .conflict => |found| {
            if (session.inputs.base.len > session.storage.scratch.len) return error.ScratchTooSmall;
            @memcpy(session.storage.scratch[0..session.inputs.base.len], session.inputs.base);
            const first = found[0];
            session.conflict = .{ .base = .{ .start = first.base.start, .end = first.base.end }, .left = .{ .start = first.left.start, .end = first.left.end }, .right = .{ .start = first.right.start, .end = first.right.end } };
            session.state = .{ .origin = .conflict, .reviewed = false, .unresolved = true, .written = session.inputs.base.len };
        },
    }
}

fn multi_origin(inputs: Inputs) Origin {
    if (std.mem.eql(u8, inputs.left, inputs.right)) return .automatic_identical;
    if (std.mem.eql(u8, inputs.left, inputs.base)) return .automatic_right;
    if (std.mem.eql(u8, inputs.right, inputs.base)) return .automatic_left;
    return .automatic_composed;
}

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

fn hash_inputs(inputs: Inputs, mode: Mode) InputIdentity {
    var identity: InputIdentity = .{ .base = null, .left = undefined, .right = undefined };
    if (mode == .three_way) {
        var base: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(inputs.base, &base, .{});
        identity.base = base;
    }
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

test "explicit JSON workspace composes independent root-field edits" {
    var result: [64]u8 = undefined;
    var scratch: [64]u8 = undefined;
    var history: [128]u8 = undefined;
    var records: [4]Record = undefined;
    var base_members: [4]json_merge.Member = undefined;
    var left_members: [4]json_merge.Member = undefined;
    var right_members: [4]json_merge.Member = undefined;
    var base_keys: [32]u8 = undefined;
    var left_keys: [32]u8 = undefined;
    var right_keys: [32]u8 = undefined;
    var scanner: [256]u8 = undefined;
    var workspace = json_merge.Workspace{ .base = .{ .members = &base_members, .keys = &base_keys }, .left = .{ .members = &left_members, .keys = &left_keys }, .right = .{ .members = &right_members, .keys = &right_keys }, .scanner_memory = &scanner };
    const active = try Session.init(.{ .base = "{\"a\":1,\"b\":1}", .left = "{\"a\":2,\"b\":1}", .right = "{\"a\":1,\"b\":2}" }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records, .json_workspace = &workspace });
    try std.testing.expectEqual(Session.json_engine, active.identity().engine);
    try std.testing.expectEqualStrings("{\"a\":2,\"b\":2}", active.result());
    try std.testing.expect(!active.current_state().unresolved);
}

test "JSON budget fallback retains exact bytes and unresolved session decisions" {
    var result: [32]u8 = @splat(0xa5);
    var scratch: [32]u8 = undefined;
    var history: [128]u8 = undefined;
    var records: [4]Record = undefined;
    var base_members: [2]json_merge.Member = undefined;
    var left_members: [2]json_merge.Member = undefined;
    var right_members: [2]json_merge.Member = undefined;
    var base_keys: [16]u8 = undefined;
    var left_keys: [16]u8 = undefined;
    var right_keys: [16]u8 = undefined;
    var scanner: [256]u8 = undefined;
    var workspace = json_merge.Workspace{ .base = .{ .members = &base_members, .keys = &base_keys }, .left = .{ .members = &left_members, .keys = &left_keys }, .right = .{ .members = &right_members, .keys = &right_keys }, .scanner_memory = &scanner, .max_work = 0 };
    var active = try Session.init(.{ .base = "{\"a\":1}", .left = "{\"a\":2}", .right = "{\"a\":3}" }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records, .json_workspace = &workspace });
    try std.testing.expectEqual(Session.degraded_byte_review_engine, active.identity().engine);
    try std.testing.expectEqual(DegradedReason.resource_limited, active.degradation().?);
    try std.testing.expect(active.current_state().unresolved);
    try std.testing.expectEqualStrings("{\"a\":1}", active.result());
    try active.choose(active.identity().generation, .left);
    try std.testing.expectEqualStrings("{\"a\":2}", active.result());
    try std.testing.expect(!active.current_state().unresolved);
}

test "multi-hunk merge retains exact change navigation provenance" {
    var result: [64]u8 = undefined;
    var scratch: [64]u8 = undefined;
    var history: [256]u8 = undefined;
    var records: [8]Record = undefined;
    var left_base: [4]multihunk.Hunk = undefined;
    var right_base: [4]multihunk.Hunk = undefined;
    var left_lines: [4]@import("engine/diff.zig").Line = undefined;
    var left_other_lines: [4]@import("engine/diff.zig").Line = undefined;
    var right_lines: [4]@import("engine/diff.zig").Line = undefined;
    var right_other_lines: [4]@import("engine/diff.zig").Line = undefined;
    var left_cells: [25]@import("engine/diff.zig").Cell = undefined;
    var right_cells: [25]@import("engine/diff.zig").Cell = undefined;
    var conflicts: [2]multihunk.Conflict = undefined;
    const storage = Storage{ .result = &result, .scratch = &scratch, .history = &history, .records = &records, .multi_storage = .{ .left = .{ .base_lines = &left_lines, .other_lines = &left_other_lines, .cells = &left_cells }, .right = .{ .base_lines = &right_lines, .other_lines = &right_other_lines, .cells = &right_cells }, .left_hunks = &left_base, .right_hunks = &right_base }, .multi_conflicts = &conflicts, .multi_max_work = 500 };
    const active = try Session.init(.{ .base = "a\nb\nc\n", .left = "A\nb\nc\n", .right = "a\nb\nC\n" }, storage);
    try std.testing.expectEqual(Session.multi_hunk_engine, active.identity().engine);
    try std.testing.expectEqualStrings("A\nb\nC\n", active.result());
    try std.testing.expectEqual(@as(usize, 1), active.left_changes.len);
    try std.testing.expectEqual(@as(usize, 1), active.right_changes.len);
}

test "Zig declaration session composes independent declarations and retains input identities" {
    const base = "// preserved\r\npub fn alpha() u8 { return 1; }\r\npub fn beta() u8 { return 1; }\r\n";
    const left = "// preserved\r\npub fn alpha() u8 { return 2; }\r\npub fn beta() u8 { return 1; }\r\n";
    const right = "// preserved\r\npub fn alpha() u8 { return 1; }\r\npub fn beta() u8 { return 3; }\r\n";
    const expected = "// preserved\r\npub fn alpha() u8 { return 2; }\r\npub fn beta() u8 { return 3; }\r\n";
    var result: [256]u8 = undefined;
    var scratch: [256]u8 = undefined;
    var history: [512]u8 = undefined;
    var records: [4]Record = undefined;
    var declarations: [3][4]zig_merge.Declaration = undefined;
    var names: [3][64]u8 = undefined;
    var parser: [8192]u8 = undefined;
    var workspace = zig_merge.Workspace{ .base = .{ .declarations = &declarations[0], .names = &names[0] }, .left = .{ .declarations = &declarations[1], .names = &names[1] }, .right = .{ .declarations = &declarations[2], .names = &names[2] }, .scratch_memory = &parser };
    var active = try Session.init(.{ .base = base, .left = left, .right = right }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records, .zig_workspace = &workspace });
    const identity = active.identity();
    try std.testing.expectEqual(Session.zig_engine, identity.engine);
    try std.testing.expectEqualStrings(expected, active.result());
    try std.testing.expect(!active.current_state().unresolved);
    try std.testing.expectEqual(hash_inputs(.{ .base = base, .left = left, .right = right }, .three_way), identity.inputs);
}

test "malformed Zig source falls back to unresolved exact bytes" {
    var result: [64]u8 = undefined;
    var scratch: [64]u8 = undefined;
    var history: [128]u8 = undefined;
    var records: [4]Record = undefined;
    var declarations: [3][4]zig_merge.Declaration = undefined;
    var names: [3][64]u8 = undefined;
    var parser: [8192]u8 = undefined;
    var workspace = zig_merge.Workspace{ .base = .{ .declarations = &declarations[0], .names = &names[0] }, .left = .{ .declarations = &declarations[1], .names = &names[1] }, .right = .{ .declarations = &declarations[2], .names = &names[2] }, .scratch_memory = &parser };
    const original = "pub fn broken( {";
    var active = try Session.init(.{ .base = original, .left = original, .right = original }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records, .zig_workspace = &workspace });
    try std.testing.expectEqual(Session.degraded_byte_review_engine, active.identity().engine);
    try std.testing.expectEqual(DegradedReason.zig_malformed_source, active.degradation().?);
    try std.testing.expect(active.current_state().unresolved);
    try std.testing.expectEqualStrings(original, active.result());
}

test "multi-hunk capacity opens lossless unresolved byte review" {
    var base: [258]u8 = undefined;
    var left: [258]u8 = undefined;
    var right: [258]u8 = undefined;
    for (0..129) |index| {
        base[index * 2] = 'b';
        left[index * 2] = 'l';
        right[index * 2] = 'r';
        base[index * 2 + 1] = '\n';
        left[index * 2 + 1] = '\n';
        right[index * 2 + 1] = '\n';
    }
    var result: [258]u8 = undefined;
    var scratch: [258]u8 = undefined;
    var history: [516]u8 = undefined;
    var records: [4]Record = undefined;
    var left_base: [128]multihunk.Hunk = undefined;
    var right_base: [128]multihunk.Hunk = undefined;
    var left_lines: [128]@import("engine/diff.zig").Line = undefined;
    var left_other_lines: [128]@import("engine/diff.zig").Line = undefined;
    var right_lines: [128]@import("engine/diff.zig").Line = undefined;
    var right_other_lines: [128]@import("engine/diff.zig").Line = undefined;
    var left_cells: [1]@import("engine/diff.zig").Cell = undefined;
    var right_cells: [1]@import("engine/diff.zig").Cell = undefined;
    var conflicts: [128]multihunk.Conflict = undefined;
    var active = try Session.init(.{ .base = &base, .left = &left, .right = &right }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records, .multi_storage = .{ .left = .{ .base_lines = &left_lines, .other_lines = &left_other_lines, .cells = &left_cells }, .right = .{ .base_lines = &right_lines, .other_lines = &right_other_lines, .cells = &right_cells }, .left_hunks = &left_base, .right_hunks = &right_base }, .multi_conflicts = &conflicts, .multi_max_work = 1 });
    try std.testing.expectEqual(Session.degraded_byte_review_engine, active.identity().engine);
    try std.testing.expectEqual(DegradedReason.resource_limited, active.degradation().?);
    try std.testing.expect(active.current_state().unresolved);
    try std.testing.expectEqualSlices(u8, &base, active.result());
    try std.testing.expectEqual(@as(usize, 0), active.left_changes.len);
    try active.choose(active.identity().generation, .left);
    try std.testing.expect(!active.current_state().unresolved);
    try std.testing.expectEqualSlices(u8, &left, active.result());
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

test "two-way dissimilar sides start at exact right without an ancestor or conflict" {
    var result: [32]u8 = undefined;
    var scratch: [32]u8 = undefined;
    var history: [128]u8 = undefined;
    var records: [8]Record = undefined;
    var session = try Session.init_two_way("left\r\n", "\x00right\xff", .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records });
    try std.testing.expectEqual(Mode.two_way, session.mode);
    try std.testing.expectEqual(Mode.two_way, session.identity().mode);
    try std.testing.expect(session.identity().inputs.base == null);
    try std.testing.expect(session.conflict == null);
    try std.testing.expectEqualStrings("\x00right\xff", session.result());
    try std.testing.expectEqual(State{ .origin = .two_way_right, .reviewed = false, .unresolved = false, .written = 7 }, session.current_state());
    try session.choose(session.identity().generation, .left);
    try std.testing.expectEqualStrings("left\r\n", session.result());
    try session.reset_original(session.identity().generation);
    try std.testing.expectEqualStrings("\x00right\xff", session.result());
    try std.testing.expectEqual(Origin.two_way_right, session.current_state().origin);
    try std.testing.expect(!session.current_state().unresolved);
    try std.testing.expect(session.conflict == null);
}

test "two-way base rejection preserves state storage and redo" {
    var result: [16]u8 = @splat(0);
    var scratch: [16]u8 = @splat(0);
    var history: [64]u8 = @splat(0);
    var records: [4]Record = @splat(.{ .start = 0, .len = 0, .origin = .two_way_right, .reviewed = false, .unresolved = false });
    var session = try Session.init_two_way("left", "right", .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records });
    try session.choose(session.identity().generation, .left);
    try session.undo(session.identity().generation);
    const before = session;
    const result_before = result;
    const scratch_before = scratch;
    const history_before = history;
    const records_before = records;
    try std.testing.expectError(error.NoBase, session.choose(session.identity().generation, .base));
    try std.testing.expectEqualDeep(before, session);
    try std.testing.expectEqualSlices(u8, &result_before, &result);
    try std.testing.expectEqualSlices(u8, &scratch_before, &scratch);
    try std.testing.expectEqualSlices(u8, &history_before, &history);
    try std.testing.expectEqualSlices(Record, &records_before, &records);
    try session.redo(session.identity().generation);
    try std.testing.expectEqualStrings("left", session.result());
}

test "two-way SHA256 identities and mode remain stable through history" {
    var result: [16]u8 = undefined;
    var scratch: [16]u8 = undefined;
    var history: [128]u8 = undefined;
    var records: [8]Record = undefined;
    var session = try Session.init_two_way("abc", "right", .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records });
    const opened = session.identity();
    const abc_sha256 = [_]u8{ 0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad };
    var right_sha256: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("right", &right_sha256, .{});
    try std.testing.expectEqualSlices(u8, &abc_sha256, &opened.inputs.left);
    try std.testing.expectEqualSlices(u8, &right_sha256, &opened.inputs.right);
    try session.choose(opened.generation, .left);
    try session.undo(session.identity().generation);
    try std.testing.expectEqualStrings("right", session.result());
    try std.testing.expectEqual(Origin.two_way_right, session.current_state().origin);
    try std.testing.expectEqual(opened.inputs, session.identity().inputs);
    try std.testing.expectEqual(opened.mode, session.identity().mode);
    try session.redo(session.identity().generation);
    try std.testing.expectEqualStrings("abc", session.result());
    try std.testing.expectEqual(Origin.manual_left, session.current_state().origin);
    try session.reset_original(session.identity().generation);
    try std.testing.expectEqualStrings("right", session.result());
    try std.testing.expectEqual(opened.inputs, session.identity().inputs);
    try std.testing.expectEqual(opened.mode, session.identity().mode);
    try std.testing.expectEqual(opened.engine, session.identity().engine);
    try std.testing.expectEqual(opened.generation + 4, session.identity().generation);
}

test "two-way empty sides differ from a real empty three-way base" {
    var result: [8]u8 = undefined;
    var scratch: [8]u8 = undefined;
    var history: [32]u8 = undefined;
    var records: [4]Record = undefined;
    const storage = Storage{ .result = &result, .scratch = &scratch, .history = &history, .records = &records };
    const two_way_identity = identity: {
        var session = try Session.init_two_way("", "", storage);
        try std.testing.expectEqualStrings("", session.result());
        try session.choose(session.identity().generation, .left);
        try session.reset_original(session.identity().generation);
        try std.testing.expectEqual(Origin.two_way_right, session.current_state().origin);
        break :identity session.identity();
    };
    var session = try Session.init(.{ .base = "", .left = "", .right = "" }, storage);
    try std.testing.expectEqual(Mode.three_way, session.identity().mode);
    try std.testing.expect(session.identity().inputs.base != null);
    try std.testing.expect(!std.meta.eql(two_way_identity.inputs, session.identity().inputs));
    try session.choose(session.identity().generation, .base);
    try std.testing.expectEqual(Origin.manual_base, session.current_state().origin);
}
