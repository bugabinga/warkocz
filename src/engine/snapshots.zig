const std = @import("std");

/// A caller-owned immutable snapshot slot. Payload storage belongs beside this state.
pub const Slot = struct {
    generation: u64 = 1,
    state: State = .free,
    lease_count: usize = 0,

    pub const State = enum { free, active, retiring };
};

pub const SnapshotId = struct {
    index: usize,
    generation: u64,
};

pub const WorkerId = struct {
    index: usize,
    generation: u64,
};

pub const Lease = struct {
    snapshot: SnapshotId,
    worker: WorkerId,
    token: u64,
};

/// Caller-owned bounded storage for issued and released lease tokens.
pub const LeaseRecord = struct {
    token: u64 = 0,
    snapshot: SnapshotId = .{ .index = 0, .generation = 0 },
    worker: WorkerId = .{ .index = 0, .generation = 0 },
    state: State = .free,

    const State = enum { free, active, released };
};

/// Caller-owned bounded storage for worker identities.
pub const WorkerRecord = struct {
    generation: u64 = 1,
    state: State = .free,

    pub const State = enum { free, active, cancelled };
};

pub const Error = error{
    NoSnapshotSlots,
    LeaseExhausted,
    WorkerExhausted,
    InvalidSnapshot,
    StaleSnapshot,
    InvalidWorker,
    WorkerCancelled,
    InvalidLease,
    LeaseReleased,
    ResultWorkerMismatch,
    UnexpectedSnapshot,
    GenerationExhausted,
    TokenExhausted,
    WorkerGenerationExhausted,
};

/// State protocol only: it neither copies nor transports snapshot bytes.
/// One application-state owner must serialize every call.
/// slots, lease_records, and workers must occupy non-overlapping backing arrays.
/// Their storage remains exclusively owned by this Pool; never reinitialize or reuse it while leases or readers live.
pub const Pool = struct {
    slots: []Slot,
    lease_records: []LeaseRecord,
    workers: []WorkerRecord,
    next_token: u64 = 1,

    pub fn init(slots: []Slot, lease_records: []LeaseRecord, workers: []WorkerRecord) Pool {
        for (slots) |*slot| slot.* = .{};
        for (lease_records) |*record| record.* = .{};
        for (workers) |*worker| worker.* = .{};
        return .{ .slots = slots, .lease_records = lease_records, .workers = workers };
    }

    /// Publish only after caller has finished writing associated payload bytes.
    pub fn publish(self: *Pool) Error!SnapshotId {
        for (self.slots, 0..) |*slot, index| {
            if (slot.state != .free) continue;
            std.debug.assert(slot.generation != 0);
            std.debug.assert(slot.lease_count == 0);
            slot.state = .active;
            return .{ .index = index, .generation = slot.generation };
        }
        return error.NoSnapshotSlots;
    }

    pub fn register_worker(self: *Pool) Error!WorkerId {
        for (self.workers, 0..) |*worker, index| {
            if (worker.state != .free) continue;
            std.debug.assert(worker.generation != 0);
            worker.state = .active;
            return .{ .index = index, .generation = worker.generation };
        }
        return error.WorkerExhausted;
    }

    /// Reject future work while retaining every acquired snapshot lease.
    pub fn cancel_worker(self: *Pool, worker: WorkerId) Error!void {
        const record = try self.current_worker(worker);
        if (record.state == .cancelled) return error.WorkerCancelled;
        if (record.state != .active) return error.InvalidWorker;
        std.debug.assert(record.generation == worker.generation);
        std.debug.assert(record.state == .active);
        record.state = .cancelled;
    }

    pub fn acquire(self: *Pool, snapshot: SnapshotId, worker: WorkerId) Error!Lease {
        _ = try self.active_worker(worker);
        const slot = try self.active_slot(snapshot);
        const record = self.free_lease_record() orelse return error.LeaseExhausted;
        if (self.next_token == std.math.maxInt(u64)) return error.TokenExhausted;
        std.debug.assert(slot.lease_count < std.math.maxInt(usize));
        std.debug.assert(record.state != .active);
        const lease = Lease{ .snapshot = snapshot, .worker = worker, .token = self.next_token };
        self.next_token += 1;
        record.* = .{ .token = lease.token, .snapshot = snapshot, .worker = worker, .state = .active };
        slot.lease_count += 1;
        std.debug.assert(same_lease(record.*, lease));
        std.debug.assert(slot.lease_count > 0 and slot.lease_count <= self.lease_records.len);
        return lease;
    }

    /// Prevent new readers; recycle after final release or caller-confirmed death.
    pub fn retire(self: *Pool, snapshot: SnapshotId) Error!void {
        const slot = try self.current_slot(snapshot);
        if (slot.state != .active) return error.StaleSnapshot;
        std.debug.assert(slot.generation == snapshot.generation);
        std.debug.assert(slot.lease_count <= self.lease_records.len);
        if (slot.lease_count == 0) return self.recycle(slot);
        slot.state = .retiring;
        std.debug.assert(slot.lease_count > 0);
        std.debug.assert(slot.generation == snapshot.generation);
    }

    /// Accept only a result tied to this active lease, worker, and expected snapshot.
    pub fn validate_result(self: *Pool, worker: WorkerId, lease: Lease, expected: SnapshotId) Error!void {
        _ = try self.active_worker(worker);
        const record = try self.active_lease_record(lease);
        if (!same_worker(record.worker, worker)) return error.ResultWorkerMismatch;
        if (!same_snapshot(record.snapshot, expected)) return error.UnexpectedSnapshot;
        _ = try self.active_slot(expected);
        std.debug.assert(same_lease(record.*, lease));
        std.debug.assert(same_snapshot(lease.snapshot, expected));
    }

    /// Release is allowed after cancellation because cancellation retains readers.
    pub fn release(self: *Pool, lease: Lease) Error!void {
        const record = self.lease_record(lease.token) orelse return error.InvalidLease;
        if (record.state == .released) return error.LeaseReleased;
        if (record.state != .active or !same_lease(record.*, lease)) return error.InvalidLease;
        const slot = try self.current_slot(lease.snapshot);
        if (slot.lease_count == 0) return error.InvalidLease;
        if (slot.state == .retiring and slot.lease_count == 1 and slot.generation == std.math.maxInt(u64)) {
            return error.GenerationExhausted;
        }
        std.debug.assert(record.state == .active);
        std.debug.assert(slot.lease_count > 0);
        const lease_count_before = slot.lease_count;
        record.state = .released;
        slot.lease_count -= 1;
        std.debug.assert(slot.lease_count + 1 == lease_count_before);
        if (slot.state == .retiring and slot.lease_count == 0) self.recycle(slot) catch unreachable;
    }

    /// Caller has independently confirmed death; this protocol performs no OS liveness check.
    pub fn release_dead_worker(self: *Pool, worker: WorkerId) Error!void {
        const worker_record = try self.current_worker(worker);
        if (worker_record.generation == std.math.maxInt(u64)) return error.WorkerGenerationExhausted;
        try self.ensure_death_can_release(worker);
        for (self.lease_records) |*record| {
            if (record.state != .active or !same_worker(record.worker, worker)) continue;
            const slot = &self.slots[record.snapshot.index];
            std.debug.assert(slot.generation == record.snapshot.generation);
            std.debug.assert(slot.lease_count > 0);
            const lease_count_before = slot.lease_count;
            record.state = .released;
            slot.lease_count -= 1;
            std.debug.assert(slot.lease_count + 1 == lease_count_before);
            if (slot.state == .retiring and slot.lease_count == 0) self.recycle(slot) catch unreachable;
        }
        for (self.lease_records) |record| {
            std.debug.assert(record.state != .active or !same_worker(record.worker, worker));
        }
        std.debug.assert(worker_record.state != .free);
        std.debug.assert(worker_record.generation == worker.generation);
        worker_record.state = .free;
        worker_record.generation += 1;
        std.debug.assert(worker_record.state == .free);
        std.debug.assert(worker_record.generation != worker.generation);
    }

    fn current_worker(self: *Pool, worker: WorkerId) Error!*WorkerRecord {
        if (worker.index >= self.workers.len) return error.InvalidWorker;
        const record = &self.workers[worker.index];
        if (record.state == .free or record.generation != worker.generation) return error.InvalidWorker;
        std.debug.assert(record.generation != 0);
        std.debug.assert(record.state != .free);
        return record;
    }

    fn active_worker(self: *Pool, worker: WorkerId) Error!*WorkerRecord {
        const record = try self.current_worker(worker);
        if (record.state == .cancelled) return error.WorkerCancelled;
        std.debug.assert(record.state == .active);
        return record;
    }

    fn current_slot(self: *Pool, snapshot: SnapshotId) Error!*Slot {
        if (snapshot.index >= self.slots.len) return error.InvalidSnapshot;
        const slot = &self.slots[snapshot.index];
        if (slot.generation != snapshot.generation) return error.StaleSnapshot;
        std.debug.assert(slot.generation != 0);
        std.debug.assert(slot.lease_count <= self.lease_records.len);
        std.debug.assert(slot.state != .free or slot.lease_count == 0);
        return slot;
    }

    fn active_slot(self: *Pool, snapshot: SnapshotId) Error!*Slot {
        const slot = try self.current_slot(snapshot);
        if (slot.state != .active) return error.StaleSnapshot;
        std.debug.assert(slot.generation == snapshot.generation);
        std.debug.assert(slot.state == .active);
        return slot;
    }

    fn active_lease_record(self: *Pool, lease: Lease) Error!*LeaseRecord {
        const record = self.lease_record(lease.token) orelse return error.InvalidLease;
        if (record.state == .released) return error.LeaseReleased;
        if (record.state != .active or !same_lease(record.*, lease)) return error.InvalidLease;
        std.debug.assert(record.state == .active);
        std.debug.assert(record.token == lease.token);
        return record;
    }

    fn free_lease_record(self: *Pool) ?*LeaseRecord {
        for (self.lease_records) |*record| {
            if (record.state != .active) return record;
        }
        return null;
    }

    fn lease_record(self: *Pool, token: u64) ?*LeaseRecord {
        for (self.lease_records) |*record| {
            if (record.token == token and record.state != .free) return record;
        }
        return null;
    }

    fn recycle(self: *Pool, slot: *Slot) Error!void {
        _ = self;
        if (slot.state != .active and slot.state != .retiring) return error.StaleSnapshot;
        if (slot.lease_count != 0) return error.StaleSnapshot;
        if (slot.generation == std.math.maxInt(u64)) return error.GenerationExhausted;
        const generation = slot.generation;
        std.debug.assert(slot.lease_count == 0);
        std.debug.assert(generation < std.math.maxInt(u64));
        slot.generation += 1;
        slot.state = .free;
        std.debug.assert(slot.generation == generation + 1);
        std.debug.assert(slot.state == .free and slot.lease_count == 0);
    }

    /// Bounded O(slots × lease_records) preflight runs only during confirmed-death cleanup.
    /// It preserves all leases and worker state when final retirement would exhaust a generation.
    fn ensure_death_can_release(self: *Pool, worker: WorkerId) Error!void {
        for (self.lease_records) |record| {
            if (record.state != .active or !same_worker(record.worker, worker)) continue;
            _ = try self.current_slot(record.snapshot);
        }
        for (self.slots, 0..) |*slot, index| {
            if (slot.state != .retiring or slot.generation != std.math.maxInt(u64)) continue;
            const snapshot = SnapshotId{ .index = index, .generation = slot.generation };
            if (slot.lease_count == self.worker_lease_count(worker, snapshot)) return error.GenerationExhausted;
        }
    }

    fn worker_lease_count(self: *Pool, worker: WorkerId, snapshot: SnapshotId) usize {
        var count: usize = 0;
        for (self.lease_records) |record| {
            if (record.state == .active and same_worker(record.worker, worker) and same_snapshot(record.snapshot, snapshot)) {
                count += 1;
            }
        }
        return count;
    }
};

fn same_worker(left: WorkerId, right: WorkerId) bool {
    return left.index == right.index and left.generation == right.generation;
}

fn same_snapshot(left: SnapshotId, right: SnapshotId) bool {
    return left.index == right.index and left.generation == right.generation;
}

fn same_lease(record: LeaseRecord, lease: Lease) bool {
    return record.token == lease.token and same_worker(record.worker, lease.worker) and
        same_snapshot(record.snapshot, lease.snapshot);
}

test "state trace rejects result without matching active lease and expected snapshot" {
    var slots: [2]Slot = undefined;
    var leases: [2]LeaseRecord = undefined;
    var workers: [2]WorkerRecord = undefined;
    var pool = Pool.init(&slots, &leases, &workers);
    const owner = try pool.register_worker();
    const foreign = try pool.register_worker();
    const first = try pool.publish();
    const second = try pool.publish();
    const lease = try pool.acquire(first, owner);
    try std.testing.expectError(error.ResultWorkerMismatch, pool.validate_result(foreign, lease, first));
    try std.testing.expectError(error.UnexpectedSnapshot, pool.validate_result(owner, lease, second));
    try pool.validate_result(owner, lease, first);
    try pool.release(lease);
}

test "state trace cancellation rejects work yet retains and permits release" {
    var slots: [1]Slot = undefined;
    var leases: [1]LeaseRecord = undefined;
    var workers: [1]WorkerRecord = undefined;
    var pool = Pool.init(&slots, &leases, &workers);
    const worker = try pool.register_worker();
    const snapshot = try pool.publish();
    const lease = try pool.acquire(snapshot, worker);
    try pool.retire(snapshot);
    try pool.cancel_worker(worker);
    try std.testing.expectError(error.WorkerCancelled, pool.acquire(snapshot, worker));
    try std.testing.expectError(error.WorkerCancelled, pool.validate_result(worker, lease, snapshot));
    try std.testing.expectError(error.WorkerExhausted, pool.register_worker());
    try std.testing.expectError(error.NoSnapshotSlots, pool.publish());
    try pool.release(lease);
    _ = try pool.publish();
    try pool.release_dead_worker(worker);
    _ = try pool.register_worker();
}

test "state trace reused lease record rejects old lease" {
    var slots: [1]Slot = undefined;
    var leases: [1]LeaseRecord = undefined;
    var workers: [1]WorkerRecord = undefined;
    var pool = Pool.init(&slots, &leases, &workers);
    const worker = try pool.register_worker();
    const snapshot = try pool.publish();
    const old_lease = try pool.acquire(snapshot, worker);
    try pool.release(old_lease);
    const new_lease = try pool.acquire(snapshot, worker);
    try std.testing.expectError(error.InvalidLease, pool.release(old_lease));
    try pool.release(new_lease);
}

test "state trace retirement waits for every reader or confirmed death" {
    var slots: [1]Slot = undefined;
    var leases: [2]LeaseRecord = undefined;
    var workers: [2]WorkerRecord = undefined;
    var pool = Pool.init(&slots, &leases, &workers);
    const first_worker = try pool.register_worker();
    const second_worker = try pool.register_worker();
    const snapshot = try pool.publish();
    const first_lease = try pool.acquire(snapshot, first_worker);
    _ = try pool.acquire(snapshot, second_worker);
    try pool.retire(snapshot);
    try pool.release(first_lease);
    try std.testing.expectError(error.NoSnapshotSlots, pool.publish());
    try pool.release_dead_worker(second_worker);
    _ = try pool.publish();
}

test "state trace overflow rollback preserves leases and worker" {
    var slots: [1]Slot = undefined;
    var leases: [1]LeaseRecord = undefined;
    var workers: [1]WorkerRecord = undefined;
    var pool = Pool.init(&slots, &leases, &workers);
    const worker = try pool.register_worker();
    pool.slots[0].generation = std.math.maxInt(u64);
    const exhausted = try pool.publish();
    const lease = try pool.acquire(exhausted, worker);
    try pool.retire(exhausted);
    try std.testing.expectError(error.GenerationExhausted, pool.release(lease));
    try std.testing.expectEqual(@as(usize, 1), pool.slots[0].lease_count);
    try std.testing.expectError(error.GenerationExhausted, pool.release_dead_worker(worker));
    try std.testing.expectEqual(WorkerRecord.State.active, pool.workers[0].state);
    try std.testing.expectEqual(@as(usize, 1), pool.slots[0].lease_count);
}

test "worker generation exhaustion rolls back confirmed-death cleanup" {
    var slots: [1]Slot = undefined;
    var leases: [1]LeaseRecord = undefined;
    var workers: [1]WorkerRecord = undefined;
    var pool = Pool.init(&slots, &leases, &workers);
    pool.workers[0].generation = std.math.maxInt(u64);
    const worker = try pool.register_worker();
    const snapshot = try pool.publish();
    const lease = try pool.acquire(snapshot, worker);
    const lease_before = pool.lease_records[0];
    try std.testing.expectError(error.WorkerGenerationExhausted, pool.release_dead_worker(worker));
    try std.testing.expectEqual(WorkerRecord.State.active, pool.workers[0].state);
    try std.testing.expectEqual(worker.generation, pool.workers[0].generation);
    try std.testing.expectEqual(@as(usize, 1), pool.slots[0].lease_count);
    try std.testing.expectEqual(lease_before, pool.lease_records[0]);
    try pool.release(lease);
}

test "invalid indices and stale generations are rejected" {
    var slots: [1]Slot = undefined;
    var leases: [1]LeaseRecord = undefined;
    var workers: [1]WorkerRecord = undefined;
    var pool = Pool.init(&slots, &leases, &workers);
    const worker = try pool.register_worker();
    const snapshot = try pool.publish();
    try std.testing.expectError(error.InvalidSnapshot, pool.acquire(.{ .index = 1, .generation = 1 }, worker));
    try std.testing.expectError(error.InvalidWorker, pool.acquire(snapshot, .{ .index = 1, .generation = 1 }));
    try pool.retire(snapshot);
    const replacement = try pool.publish();
    try std.testing.expectError(error.StaleSnapshot, pool.acquire(snapshot, worker));
    try std.testing.expect(replacement.generation != snapshot.generation);
}
