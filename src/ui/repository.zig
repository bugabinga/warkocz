const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl3");
const invocation = @import("../invocation.zig");
const files = @import("../files.zig");
const inspect = @import("../vcs/inspect.zig");
const record = @import("../vcs/record.zig");
const trust = @import("../vcs/trust.zig");
const actions = @import("actions.zig");

const status_capacity = 128;
const history_capacity = 64;
const file_history_capacity = 64;
const blame_capacity = 1024;
const file_path_capacity = 4096;
const branch_capacity = 128;
const output_capacity = 64 * 1024;
const visible_rows = 18;
const line_height: f32 = 14;
const record_path_capacity = 4096;
/// Provisional installed-Git executable/config digest workspace: 8 MiB ≥ current Git-for-Windows binary.
const record_file_capacity = 8 * 1024 * 1024;
const State = enum { pending, ready, failed };
const RecordState = enum { idle, preparing, review, executing, finished, failed };
const View = struct { state: State, generation: u64, published_generation: u64, snapshot: ?inspect.Snapshot, failure: ?anyerror };
const FileMode = enum { history, blame };
const FileView = struct { state: State, generation: u64, mode: FileMode, path: []const u8, commits: []const inspect.Commit, blame: []const inspect.BlameSpan, failure: ?anyerror };

/// One persistent worker owns both result slots.
/// UI reads published slot while worker writes only other slot.
const Job = struct {
    io: std.Io,
    request: invocation.RepoRequest,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    stopping: bool = false,
    job_ready: bool = false,
    running: bool = false,
    requested_generation: u64 = 0,
    published_generation: u64 = 0,
    published_slot: usize = 0,
    state: State = .pending,
    failure: ?anyerror = null,
    version: [2][4096]u8 = undefined,
    status_workspace: [2][output_capacity]u8 = undefined,
    history_workspace: [2][output_capacity]u8 = undefined,
    branch_workspace: [2][output_capacity]u8 = undefined,
    status: [2][status_capacity]inspect.Status = undefined,
    history: [2][history_capacity]inspect.Commit = undefined,
    branches: [2][branch_capacity]inspect.Branch = undefined,
    snapshots: [2]?inspect.Snapshot = .{ null, null },

    fn start(self: *Job) !void {
        self.thread = try std.Thread.spawn(.{}, inspect_worker, .{self});
        try self.request_refresh();
        std.debug.assert(self.thread != null and self.requested_generation == 1);
    }

    fn deinit(self: *Job) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.wake.signal(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn request_refresh(self: *Job) error{ Stopping, Busy, CapacityExceeded }!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping) return error.Stopping;
        if (self.running or self.job_ready) return error.Busy;
        if (self.requested_generation == std.math.maxInt(u64)) return error.CapacityExceeded;
        self.requested_generation += 1;
        self.job_ready = true;
        self.state = .pending;
        self.failure = null;
        self.wake.signal(self.io);
        std.debug.assert(self.requested_generation != 0);
    }

    fn view(self: *Job) View {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const snapshot = self.snapshots[self.published_slot];
        return .{ .state = self.state, .generation = self.requested_generation, .published_generation = self.published_generation, .snapshot = snapshot, .failure = self.failure };
    }

    fn inspect_worker(self: *Job) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.stopping and !self.job_ready) self.wake.wait(self.io, &self.mutex) catch unreachable;
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            const generation = self.requested_generation;
            const slot = (self.published_slot + 1) % self.snapshots.len;
            self.job_ready = false;
            self.running = true;
            self.mutex.unlock(self.io);

            const result = inspect.inspect(self.io, .{
                .git_exe = self.request.git,
                .repository_path = self.request.path,
                .history_limit = @min(self.request.history_limit, history_capacity),
                .limits = .{ .stdout_bytes = output_capacity, .stderr_bytes = 4096, .status_rows = status_capacity, .history_rows = history_capacity, .timeout = .{ .duration = .{ .raw = .fromMilliseconds(10_000), .clock = .awake } } },
            }, .{ .version_workspace = &self.version[slot], .status_workspace = &self.status_workspace[slot], .history_workspace = &self.history_workspace[slot], .status_rows = &self.status[slot], .history_rows = &self.history[slot], .branch_workspace = &self.branch_workspace[slot], .branch_rows = &self.branches[slot] });

            self.mutex.lockUncancelable(self.io);
            self.running = false;
            if (!self.stopping and generation == self.requested_generation) {
                if (result) |value| {
                    self.snapshots[slot] = value;
                    self.published_slot = slot;
                    self.published_generation = generation;
                    self.state = .ready;
                } else |err| {
                    self.failure = err;
                    self.state = .failed;
                }
            }
            self.mutex.unlock(self.io);
        }
    }
};

/// One worker owns bounded file-history/blame requests and publishes versioned immutable slots.
const FileJob = struct {
    io: std.Io,
    git: [record_path_capacity]u8 = undefined,
    git_len: usize = 0,
    repository: [record_path_capacity]u8 = undefined,
    repository_len: usize = 0,
    path: [file_path_capacity]u8 = undefined,
    path_len: usize = 0,
    query: [64]u8 = undefined,
    query_len: usize = 0,
    mode: FileMode = .history,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    stopping: bool = false,
    queued: bool = false,
    running: bool = false,
    generation: u64 = 0,
    published_generation: u64 = 0,
    published_slot: usize = 0,
    state: State = .pending,
    failure: ?anyerror = null,
    workspaces: [2][output_capacity]u8 = undefined,
    commits: [2][file_history_capacity]inspect.Commit = undefined,
    annotations: [2][blame_capacity]inspect.BlameSpan = undefined,
    commit_counts: [2]usize = .{ 0, 0 },
    annotation_counts: [2]usize = .{ 0, 0 },
    published_path: [file_path_capacity]u8 = undefined,
    published_path_len: usize = 0,
    published_mode: FileMode = .history,

    fn start(self: *FileJob) !void {
        self.thread = try std.Thread.spawn(.{}, file_worker, .{self});
    }
    fn deinit(self: *FileJob) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.wake.signal(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }
    fn request(self: *FileJob, request_value: invocation.RepoRequest, path_value: []const u8, mode_value: FileMode, query_value: []const u8) error{ Busy, CapacityExceeded }!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping or self.running or self.queued) return error.Busy;
        if (self.generation == std.math.maxInt(u64)) return error.CapacityExceeded;
        if (request_value.git.len > self.git.len or request_value.path.len > self.repository.len or path_value.len > self.path.len or query_value.len > self.query.len) return error.CapacityExceeded;
        @memcpy(self.git[0..request_value.git.len], request_value.git);
        @memcpy(self.repository[0..request_value.path.len], request_value.path);
        @memcpy(self.path[0..path_value.len], path_value);
        @memcpy(self.query[0..query_value.len], query_value);
        self.git_len = request_value.git.len;
        self.repository_len = request_value.path.len;
        self.path_len = path_value.len;
        self.query_len = query_value.len;
        self.mode = mode_value;
        self.generation += 1;
        self.failure = null;
        self.state = .pending;
        self.queued = true;
        self.wake.signal(self.io);
    }
    fn view(self: *FileJob) FileView {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.view_locked();
    }
    fn await(self: *FileJob) !FileView {
        for (0..3000) |_| {
            const value = self.view();
            if (value.generation == 0) return error.FileRequestNotDispatched;
            if (value.state != .pending) return value;
            try std.Io.sleep(self.io, .fromMilliseconds(10), .real);
        }
        return error.FileInspectionTimedOut;
    }
    fn view_locked(self: *FileJob) FileView {
        const slot = self.published_slot;
        return .{ .state = self.state, .generation = self.generation, .mode = self.published_mode, .path = self.published_path[0..self.published_path_len], .commits = self.commits[slot][0..self.commit_counts[slot]], .blame = self.annotations[slot][0..self.annotation_counts[slot]], .failure = self.failure };
    }
    fn file_worker(self: *FileJob) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.stopping and !self.queued) self.wake.wait(self.io, &self.mutex) catch unreachable;
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            const generation = self.generation;
            const mode_value = self.mode;
            const git_value = self.git[0..self.git_len];
            const repository_value = self.repository[0..self.repository_len];
            const path_value = self.path[0..self.path_len];
            const query_value = self.query[0..self.query_len];
            const slot = (self.published_slot + 1) % self.commits.len;
            self.queued = false;
            self.running = true;
            self.mutex.unlock(self.io);
            const file_request = inspect.FileRequest{ .git_exe = git_value, .repository_path = repository_value, .path = path_value, .history_limit = file_history_capacity, .limits = .{ .stdout_bytes = output_capacity, .stderr_bytes = 4096, .status_rows = 0, .history_rows = file_history_capacity, .timeout = .{ .duration = .{ .raw = .fromMilliseconds(10_000), .clock = .awake } } } };
            const result: anyerror!void = if (mode_value == .history) blk: {
                const parsed = inspect.file_history(self.io, file_request, &self.workspaces[slot], &self.commits[slot], if (query_value.len == 0) null else query_value) catch |err| break :blk err;
                self.commit_counts[slot] = parsed.len;
                self.annotation_counts[slot] = 0;
                break :blk {};
            } else blk: {
                const parsed = inspect.blame(self.io, file_request, &self.workspaces[slot], &self.annotations[slot]) catch |err| break :blk err;
                self.annotation_counts[slot] = parsed.len;
                self.commit_counts[slot] = 0;
                break :blk {};
            };
            self.mutex.lockUncancelable(self.io);
            self.running = false;
            if (!self.stopping and generation == self.generation) {
                if (result) |_| {
                    @memcpy(self.published_path[0..path_value.len], path_value);
                    self.published_path_len = path_value.len;
                    self.published_mode = mode_value;
                    self.published_slot = slot;
                    self.state = .ready;
                } else |err| {
                    self.failure = err;
                    self.state = .failed;
                }
                self.wake.signal(self.io);
            }
            self.mutex.unlock(self.io);
        }
    }
};

test "file inspection owns request bytes and rejects exhaustion without changing pending work" {
    const job = try std.testing.allocator.create(FileJob);
    defer std.testing.allocator.destroy(job);
    job.* = .{ .io = std.testing.io };
    const request_value = invocation.RepoRequest{ .git = "C:/git.exe", .path = "C:/repo", .history_limit = 1 };
    var path_value = [_]u8{ 'f', 'o', 'o' };
    var query_value = [_]u8{ '.', '*' };
    try job.request(request_value, &path_value, .history, &query_value);
    @memset(&path_value, 'x');
    @memset(&query_value, 'x');
    try std.testing.expectEqualStrings("foo", job.path[0..job.path_len]);
    try std.testing.expectEqualStrings(".*", job.query[0..job.query_len]);
    try std.testing.expectError(error.Busy, job.request(request_value, "other", .blame, ""));
    try std.testing.expectEqual(@as(u64, 1), job.generation);
    job.queued = false;
    job.generation = std.math.maxInt(u64);
    try std.testing.expectError(error.CapacityExceeded, job.request(request_value, "other", .blame, ""));
    try std.testing.expectEqualStrings("foo", job.path[0..job.path_len]);
    try std.testing.expectEqual(FileMode.history, job.mode);
    job.stopping = true;
    try std.testing.expectError(error.Busy, job.request(request_value, "other", .blame, ""));
}

/// One worker owns every native child process used for recording.
/// Its caller-owned fixed backing is allocated before the UI event loop begins.
const RecordWorker = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    stopping: bool = false,
    ready: bool = false,
    execute: bool = false,
    running: bool = false,
    state: RecordState = .idle,
    version: u64 = 0,
    request_version: u64 = 0,
    failure: ?anyerror = null,
    result: ?record.Result = null,
    unknown_outcome: bool = false,
    target_oid: [65]u8 = undefined,
    target_oid_len: usize = 0,
    config_sources: record.ConfigSources = .{},
    repository: [record_path_capacity]u8 = undefined,
    repository_len: usize = 0,
    executable: [record_path_capacity]u8 = undefined,
    executable_len: usize = 0,
    value: [record_path_capacity]u8 = undefined,
    value_len: usize = 0,
    branch_new: [record_path_capacity]u8 = undefined,
    branch_new_len: usize = 0,
    branch_start: [record_path_capacity]u8 = undefined,
    branch_start_len: usize = 0,
    operation: record.Operation = .stage,
    collected: ?record.Collected = null,
    token: ?record.Token = null,
    grants: [1]trust.Grant = undefined,
    command: [64 * 1024]u8 = undefined,
    environment: [64 * 1024]u8 = undefined,
    file: [record_file_capacity]u8 = undefined,
    canonical_executable: [record_path_capacity]u8 = undefined,
    canonical_repository: [record_path_capacity]u8 = undefined,
    canonical_git: [record_path_capacity]u8 = undefined,
    canonical_worktree: [record_path_capacity]u8 = undefined,
    canonical_common_dir: [record_path_capacity]u8 = undefined,
    status_workspace: [2][output_capacity]u8 = undefined,
    status_rows: [2][status_capacity]inspect.Status = undefined,
    status_slot: usize = 0,
    published_status_slot: usize = 0,
    published_status_generation: u64 = 0,
    published_status_len: usize = 0,
    review_metadata_generation: u64 = 0,

    fn start(self: *RecordWorker) !void {
        self.thread = try std.Thread.spawn(.{}, record_worker, .{self});
        std.debug.assert(self.thread != null);
    }

    fn deinit(self: *RecordWorker) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.wake.signal(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn prepare(self: *RecordWorker, git: []const u8, repository: []const u8, operation: record.Operation, value: []const u8) error{ Busy, CapacityExceeded }!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.running or self.ready) return error.Busy;
        if (self.version == std.math.maxInt(u64)) return error.CapacityExceeded;
        self.target_oid_len = 0;
        try copy_request(&self.executable, &self.executable_len, git);
        try copy_request(&self.repository, &self.repository_len, repository);
        try copy_request(&self.value, &self.value_len, value);
        self.operation = operation;
        self.version += 1;
        self.request_version = self.version;
        self.failure = null;
        self.result = null;
        self.unknown_outcome = false;
        self.state = .preparing;
        self.ready = true;
        self.execute = false;
        self.wake.signal(self.io);
    }

    fn prepare_branch(self: *RecordWorker, git: []const u8, repository: []const u8, operation: record.Operation, first: []const u8, second: []const u8) error{ Busy, CapacityExceeded }!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.running or self.ready) return error.Busy;
        if (self.version == std.math.maxInt(u64)) return error.CapacityExceeded;
        self.target_oid_len = 0;
        try copy_request(&self.executable, &self.executable_len, git);
        try copy_request(&self.repository, &self.repository_len, repository);
        try copy_request(&self.value, &self.value_len, first);
        if (operation == .branch_create) try copy_request(&self.branch_start, &self.branch_start_len, second) else try copy_request(&self.branch_new, &self.branch_new_len, second);
        self.operation = operation;
        self.version += 1;
        self.request_version = self.version;
        self.failure = null;
        self.result = null;
        self.unknown_outcome = false;
        self.state = .preparing;
        self.ready = true;
        self.execute = false;
        self.wake.signal(self.io);
    }

    fn prepare_status(self: *RecordWorker, git: []const u8, repository: []const u8, metadata_generation: u64) error{ Busy, CapacityExceeded }!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.running or self.ready) return error.Busy;
        if (self.version == std.math.maxInt(u64)) return error.CapacityExceeded;
        self.target_oid_len = 0;
        try copy_request(&self.executable, &self.executable_len, git);
        try copy_request(&self.repository, &self.repository_len, repository);
        self.value_len = 0;
        self.operation = .worktree_status;
        self.review_metadata_generation = metadata_generation;
        self.status_slot = (self.published_status_slot + 1) % self.status_rows.len;
        self.version += 1;
        self.request_version = self.version;
        self.failure = null;
        self.result = null;
        self.unknown_outcome = false;
        self.state = .preparing;
        self.ready = true;
        self.execute = false;
        self.wake.signal(self.io);
    }

    fn invalidate_status(self: *RecordWorker) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.published_status_generation = 0;
        self.published_status_len = 0;
        self.review_metadata_generation = 0;
        if (self.state == .executing and self.operation == .worktree_status) self.version +|= 1;
    }

    fn confirm(self: *RecordWorker, version: u64) error{ Busy, Stale }!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (version != self.version or self.state != .review or self.token == null) return error.Stale;
        if (self.running or self.ready) return error.Busy;
        self.state = .executing;
        self.ready = true;
        self.execute = true;
        self.wake.signal(self.io);
    }

    fn revoke(self: *RecordWorker) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state == .review or self.state == .preparing) {
            self.version +|= 1;
            self.ready = false;
            self.token = null;
            self.collected = null;
            self.state = .idle;
        }
    }

    fn view(self: *RecordWorker) RecordView {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const remote_summary = if (self.collected) |collected| collected.remote_summary else record.RemoteSummary{};
        return .{ .state = self.state, .version = self.version, .failure = self.failure, .result = self.result, .unknown_outcome = self.unknown_outcome, .target_oid = self.target_oid[0..self.target_oid_len], .operation = self.operation, .remote_summary = remote_summary, .status = self.status_rows[self.published_status_slot][0..self.published_status_len], .status_generation = self.published_status_generation };
    }

    fn record_worker(self: *RecordWorker) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.stopping and !self.ready) self.wake.wait(self.io, &self.mutex) catch unreachable;
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            const version = self.request_version;
            const execute = self.execute;
            self.ready = false;
            self.running = true;
            self.mutex.unlock(self.io);
            if (execute) self.run_execute(version) else self.run_prepare(version);
        }
    }

    fn run_prepare(self: *RecordWorker, version: u64) void {
        const record_request = self.request();
        const result = record.collect(self.io, self.executable[0..self.executable_len], self.repository[0..self.repository_len], record_request, self.buffers());
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.running = false;
        if (version != self.version or self.stopping) return;
        if (result) |collected| {
            if (collected.branch_target) |target| {
                self.target_oid_len = target.oid().len;
                @memcpy(self.target_oid[0..self.target_oid_len], target.oid());
            }
            self.collected = collected;
            self.token = record.Token.init(collected.preflight);
            self.state = .review;
        } else |err| {
            self.failure = err;
            self.state = .failed;
        }
    }

    fn run_execute(self: *RecordWorker, version: u64) void {
        const initial = self.collected orelse return self.finish_execute(version, error.StalePreflight);
        var store = trust.Store.init(&self.grants);
        const record_request = self.request();
        store.grant(.{ .repository = initial.preflight.repository, .config = initial.preflight.executable_config, .scope = record.scope(record_request) }) catch return self.finish_execute(version, error.CapacityExceeded);
        var token = self.token orelse return self.finish_execute(version, error.TokenExpired);
        if (std.meta.activeTag(record_request) == .worktree_status) {
            const slot = self.status_slot;
            const statuses = inspect.execute_worktree_status_revalidated(self.io, &store, &token, initial, self.buffers(), &self.file, &self.status_workspace[slot], &self.status_rows[slot], .{ .stdout_bytes = output_capacity, .stderr_bytes = 64 * 1024, .status_rows = status_capacity, .history_rows = 0, .timeout = .{ .duration = .{ .raw = .fromMilliseconds(30_000), .clock = .awake } } });
            self.finish_status_execute(version, slot, statuses);
            return;
        }
        const result = record.execute_revalidated(self.io, &store, &token, initial, record_request, self.buffers(), &self.file, 64 * 1024, 64 * 1024, .{ .duration = .{ .raw = .fromMilliseconds(30_000), .clock = .awake } });
        self.finish_execute(version, result);
    }

    fn finish_status_execute(self: *RecordWorker, version: u64, slot: usize, result: anyerror![]const inspect.Status) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.running = false;
        self.token = null;
        self.collected = null;
        if (self.stopping) return;
        if (result) |statuses| {
            if (version == self.version and self.review_metadata_generation != 0) {
                self.published_status_slot = slot;
                self.published_status_len = statuses.len;
                self.published_status_generation = self.review_metadata_generation;
            }
            self.state = .finished;
        } else |err| {
            self.failure = err;
            self.unknown_outcome = err == error.ChildTimeout;
            self.state = .failed;
        }
    }

    fn finish_execute(self: *RecordWorker, version: u64, result: anyerror!record.Result) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.running = false;
        self.token = null;
        self.collected = null;
        if (version != self.version or self.stopping) return;
        if (result) |value| {
            self.result = value;
            if (value.succeeded) self.state = .finished else {
                self.failure = error.GitFailed;
                self.state = .failed;
            }
        } else |err| {
            self.failure = err;
            self.unknown_outcome = err == error.ChildTimeout;
            self.state = .failed;
        }
    }

    fn request(self: *const RecordWorker) record.Request {
        return switch (self.operation) {
            .stage => .{ .stage = .{ .path = self.value[0..self.value_len] } },
            .unstage => .{ .unstage = .{ .path = self.value[0..self.value_len] } },
            .commit => .{ .commit = .{ .message = self.value[0..self.value_len] } },
            .branch_create => .{ .branch_create = .{ .name = self.value[0..self.value_len], .start_point = self.branch_start[0..self.branch_start_len] } },
            .branch_rename => .{ .branch_rename = .{ .old = self.value[0..self.value_len], .new = self.branch_new[0..self.branch_new_len] } },
            .branch_delete => .{ .branch_delete = .{ .target = self.value[0..self.value_len] } },
            .fetch => .{ .fetch = .{ .remote = self.value[0..self.value_len] } },
            .push => .{ .push = .{ .remote = self.value[0..self.value_len] } },
            .worktree_status => .{ .worktree_status = {} },
        };
    }

    fn buffers(self: *RecordWorker) record.Buffers {
        return .{ .config_sources = self.config_sources, .command = &self.command, .environment = &self.environment, .file = &self.file, .canonical_executable = &self.canonical_executable, .canonical_repository = &self.canonical_repository, .canonical_git = &self.canonical_git, .canonical_worktree = &self.canonical_worktree, .canonical_common_dir = &self.canonical_common_dir };
    }
};

test "repository discarded status scans retain execution outcome" {
    const worker = try std.testing.allocator.create(RecordWorker);
    defer std.testing.allocator.destroy(worker);
    worker.* = .{ .io = std.testing.io, .operation = .worktree_status, .version = 1, .state = .executing, .running = true };
    worker.invalidate_status();
    try std.testing.expectEqual(RecordState.executing, worker.view().state);
    worker.finish_status_execute(1, 0, &.{});
    try std.testing.expectEqual(RecordState.finished, worker.view().state);
    try std.testing.expectEqual(@as(u64, 0), worker.view().status_generation);
    worker.state = .executing;
    worker.running = true;
    const version = worker.version;
    worker.invalidate_status();
    worker.finish_status_execute(version, 0, error.ChildTimeout);
    try std.testing.expectEqual(RecordState.failed, worker.view().state);
    try std.testing.expect(worker.view().unknown_outcome);
    try std.testing.expectEqual(@as(u64, 0), worker.view().status_generation);
}

test "repository generations exhaust without wrapping or publishing discarded scans" {
    const worker = try std.testing.allocator.create(RecordWorker);
    defer std.testing.allocator.destroy(worker);
    worker.* = .{ .io = std.testing.io, .operation = .worktree_status, .version = std.math.maxInt(u64), .state = .executing, .running = true, .review_metadata_generation = 9 };
    worker.invalidate_status();
    const statuses = [_]inspect.Status{.{ .kind = .changed, .xy = .{ 'M', '.' }, .path = "discarded" }};
    worker.finish_status_execute(std.math.maxInt(u64), 0, &statuses);
    try std.testing.expectEqual(@as(usize, 0), worker.view().status.len);
    try std.testing.expectError(error.CapacityExceeded, worker.prepare_status("git", "repo", 1));
    try std.testing.expectError(error.CapacityExceeded, worker.prepare("git", "repo", .stage, "path"));
    try std.testing.expectError(error.CapacityExceeded, worker.prepare_branch("git", "repo", .branch_create, "branch", "HEAD"));
    const job = try std.testing.allocator.create(Job);
    defer std.testing.allocator.destroy(job);
    job.* = .{ .io = std.testing.io, .request = .{ .path = "repo", .git = "git", .history_limit = 1 }, .requested_generation = std.math.maxInt(u64) };
    try std.testing.expectError(error.CapacityExceeded, job.request_refresh());
    try std.testing.expect(!job.job_ready);
}

/// Remote summary is copied from collected evidence while its exact preflight remains reviewable.
const RecordView = struct { state: RecordState, version: u64, failure: ?anyerror, result: ?record.Result, unknown_outcome: bool, target_oid: []const u8 = "", operation: record.Operation = .stage, remote_summary: record.RemoteSummary = .{}, status: []const inspect.Status = &.{}, status_generation: u64 = 0 };

fn copy_request(destination: []u8, length: *usize, source: []const u8) error{CapacityExceeded}!void {
    if (source.len > destination.len) return error.CapacityExceeded;
    @memcpy(destination[0..source.len], source);
    length.* = source.len;
}

const Model = struct {
    /// Copies selected NUL-parser path before any subsequent inspector refresh can recycle its slot.
    review_path: ?[]const u8 = null,
    review_path_storage: [record_path_capacity]u8 = undefined,
    review_action: ?actions.RepositoryId = null,
    review_metadata_generation: u64 = 0,
    commit_message: [72]u8 = undefined,
    commit_message_len: usize = 0,
    branch_name: [record_path_capacity]u8 = undefined,
    branch_name_len: usize = 0,
    branch_start: [record_path_capacity]u8 = undefined,
    branch_start_len: usize = 0,
    branch_entry: enum { none, create_name, create_start, rename, remote } = .none,
    branch_input: [record_path_capacity]u8 = undefined,
    branch_input_len: usize = 0,
    target_oid: [65]u8 = undefined,
    target_oid_len: usize = 0,
    notice: ?[]const u8 = null,
    palette_open: bool = false,
    query: [64]u8 = undefined,
    query_len: usize = 0,
    selected_action: usize = 0,
    focus_history: bool = false,
    focus_branches: bool = false,
    status_selected: usize = 0,
    history_selected: usize = 0,
    branch_selected: usize = 0,
    status_scroll: usize = 0,
    history_scroll: usize = 0,
    rendered_generation: u64 = std.math.maxInt(u64),
    rendered_state: ?State = null,
    rendered_record_version: u64 = std.math.maxInt(u64),
    rendered_review_ready: bool = false,
    rendered_review_at: u64 = 0,
    rendered_record_state: ?RecordState = null,
    rendered_file_generation: u64 = std.math.maxInt(u64),
    rendered_file_state: ?State = null,
    repository_path: []const u8 = "",
    git_exe: []const u8 = "",
    file_job: ?*FileJob = null,
    file_querying: bool = false,
    file_query_len: usize = 0,
    file_query: [64]u8 = undefined,
};

pub fn run(init: std.process.Init, request: invocation.RepoRequest) !void {
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return graphics_failure("SDL video initialization failed");
    defer sdl.SDL_Quit();
    return run_initialized(init, request);
}

/// Caller owns SDL video lifetime and must keep it alive through worker join.
pub fn run_initialized(init: std.process.Init, request: invocation.RepoRequest) !void {
    const window = try create_window();
    defer sdl.SDL_DestroyWindow(window);
    const device = try create_device();
    defer sdl.SDL_DestroyGPUDevice(device);
    const renderer = sdl.SDL_CreateGPURenderer(device, window) orelse return graphics_failure("SDL_CreateGPURenderer failed");
    defer sdl.SDL_DestroyRenderer(renderer);

    var job = Job{ .io = init.io, .request = request };
    try job.start();
    defer job.deinit();
    const record_backing = try std.heap.page_allocator.alloc(u8, @sizeOf(RecordWorker) + @alignOf(RecordWorker) - 1);
    defer std.heap.page_allocator.free(record_backing);
    var record_allocator = std.heap.FixedBufferAllocator.init(record_backing);
    const worker = try record_allocator.allocator().create(RecordWorker);
    worker.* = .{ .io = init.io };
    try worker.start();
    defer worker.deinit();
    const file_backing = try std.heap.page_allocator.alloc(u8, @sizeOf(FileJob) + @alignOf(FileJob) - 1);
    defer std.heap.page_allocator.free(file_backing);
    var file_allocator = std.heap.FixedBufferAllocator.init(file_backing);
    const file_job = try file_allocator.allocator().create(FileJob);
    file_job.* = .{ .io = init.io };
    try file_job.start();
    defer file_job.deinit();
    try event_loop(init.io, renderer, &job, worker, file_job);
}

fn create_window() !*sdl.SDL_Window {
    const window = sdl.SDL_CreateWindow("warkocz repository inspection", 1120, 720, sdl.SDL_WINDOW_RESIZABLE | sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse return graphics_failure("SDL_CreateWindow failed");
    errdefer sdl.SDL_DestroyWindow(window);
    if (!sdl.SDL_SetWindowMinimumSize(window, 720, 480)) return graphics_failure("SDL_SetWindowMinimumSize failed");
    return window;
}

fn create_device() !*sdl.SDL_GPUDevice {
    const formats = sdl.SDL_GPU_SHADERFORMAT_DXIL | sdl.SDL_GPU_SHADERFORMAT_SPIRV;
    return sdl.SDL_CreateGPUDevice(formats, false, null) orelse graphics_failure("No compatible DXIL or SPIR-V GPU device");
}

fn graphics_failure(summary: []const u8) error{GraphicsUnavailable} {
    var buffer: [1024]u8 = undefined;
    const detail = std.mem.span(sdl.SDL_GetError());
    const message = std.fmt.bufPrintSentinel(&buffer, "{s}\nSDL: {s}\nUpdate GPU driver or use a compatible GPU. No repository was opened or mutated.", .{ summary, detail[0..@min(detail.len, 384)] }, 0) catch unreachable;
    _ = sdl.SDL_ShowSimpleMessageBox(sdl.SDL_MESSAGEBOX_ERROR, "warkocz graphics unavailable", message, null);
    return error.GraphicsUnavailable;
}

fn event_loop(io: std.Io, renderer: *sdl.SDL_Renderer, job: *Job, worker: *RecordWorker, file_job: *FileJob) !void {
    var model = Model{ .repository_path = job.request.path, .git_exe = job.request.git };
    var running = true;
    var redraw = true;
    while (running) {
        const view = job.view();
        const record_view = worker.view();
        const file_view = file_job.view();
        if ((record_view.state == .finished or record_view.state == .failed) and record_view.state != model.rendered_record_state and record_view.operation != .worktree_status) {
            try request_metadata_refresh(job, worker);
        }
        if (view.generation != model.rendered_generation or view.state != model.rendered_state or record_view.version != model.rendered_record_version or record_view.state != model.rendered_record_state or file_view.generation != model.rendered_file_generation or file_view.state != model.rendered_file_state or redraw) {
            model.file_job = file_job;
            try render(renderer, view, record_view, file_view, &model);
            model.rendered_generation = view.generation;
            model.rendered_state = view.state;
            model.rendered_file_generation = file_view.generation;
            model.rendered_file_state = file_view.state;
            redraw = false;
        }
        var event: sdl.SDL_Event = undefined;
        if (!sdl.SDL_WaitEventTimeout(&event, 100)) continue;
        redraw = try handle_event(&event, &model, job, worker, file_job, &running);
    }
    _ = io;
}

fn handle_event(event: *const sdl.SDL_Event, model: *Model, job: *Job, worker: *RecordWorker, file_job: ?*FileJob, running: *bool) !bool {
    if (event.type == sdl.SDL_EVENT_QUIT or event.type == sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED) {
        running.* = false;
        return false;
    }
    if (event.type == sdl.SDL_EVENT_WINDOW_RESIZED or event.type == sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED or event.type == sdl.SDL_EVENT_WINDOW_EXPOSED) return true;
    if (event.type == sdl.SDL_EVENT_TEXT_INPUT) {
        if (model.palette_open or model.file_querying) append_query(model, std.mem.span(event.text.text)) else if (model.branch_entry != .none) append_branch_input(model, std.mem.span(event.text.text)) else if (model.review_action != null and model.review_action.? == .commit_staged) {
            worker.revoke();
            append_commit_message(model, std.mem.span(event.text.text));
        }
        return true;
    }
    if (event.type == sdl.SDL_EVENT_MOUSE_WHEEL) {
        const delta: isize = @intFromFloat(event.wheel.y);
        scroll(model, status_snapshot(job.view(), worker.view()), -delta * 3);
        return true;
    }
    if (event.type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN and event.button.button == sdl.SDL_BUTTON_LEFT) {
        return select_mouse_row(event.button.x, event.button.y, model, job, worker);
    }
    if (event.type != sdl.SDL_EVENT_KEY_DOWN) return false;
    const key = event.key.key;
    if ((event.key.mod & sdl.SDL_KMOD_CTRL) != 0 and key == sdl.SDLK_P) {
        model.palette_open = !model.palette_open;
        model.query_len = 0;
        return true;
    }
    if (model.palette_open) return handle_palette_key(key, model, job, worker, file_job, running);
    if (model.file_querying) {
        if (key == sdl.SDLK_ESCAPE) {
            model.file_querying = false;
            model.query_len = 0;
            return true;
        }
        if (key == sdl.SDLK_BACKSPACE) {
            model.query_len -|= 1;
            return true;
        }
        if (key == sdl.SDLK_RETURN) {
            const selected = selected_path(status_snapshot(job.view(), worker.view()), model, .search_history) orelse {
                model.notice = "Select a tracked file before history search.";
                model.file_querying = false;
                return true;
            };
            if (file_job) |active_file_job| {
                active_file_job.request(job.request, selected, .history, model.query[0..model.query_len]) catch |err| {
                    model.notice = @errorName(err);
                };
            } else model.notice = "File inspection worker unavailable.";
            model.file_querying = false;
            return true;
        }
        return true;
    }
    if (model.branch_entry != .none) return handle_branch_entry(key, model, worker);
    if (model.review_action != null) {
        if (key == sdl.SDLK_RETURN and (event.key.repeat or event.key.timestamp < model.rendered_review_at)) {
            model.notice = "Release Enter and press again after reviewing the displayed preflight.";
            return true;
        }
        return handle_review_key(key, model, job, worker);
    }
    if (key == sdl.SDLK_ESCAPE) {
        running.* = false;
        return false;
    }
    if (key == sdl.SDLK_R) {
        try request_metadata_refresh(job, worker);
        return true;
    }
    if (key == sdl.SDLK_S or key == sdl.SDLK_U or key == sdl.SDLK_C or key == sdl.SDLK_B or key == sdl.SDLK_N or key == sdl.SDLK_D) {
        const action: actions.RepositoryId = switch (key) {
            sdl.SDLK_S => .stage_selected,
            sdl.SDLK_U => .unstage_selected,
            sdl.SDLK_C => .commit_staged,
            sdl.SDLK_B => .branch_create,
            sdl.SDLK_N => .branch_rename,
            else => .branch_delete,
        };
        begin_review(model, status_snapshot(job.view(), worker.view()), job.request, worker, action);
        return true;
    }
    if (key == sdl.SDLK_TAB) {
        if (model.focus_history) {
            model.focus_history = false;
            model.focus_branches = true;
        } else if (model.focus_branches) {
            model.focus_branches = false;
        } else {
            model.focus_history = true;
        }
        return true;
    }
    if (key == sdl.SDLK_UP or key == sdl.SDLK_DOWN or key == sdl.SDLK_PAGEUP or key == sdl.SDLK_PAGEDOWN) {
        const amount: isize = if (key == sdl.SDLK_PAGEUP or key == sdl.SDLK_PAGEDOWN) visible_rows else 1;
        scroll(model, status_snapshot(job.view(), worker.view()), if (key == sdl.SDLK_UP or key == sdl.SDLK_PAGEUP) -amount else amount);
        return true;
    }
    return false;
}

fn handle_palette_key(key: sdl.SDL_Keycode, model: *Model, job: *Job, worker: *RecordWorker, file_job: ?*FileJob, running: *bool) !bool {
    if (key == sdl.SDLK_ESCAPE) {
        model.palette_open = false;
        return true;
    }
    if (key == sdl.SDLK_BACKSPACE) {
        model.query_len -|= 1;
        select_first_match(model);
        return true;
    }
    if (key == sdl.SDLK_UP or key == sdl.SDLK_DOWN) {
        move_action(model, key == sdl.SDLK_DOWN);
        return true;
    }
    if (key == sdl.SDLK_RETURN) {
        const action = actions.repository_actions[model.selected_action].id;
        try execute_action(model, job, worker, file_job, running, action);
        model.palette_open = false;
        return true;
    }
    return true;
}

fn execute_action(model: *Model, job: *Job, worker: *RecordWorker, file_job: ?*FileJob, running: *bool, action: actions.RepositoryId) !void {
    if (model.review_action != null) {
        worker.revoke();
        model.review_action = null;
        model.review_path = null;
    }
    switch (action) {
        .refresh => try request_metadata_refresh(job, worker),
        .review_worktree_status => begin_status_review(model, job.view(), job.request, worker),
        .history_selected, .blame_selected => {
            const selected = selected_path(status_snapshot(job.view(), worker.view()), model, action) orelse {
                model.notice = "Select a tracked file first.";
                return;
            };
            const mode_value: FileMode = if (action == .blame_selected) .blame else .history;
            if (file_job) |active_file_job| active_file_job.request(job.request, selected, mode_value, "") catch |err| {
                model.notice = @errorName(err);
            } else model.notice = "File inspection worker unavailable.";
        },
        .search_history => {
            model.file_querying = true;
            model.query_len = 0;
            model.notice = "Search selected file history | literal query | Enter search | Esc cancel";
        },
        .stage_selected, .unstage_selected, .commit_staged, .branch_create, .branch_rename, .branch_delete, .fetch, .push => begin_review(model, status_snapshot(job.view(), worker.view()), job.request, worker, action),
        .revoke_record_trust => {
            worker.revoke();
            model.review_action = null;
            model.review_path = null;
            model.notice = "Pending one-use record authorization revoked.";
        },
        .close => running.* = false,
    }
}

fn request_metadata_refresh(job: *Job, worker: *RecordWorker) !void {
    worker.revoke();
    worker.invalidate_status();
    job.request_refresh() catch |err| if (err != error.Busy) return err;
}

fn begin_status_review(model: *Model, view: View, request: invocation.RepoRequest, worker: *RecordWorker) void {
    if (worker.view().state == .executing) {
        model.notice = "An authorized operation is executing; wait for its outcome.";
        return;
    }
    worker.revoke();
    model.review_action = .review_worktree_status;
    model.review_path = null;
    model.review_metadata_generation = view.published_generation;
    const snapshot = view.snapshot orelse {
        model.notice = "Metadata is unavailable; refresh before reviewing worktree status.";
        return;
    };
    if (view.state != .ready or view.published_generation == 0 or snapshot.worktree_status_available) {
        model.review_action = null;
        model.notice = "Worktree status scan is unavailable for this metadata view.";
        return;
    }
    worker.prepare_status(request.git, request.path, view.published_generation) catch |err| {
        model.review_action = null;
        model.notice = @errorName(err);
    };
}

fn begin_branch_review(model: *Model, snapshot: ?inspect.Snapshot, request: invocation.RepoRequest, worker: *RecordWorker, action: actions.RepositoryId) void {
    const snapshot_value = snapshot orelse {
        model.notice = "Branch list unavailable.";
        return;
    };
    if (model.branch_selected >= snapshot_value.branches.len) {
        model.notice = "Select a local branch first.";
        return;
    }
    const branch = snapshot_value.branches[model.branch_selected];
    if (branch.current or branch.worktree_path.len != 0) {
        model.notice = "Refused: branch is current or checked out in a worktree.";
        return;
    }
    if (branch.name.len > model.review_path_storage.len or branch.oid.len > model.target_oid.len) {
        model.notice = "Branch identity exceeds bounded review capacity.";
        return;
    }
    @memcpy(model.review_path_storage[0..branch.name.len], branch.name);
    model.review_path = model.review_path_storage[0..branch.name.len];
    model.target_oid_len = branch.oid.len;
    @memcpy(model.target_oid[0..model.target_oid_len], branch.oid[0..model.target_oid_len]);
    if (action == .branch_rename) {
        model.branch_entry = .rename;
        model.branch_input_len = 0;
        return;
    }
    worker.prepare(request.git, request.path, .branch_delete, branch.name) catch |err| {
        model.notice = @errorName(err);
    };
    return;
}

fn begin_review(model: *Model, snapshot: ?inspect.Snapshot, request: invocation.RepoRequest, worker: *RecordWorker, action: actions.RepositoryId) void {
    if (worker.view().state == .executing) {
        model.notice = "An authorized operation is executing; wait for its outcome.";
        return;
    }
    worker.revoke();
    model.notice = null;
    model.review_action = action;
    model.review_path = null;
    model.review_metadata_generation = 0;
    model.commit_message_len = 0;
    model.branch_name_len = 0;
    model.branch_start_len = 0;
    model.target_oid_len = 0;
    if (action == .fetch or action == .push) {
        model.branch_entry = .remote;
        model.branch_input_len = 0;
        return;
    }
    if (action == .branch_create) {
        model.branch_entry = .create_name;
        model.branch_input_len = 0;
        return;
    }
    if (action == .commit_staged) return;
    if (action == .branch_rename or action == .branch_delete) return begin_branch_review(model, snapshot, request, worker, action);
    if (record_operation(action) == null) return;
    if (snapshot) |value| {
        if (model.status_selected < value.status.len and value.status[model.status_selected].kind == .renamed) {
            model.notice = "Rename/copy recording needs paired-path review; use installed Git for this operation.";
            return;
        }
    }
    const selected = selected_path(snapshot, model, action) orelse {
        model.notice = "Unavailable: selected row has no matching index/worktree change.";
        return;
    };
    if (selected.len > model.review_path_storage.len) {
        model.notice = "Selected path exceeds bounded record request capacity.";
        return;
    }
    @memcpy(model.review_path_storage[0..selected.len], selected);
    model.review_path = model.review_path_storage[0..selected.len];
    const value = model.review_path orelse {
        model.notice = "Unavailable: selected row has no matching index/worktree change.";
        return;
    };
    worker.prepare(request.git, request.path, record_operation(action).?, value) catch |err| {
        model.notice = @errorName(err);
    };
}

test "record selection respects porcelain v2 dots and refuses partial rename recording" {
    var rows = [_]inspect.Status{.{ .kind = .changed, .xy = .{ '.', 'M' }, .path = "tracked" }};
    const snapshot = inspect.Snapshot{ .version = "", .status = &rows, .history = &.{}, .branches = &.{} };
    const model = Model{};
    try std.testing.expect(selected_path(snapshot, &model, .stage_selected) != null);
    try std.testing.expect(selected_path(snapshot, &model, .unstage_selected) == null);
    rows[0].xy = .{ 'M', '.' };
    try std.testing.expect(selected_path(snapshot, &model, .stage_selected) == null);
    try std.testing.expect(selected_path(snapshot, &model, .unstage_selected) != null);
    try std.testing.expectEqualStrings("tracked", selected_path(snapshot, &model, .history_selected).?);
    rows[0].kind = .renamed;
    rows[0].original_path = "old";
    try std.testing.expect(selected_path(snapshot, &model, .stage_selected) == null);
    try std.testing.expect(selected_path(snapshot, &model, .unstage_selected) == null);
}

test "new or edited record review revokes previous confirmation before any new request" {
    const worker = try std.testing.allocator.create(RecordWorker);
    defer std.testing.allocator.destroy(worker);
    worker.* = .{ .io = std.testing.io, .state = .review, .version = 7 };
    const request_value = invocation.RepoRequest{ .git = "C:/git.exe", .path = "C:/repo", .history_limit = 1 };
    var model = Model{};
    begin_review(&model, null, request_value, worker, .stage_selected);
    try std.testing.expectEqual(RecordState.idle, worker.state);
    try std.testing.expectError(error.Stale, worker.confirm(7));
    const job = try std.testing.allocator.create(Job);
    defer std.testing.allocator.destroy(job);
    job.* = .{ .io = std.testing.io, .request = request_value };
    worker.state = .review;
    model.review_action = .commit_staged;
    var running = true;
    const text_event: sdl.SDL_Event = .{ .text = .{ .type = sdl.SDL_EVENT_TEXT_INPUT, .text = "x" } };
    _ = try handle_event(&text_event, &model, job, worker, null, &running);
    try std.testing.expectEqual(RecordState.idle, worker.state);
    try std.testing.expectEqualStrings("x", model.commit_message[0..model.commit_message_len]);
    worker.state = .review;
    _ = handle_review_key(sdl.SDLK_BACKSPACE, &model, job, worker);
    try std.testing.expectEqual(RecordState.idle, worker.state);
    try std.testing.expectEqual(@as(usize, 0), model.commit_message_len);
    worker.state = .review;
    model.review_action = .review_worktree_status;
    try execute_action(&model, job, worker, null, &running, .history_selected);
    try std.testing.expectEqual(RecordState.idle, worker.state);
    try std.testing.expectEqual(@as(?actions.RepositoryId, null), model.review_action);
}

fn status_snapshot(view: View, record_view: RecordView) ?inspect.Snapshot {
    var snapshot = view.snapshot orelse return null;
    if (record_view.status_generation != 0 and record_view.status_generation == view.published_generation) snapshot.status = record_view.status;
    return snapshot;
}

fn selected_path(snapshot: ?inspect.Snapshot, model: *const Model, action: actions.RepositoryId) ?[]const u8 {
    const value = snapshot orelse return null;
    if (model.status_selected >= value.status.len) return null;
    const status = value.status[model.status_selected];
    if (action == .history_selected or action == .blame_selected or action == .search_history) {
        return if (status.kind != .untracked and status.kind != .ignored) status.path else null;
    }
    if (status.kind == .renamed or status.kind == .ignored) return null;
    if (action == .stage_selected and ((status.xy[1] != ' ' and status.xy[1] != '.') or status.kind == .untracked)) return status.path;
    if (action == .unstage_selected and status.xy[0] != ' ' and status.xy[0] != '.') return status.path;
    return null;
}

fn handle_review_key(key: sdl.SDL_Keycode, model: *Model, job: *Job, worker: *RecordWorker) bool {
    if (key == sdl.SDLK_ESCAPE) {
        worker.revoke();
        model.review_action = null;
        model.review_path = null;
        return true;
    }
    if (key == sdl.SDLK_R) {
        request_metadata_refresh(job, worker) catch |err| {
            model.notice = @errorName(err);
        };
        model.review_action = null;
        model.review_path = null;
        return true;
    }
    if (model.review_action != null and model.review_action.? == .commit_staged and key == sdl.SDLK_BACKSPACE) {
        worker.revoke();
        model.commit_message_len -|= 1;
        return true;
    }
    if (key == sdl.SDLK_RETURN) {
        if (model.review_action != null and model.review_action.? == .commit_staged and model.commit_message_len == 0) {
            model.notice = "Commit message required.";
            return true;
        }
        const view = worker.view();
        if (model.review_action.? == .review_worktree_status and model.review_metadata_generation != job.view().published_generation) {
            worker.revoke();
            model.review_action = null;
            model.notice = "Metadata changed; refresh and review worktree status again.";
            return true;
        }
        if (model.review_action.? == .commit_staged and view.state == .idle) {
            worker.prepare(model.git_exe, model.repository_path, .commit, model.commit_message[0..model.commit_message_len]) catch |err| {
                model.notice = @errorName(err);
            };
            return true;
        }
        if (view.state != .review) {
            model.notice = if (view.failure) |err| @errorName(err) else "Preflight still running; exact confirmation unavailable.";
            return true;
        }
        if (!model.rendered_review_ready or model.rendered_record_state != .review or model.rendered_record_version != view.version) {
            model.notice = "Wait for the exact preflight review to be displayed before confirming.";
            return true;
        }
        worker.confirm(view.version) catch |err| {
            model.notice = @errorName(err);
            return true;
        };
        model.review_action = null;
        model.review_path = null;
        model.notice = "Executing one revalidated installed-Git operation off UI thread.";
    }
    return true;
}

fn append_branch_input(model: *Model, input: []const u8) void {
    for (input) |byte| {
        if (model.branch_input_len == model.branch_input.len) break;
        if (byte >= 32 and byte <= 126) {
            model.branch_input[model.branch_input_len] = byte;
            model.branch_input_len += 1;
        }
    }
}

fn handle_branch_entry(key: sdl.SDL_Keycode, model: *Model, worker: *RecordWorker) bool {
    if (key == sdl.SDLK_ESCAPE) {
        model.branch_entry = .none;
        model.branch_input_len = 0;
        return true;
    }
    if (key == sdl.SDLK_BACKSPACE) {
        model.branch_input_len -|= 1;
        return true;
    }
    if (key != sdl.SDLK_RETURN) return true;
    const input = model.branch_input[0..model.branch_input_len];
    if (input.len == 0) {
        model.notice = "Branch name/ref required.";
        return true;
    }
    if (model.branch_entry == .remote) {
        const action = model.review_action orelse return true;
        const operation: record.Operation = if (action == .fetch) .fetch else .push;
        worker.prepare(model.git_exe, model.repository_path, operation, input) catch |err| {
            model.notice = @errorName(err);
            return true;
        };
        @memcpy(model.review_path_storage[0..input.len], input);
        model.review_path = model.review_path_storage[0..input.len];
        model.branch_entry = .none;
        return true;
    }
    if (model.branch_entry == .create_name) {
        @memcpy(model.branch_name[0..input.len], input);
        model.branch_name_len = input.len;
        model.branch_entry = .create_start;
        model.branch_input_len = 0;
        return true;
    }
    const operation: record.Operation = if (model.branch_entry == .create_start) .branch_create else .branch_rename;
    if (operation == .branch_create) {
        @memcpy(model.branch_start[0..input.len], input);
        model.branch_start_len = input.len;
    }
    worker.prepare_branch(model.git_exe, model.repository_path, operation, if (operation == .branch_create) model.branch_name[0..model.branch_name_len] else (model.review_path orelse ""), input) catch |err| {
        model.notice = @errorName(err);
        return true;
    };
    model.branch_entry = .none;
    return true;
}

fn append_commit_message(model: *Model, input: []const u8) void {
    for (input) |byte| {
        if (model.commit_message_len == model.commit_message.len) break;
        if (byte >= 32 and byte <= 126) {
            model.commit_message[model.commit_message_len] = byte;
            model.commit_message_len += 1;
        }
    }
}

fn select_mouse_row(x: f32, y: f32, model: *Model, job: *Job, worker: *RecordWorker) bool {
    if (y >= 80 and y < 94) {
        const action: ?actions.RepositoryId = if (x < 150) .stage_selected else if (x < 300) .unstage_selected else if (x < 480) .commit_staged else if (x < 590) .branch_create else if (x < 700) .branch_rename else if (x < 820) .branch_delete else null;
        if (action) |value| {
            begin_review(model, job.view().snapshot, job.request, worker, value);
            return true;
        }
    }
    const snapshot = status_snapshot(job.view(), worker.view()) orelse return false;
    const status_first: f32 = 126;
    const history_first = status_first + @as(f32, @floatFromInt(visible_rows + 1)) * line_height + line_height;
    if (y >= status_first and y < status_first + @as(f32, @floatFromInt(visible_rows)) * line_height) {
        const row: usize = @intFromFloat((y - status_first) / line_height);
        if (model.status_scroll + row >= snapshot.status.len) return false;
        model.focus_history = false;
        model.status_selected = model.status_scroll + row;
        return true;
    }
    if (x >= 600 and y >= 112 and y < 112 + @as(f32, @floatFromInt(visible_rows)) * line_height) {
        const row: usize = @intFromFloat((y - 112) / line_height);
        if (row >= snapshot.branches.len) return false;
        model.branch_selected = row;
        model.focus_history = false;
        model.focus_branches = true;
        return true;
    }
    if (y >= history_first and y < history_first + @as(f32, @floatFromInt(visible_rows)) * line_height) {
        const row: usize = @intFromFloat((y - history_first) / line_height);
        if (model.history_scroll + row >= snapshot.history.len) return false;
        model.focus_history = true;
        model.history_selected = model.history_scroll + row;
        return true;
    }
    return false;
}

fn scroll(model: *Model, snapshot: ?inspect.Snapshot, delta: isize) void {
    if (model.focus_branches) {
        const branches = if (snapshot) |value| value.branches.len else 0;
        if (branches == 0) return;
        const next: isize = @as(isize, @intCast(model.branch_selected)) + delta;
        model.branch_selected = @intCast(@max(0, @min(next, @as(isize, @intCast(branches - 1)))));
        return;
    }
    const rows = if (model.focus_history) if (snapshot) |value| value.history.len else 0 else if (snapshot) |value| value.status.len else 0;
    const selected = if (model.focus_history) &model.history_selected else &model.status_selected;
    const top = if (model.focus_history) &model.history_scroll else &model.status_scroll;
    if (rows == 0) return;
    const next: isize = @as(isize, @intCast(selected.*)) + delta;
    selected.* = @intCast(@max(0, @min(next, @as(isize, @intCast(rows - 1)))));
    if (selected.* < top.*) top.* = selected.*;
    if (selected.* >= top.* + visible_rows) top.* = selected.* - visible_rows + 1;
    std.debug.assert(selected.* < rows and top.* <= selected.*);
}

fn append_query(model: *Model, input: []const u8) void {
    for (input) |byte| {
        if (model.query_len == model.query.len) break;
        if (byte >= 32 and byte <= 126) {
            model.query[model.query_len] = byte;
            model.query_len += 1;
        }
    }
    select_first_match(model);
}

fn matches(model: *const Model, index: usize) bool {
    const action = actions.repository_actions[index];
    const query = model.query[0..model.query_len];
    return std.ascii.findIgnoreCase(action.name, query) != null or std.ascii.findIgnoreCase(action.aliases, query) != null or std.ascii.findIgnoreCase(action.help, query) != null;
}

fn select_first_match(model: *Model) void {
    for (actions.repository_actions, 0..) |_, index| if (matches(model, index)) {
        model.selected_action = index;
        return;
    };
}

fn move_action(model: *Model, forward: bool) void {
    var next = model.selected_action;
    for (0..actions.repository_actions.len) |_| {
        next = if (forward) (next + 1) % actions.repository_actions.len else (next + actions.repository_actions.len - 1) % actions.repository_actions.len;
        if (matches(model, next)) {
            model.selected_action = next;
            return;
        }
    }
}

fn empty_file_view() FileView {
    return .{ .state = .pending, .generation = 0, .mode = .history, .path = "", .commits = &.{}, .blame = &.{}, .failure = null };
}

fn render(renderer: *sdl.SDL_Renderer, view: View, record_view: RecordView, file_view: FileView, model: *Model) !void {
    if (!sdl.SDL_SetRenderDrawColor(renderer, 24, 28, 38, 255) or !sdl.SDL_RenderClear(renderer)) return error.RenderFailed;
    try text(renderer, 8, 8, "warkocz | repository inspection | installed-Git whole-file record worker");
    try text(renderer, 8, 22, "Ctrl+P actions | History/Blame/Search selected file | S/U/C record | Esc closes/cancels input");
    try text(renderer, 8, 36, "No implicit execution grants; each status scan or mutation requires its own displayed review.");
    try text(renderer, 8, 80, "[Stage] [Unstage] [Commit] [Create branch] [Rename] [Delete merged]");
    switch (view.state) {
        .pending => try text(renderer, 8, 52, "Refreshing off UI thread. Existing snapshot remains readable; newest generation wins."),
        .failed => try failure(renderer, view.failure.?),
        .ready => {},
    }
    if (!remote_review(model)) {
        if (status_snapshot(view, record_view)) |snapshot| {
            model.status_scroll = @min(model.status_scroll, snapshot.status.len -| visible_rows);
            model.history_scroll = @min(model.history_scroll, snapshot.history.len -| visible_rows);
            model.status_selected = @min(model.status_selected, snapshot.status.len -| 1);
            model.history_selected = @min(model.history_selected, snapshot.history.len -| 1);
            model.branch_selected = @min(model.branch_selected, snapshot.branches.len -| 1);
            try snapshot_rows(renderer, snapshot, view.published_generation, record_view, model);
        }
        try file_rows(renderer, file_view);
    }
    if (model.file_querying) {
        try text(renderer, 520, 612, "Search history | literal query:");
        try text(renderer, 760, 612, model.query[0..model.query_len]);
        try text(renderer, 520, 626, "Enter search | Esc cancel");
    }
    if (model.notice) |notice| if (!remote_review(model)) try text(renderer, 8, 690, notice);
    if (record_view.state == .failed) try text(renderer, 8, 676, if (record_view.unknown_outcome) "Record timeout: outcome unknown; do not rerun without refresh/reconciliation." else record_failure_message(record_view.failure.?));
    if (record_view.state == .executing) try text(renderer, 8, 676, "Authorized Git command executing; wait for its outcome before another operation.");
    if (record_view.state == .finished) try text(renderer, 8, 676, if (record_view.operation == .worktree_status)
        (if (record_view.status_generation != 0 and record_view.status_generation == view.published_generation) "Worktree status scan finished for displayed metadata; refresh hides it." else "Authorized scan finished; stale result discarded, not configured-code side effects.")
    else if (record_view.result.?.succeeded)
        "Record operation finished; refreshing repository."
    else
        "Git reported failure; refresh and reconcile state before any retry.");
    if (model.palette_open) try palette(renderer, model, view.state == .pending);
    if (model.branch_entry != .none) try text(renderer, 520, 612, switch (model.branch_entry) {
        .create_name => "New branch name:",
        .create_start => "Start ref (resolved OID shown before confirm):",
        .rename => "New branch name:",
        .remote => "Configured remote name (not URL):",
        .none => "",
    });
    if (model.branch_entry != .none) try text(renderer, 720, 612, model.branch_input[0..model.branch_input_len]);
    const review_visible = !remote_review(model) or try remote_review_visible(renderer);
    if (model.review_action) |action| {
        if (review_visible) try review(renderer, model, action, record_view) else try text(renderer, 8, 96, "Enlarge window to 1120 x 720 pixels to review all endpoints; confirmation unavailable.");
    }
    if (!sdl.SDL_RenderPresent(renderer)) return error.RenderFailed;
    const review_ready = review_visible and record_view.state == .review and model.review_action != null;
    if (review_ready and (!model.rendered_review_ready or model.rendered_record_version != record_view.version)) model.rendered_review_at = sdl.SDL_GetTicksNS();
    model.rendered_review_ready = review_ready;
    model.rendered_record_version = record_view.version;
    model.rendered_record_state = record_view.state;
}

fn failure(renderer: *sdl.SDL_Renderer, err: anyerror) !void {
    try text(renderer, 8, 52, "Inspection unavailable. No repository mutation occurred.");
    try text(renderer, 8, 66, @errorName(err));
    try text(renderer, 8, 80, "Check absolute Git executable/repository paths, permissions, compatibility, or bounded output limits.");
}

fn file_rows(renderer: *sdl.SDL_Renderer, value: FileView) !void {
    if (value.state == .pending) {
        try text(renderer, 600, 360, "File inspection running | prior result remains readable");
        return;
    }
    if (value.state == .failed) {
        try text(renderer, 600, 360, @errorName(value.failure.?));
        return;
    }
    if (value.path.len == 0) return;
    try text(renderer, 600, 360, if (value.mode == .history) "FILE HISTORY | literal path:" else "BLAME HEAD | literal path:");
    try text(renderer, 600, 374, value.path);
    if (value.mode == .history) {
        for (value.commits[0..@min(value.commits.len, 18)], 0..) |commit, index| {
            var row: [257]u8 = undefined;
            const line = std.fmt.bufPrint(&row, "{s} {s}", .{ commit.id[0..@min(12, commit.id.len)], commit.subject }) catch "commit";
            try text(renderer, 600, 392 + @as(f32, @floatFromInt(index)) * line_height, line);
        }
    } else {
        for (value.blame[0..@min(value.blame.len, 18)], 0..) |annotation, index| {
            var row: [257]u8 = undefined;
            const prefix = std.fmt.bufPrint(&row, "{d} {s} {s} | ", .{ annotation.line_id, annotation.commit_id[0..@min(8, annotation.commit_id.len)], annotation.author }) catch "";
            try text(renderer, 600, 392 + @as(f32, @floatFromInt(index)) * line_height, prefix);
            var escaped: [128]u8 = undefined;
            try text(renderer, 840, 392 + @as(f32, @floatFromInt(index)) * line_height, escape_source(annotation.source, &escaped));
        }
    }
}

fn escape_source(source: []const u8, destination: []u8) []const u8 {
    const hex = "0123456789ABCDEF";
    var used: usize = 0;
    for (source) |byte| {
        const needed: usize = if (byte >= 32 and byte <= 126 and byte != '\\') 1 else 4;
        if (needed > destination.len - used) break;
        if (needed == 1) {
            destination[used] = byte;
            used += 1;
        } else {
            destination[used] = '\\';
            destination[used + 1] = 'x';
            destination[used + 2] = hex[byte >> 4];
            destination[used + 3] = hex[byte & 15];
            used += 4;
        }
    }
    return destination[0..used];
}

fn snapshot_rows(renderer: *sdl.SDL_Renderer, value: inspect.Snapshot, metadata_generation: u64, record_view: RecordView, model: *const Model) !void {
    const status_scanned = record_view.status_generation != 0 and record_view.status_generation == metadata_generation;
    const status = if (status_scanned) record_view.status else value.status;
    var header: [128]u8 = undefined;
    var version: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&header, "READY | {s} | status {d}/{d} | history {d}/{d}", .{ clip(value.version, &version), status.len, status_capacity, value.history.len, history_capacity }) catch "READY | metadata clipped";
    try text(renderer, 8, 96, if (status_scanned) title else "READY | worktree status not scanned | review scan: configured clean/process filters may execute");
    try text(renderer, 8, 112, if (model.focus_history) " STATUS" else ">STATUS");
    const shown_status = @min(visible_rows, status.len -| model.status_scroll);
    for (status[model.status_scroll .. model.status_scroll + shown_status], 0..) |entry, index| {
        const y = 126 + @as(f32, @floatFromInt(index)) * line_height;
        try text(renderer, 8, y, if (!model.focus_history and model.status_selected == model.status_scroll + index) ">" else " ");
        try text(renderer, 18, y, @tagName(entry.kind));
        try text(renderer, 86, y, entry.xy[0..]);
        try text(renderer, 110, y, entry.path);
    }
    const history_top = 126 + @as(f32, @floatFromInt(visible_rows + 1)) * line_height;
    try text(renderer, 8, history_top, if (model.focus_history) ">HISTORY" else " HISTORY");
    try text(renderer, 600, 96, if (model.focus_branches) ">LOCAL BRANCHES | * current | path means checked out" else " LOCAL BRANCHES | * current | path means checked out");
    for (value.branches[0..@min(visible_rows, value.branches.len)], 0..) |branch, index| {
        const y = 112 + @as(f32, @floatFromInt(index)) * line_height;
        try text(renderer, 600, y, if (model.branch_selected == index) ">" else " ");
        try text(renderer, 612, y, if (branch.current) "*" else if (branch.worktree_path.len != 0) "W" else " ");
        try text(renderer, 628, y, branch.name);
        if (branch.worktree_path.len != 0) try text(renderer, 820, y, "worktree");
    }
    const shown_history = @min(visible_rows, value.history.len -| model.history_scroll);
    for (value.history[model.history_scroll .. model.history_scroll + shown_history], 0..) |entry, index| {
        const y = history_top + line_height + @as(f32, @floatFromInt(index)) * line_height;
        try text(renderer, 8, y, if (model.focus_history and model.history_selected == model.history_scroll + index) ">" else " ");
        try text(renderer, 18, y, entry.id[0..@min(entry.id.len, 12)]);
        try text(renderer, 122, y, entry.subject);
    }
}

fn palette(renderer: *sdl.SDL_Renderer, model: *const Model, refreshing: bool) !void {
    try text(renderer, 620, 8, "ACTION PALETTE");
    try text(renderer, 620, 22, model.query[0..model.query_len]);
    for (actions.repository_actions, 0..) |action, index| {
        if (!matches(model, index)) continue;
        const y = 40 + @as(f32, @floatFromInt(index)) * 42;
        try text(renderer, 620, y, if (index == model.selected_action) ">" else " ");
        try text(renderer, 632, y, action.name);
        try text(renderer, 632, y + 14, action.help);
        if (action.id == .refresh and refreshing) try text(renderer, 632, y + 28, "Disabled: inspection already running.") else try text(renderer, 920, y, action.binding);
    }
}

fn remote_review(model: *const Model) bool {
    const action = model.review_action orelse return false;
    const operation = record_operation(action) orelse return false;
    return operation == .fetch or operation == .push;
}

fn review(renderer: *sdl.SDL_Renderer, model: *const Model, action: actions.RepositoryId, record_view: RecordView) !void {
    const operation = record_operation(action) orelse return;
    if (operation == .fetch or operation == .push) return render_remote_review(renderer, model, record_view);
    if (operation == .worktree_status) {
        try text(renderer, 520, 430, "REVIEW ONE WORKTREE STATUS SCAN");
        try text(renderer, 520, 444, "Scope: current repository/worktree/common-dir + HEAD/index/config/executable state.");
        try text(renderer, 520, 458, "Configured clean/process filters may execute during this scan.");
        try text(renderer, 520, 472, "Grant expires after one scan attempt; Enter confirms only displayed preflight.");
        try text(renderer, 520, 556, if (record_view.state == .review) "Enter confirms this exact one-use scan." else "Preparing exact config/executable evidence off UI thread; Enter waits.");
        return;
    }
    try text(renderer, 520, 430, "REVIEW ONE INSTALLED-GIT OPERATION");
    try text(renderer, 520, 444, @tagName(operation));
    try text(renderer, 520, 458, "Scope: current repository/worktree/common-dir + HEAD/index/config/executable state.");
    try text(renderer, 520, 472, "Risk: hooks, filters, signing, external commands, configured network. Grant expires after one attempt.");
    if (model.review_path) |path| {
        try text(renderer, 520, 486, if (operation == .branch_rename or operation == .branch_delete) "Exact local branch ref:" else "Exact selected NUL-parser path bytes:");
        try text(renderer, 520, 500, path);
    }
    if (operation == .branch_create) {
        try text(renderer, 520, 486, "New branch:");
        try text(renderer, 600, 486, model.branch_name[0..model.branch_name_len]);
        try text(renderer, 520, 500, "Start ref:");
        try text(renderer, 600, 500, model.branch_start[0..model.branch_start_len]);
    } else if (operation == .branch_rename) {
        try text(renderer, 520, 486, "Rename to:");
        try text(renderer, 600, 486, model.branch_input[0..model.branch_input_len]);
    }
    if (action == .commit_staged) {
        try text(renderer, 520, 486, "Commit message ASCII:");
        try text(renderer, 520, 500, model.commit_message[0..model.commit_message_len]);
    }
    if (model.notice) |notice| try text(renderer, 520, 514, notice);
    if (operation == .branch_create or operation == .branch_rename or operation == .branch_delete) {
        try text(renderer, 520, 514, "Exact reviewed target commit OID:");
        try text(renderer, 520, 528, record_view.target_oid);
    }
    try text(renderer, 520, 556, if (record_view.state == .review) "Enter confirms this exact one-use operation." else "Preparing exact config/executable evidence off UI thread; Enter waits.");
}

fn remote_review_visible(renderer: *sdl.SDL_Renderer) !bool {
    var width: c_int = 0;
    var height: c_int = 0;
    if (!sdl.SDL_GetRenderOutputSize(renderer, &width, &height)) return error.RenderFailed;
    return width >= 1120 and height >= 720;
}

fn render_remote_review(renderer: *sdl.SDL_Renderer, model: *const Model, record_view: RecordView) !void {
    try text(renderer, 8, 96, "REVIEW ONE INSTALLED-GIT REMOTE OPERATION");
    try text(renderer, 8, 110, "Configured remote name:");
    var line_index: usize = 0;
    try remote_review_lines(renderer, model.review_path orelse "", &line_index);
    try remote_review_lines(renderer, "Network risk: Git may contact endpoint; credentials may be used.", &line_index);
    try remote_review_lines(renderer, "Configured helpers, SSH, hooks and signing may execute with your permissions.", &line_index);
    try remote_review_lines(renderer, "Scheme/host summaries only: userinfo, paths, queries and fragments are hidden.", &line_index);
    try remote_review_lines(renderer, "Exact effective config remains bound; this does not disclose full destinations.", &line_index);
    line_index += 1;
    for (record_view.remote_summary.items()) |endpoint| {
        var row: [176]u8 = undefined;
        const label = std.fmt.bufPrint(&row, "{s}: {s}", .{ @tagName(endpoint.role), endpoint.text() }) catch "endpoint label unavailable";
        try remote_review_lines(renderer, label, &line_index);
    }
    const confirm_y = 138 + @as(f32, @floatFromInt(line_index)) * line_height;
    if (model.notice) |notice| try text(renderer, 8, confirm_y, notice);
    try text(renderer, 8, confirm_y + line_height, if (record_view.state == .review) "Enter confirms this bound one-use operation; full destination paths remain hidden." else "Preparing exact config/executable evidence off UI thread; Enter waits.");
}

fn remote_review_lines(renderer: *sdl.SDL_Renderer, value: []const u8, line_index: *usize) !void {
    var start: usize = 0;
    while (start < value.len) {
        const end = @min(start + 120, value.len);
        try text(renderer, 8, 124 + @as(f32, @floatFromInt(line_index.*)) * line_height, value[start..end]);
        line_index.* += 1;
        start = end;
    }
}

fn record_failure_message(err: anyerror) []const u8 {
    return switch (err) {
        error.GitFailed => "Git failed; configured code or remote operations may have partial effects. Reconcile before retry.",
        error.OutputLimitExceeded => "Bounded output capacity exceeded; partial effects are possible. Reconcile before retry.",
        error.BranchCheckedOut => "Refused: branch is checked out in a worktree.",
        error.StalePreflight => "Refused: branch/ref/repository changed after review; refresh and review again.",
        error.RemoteSummaryLimitExceeded => "Remote endpoint review exceeds bounded capacity; no partial endpoint list is shown.",
        else => @errorName(err),
    };
}

fn record_operation(action: actions.RepositoryId) ?record.Operation {
    return switch (action) {
        .stage_selected => .stage,
        .unstage_selected => .unstage,
        .commit_staged => .commit,
        .branch_create => .branch_create,
        .branch_rename => .branch_rename,
        .branch_delete => .branch_delete,
        .fetch => .fetch,
        .push => .push,
        .review_worktree_status => .worktree_status,
        else => null,
    };
}

fn clip(value: []const u8, buffer: []u8) []const u8 {
    const length = @min(value.len, buffer.len - 1);
    @memcpy(buffer[0..length], value[0..length]);
    return buffer[0..length];
}

fn text(renderer: *sdl.SDL_Renderer, x: f32, y: f32, value: []const u8) !void {
    var buffer: [257:0]u8 = undefined;
    const clipped = @min(value.len, buffer.len - 1);
    for (value[0..clipped], 0..) |byte, index| buffer[index] = if (byte >= 32 and byte <= 126) byte else '?';
    if (value.len > clipped and clipped >= 3) @memcpy(buffer[clipped - 3 .. clipped], "...");
    buffer[clipped] = 0;
    if (!sdl.SDL_RenderDebugText(renderer, x, y, &buffer)) return error.RenderFailed;
}

/// Executes stage then unstage against an isolated installed-Git repository through real SDL input.
pub fn gpu_repository_record_stage_unstage_test() !void {
    if (comptime builtin.os.tag != .windows) return;
    const git = try fixture_git_executable() orelse return;
    defer std.testing.allocator.free(git);
    var fixture = try RecordFixture.init(std.testing.io);
    defer fixture.deinit(std.testing.io);
    try fixture.run_git(&.{"init"});
    try fixture.run_git(&.{ "config", "user.name", "warkocz fixture" });
    try fixture.run_git(&.{ "config", "user.email", "fixture@example.invalid" });
    // Equal-length edits force content comparison; size-only dirtiness may skip clean filters.
    try fixture.write("tracked.txt", "base!\r\n");
    try fixture.run_git(&.{ "add", "--", "tracked.txt" });
    try fixture.run_git(&.{ "commit", "-m", "baseline" });
    try fixture.write("tracked.txt", "dirty\r\n");
    try fixture.write(".gitattributes", "tracked.txt filter=fixture\n");
    try fixture.run_git(&.{ "config", "filter.fixture.clean", "echo status-scan >> status-scan.marker; cat" });

    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.GraphicsUnavailable;
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("warkocz record fixture", 1120, 720, sdl.SDL_WINDOW_HIDDEN) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const device = try create_device();
    defer sdl.SDL_DestroyGPUDevice(device);
    const renderer = sdl.SDL_CreateGPURenderer(device, window) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);

    var job = Job{ .io = std.testing.io, .request = .{ .path = fixture.path, .git = git, .history_limit = 4 } };
    try job.start();
    defer job.deinit();
    try await_job(&job);
    const backing = try std.heap.page_allocator.alloc(u8, @sizeOf(RecordWorker) + @alignOf(RecordWorker) - 1);
    defer std.heap.page_allocator.free(backing);
    var allocator = std.heap.FixedBufferAllocator.init(backing);
    const worker = try allocator.allocator().create(RecordWorker);
    worker.* = .{ .io = std.testing.io, .config_sources = fixture.config_sources() };
    try worker.start();
    defer worker.deinit();
    var model = Model{ .repository_path = fixture.path, .git_exe = git };
    try render(renderer, job.view(), worker.view(), empty_file_view(), &model);
    try verify_worktree_status_scan(&fixture, renderer, &model, &job, worker);
    const marker = try fixture.file_bytes("status-scan.marker");
    defer std.testing.allocator.free(marker);
    try std.testing.expect(marker.len > 0);
    try confirm_worktree_status_scan(renderer, &model, &job, worker);
    var queued: sdl.SDL_Event = undefined;
    while (sdl.SDL_PollEvent(&queued)) {}

    try verify_record_staging(&fixture, renderer, &model, &job, worker);
    try verify_record_branches(&fixture, renderer, &model, &job, worker);
}

fn confirm_worktree_status_scan(renderer: *sdl.SDL_Renderer, model: *Model, job: *Job, worker: *RecordWorker) !void {
    var running = true;
    try execute_action(model, job, worker, null, &running, .review_worktree_status);
    try await_record(worker, .review);
    try render(renderer, job.view(), worker.view(), empty_file_view(), model);
    _ = handle_review_key(sdl.SDLK_RETURN, model, job, worker);
    try expect_record_confirmation(worker, model);
    try await_record(worker, .finished);
}

fn verify_worktree_status_scan(fixture: *RecordFixture, renderer: *sdl.SDL_Renderer, model: *Model, job: *Job, worker: *RecordWorker) !void {
    var running = true;
    try expect_status_marker_absent(fixture);
    try execute_action(model, job, worker, null, &running, .review_worktree_status);
    try await_record(worker, .review);
    _ = handle_review_key(sdl.SDLK_RETURN, model, job, worker);
    try std.testing.expectEqual(RecordState.review, worker.view().state);
    try expect_status_marker_absent(fixture);
    try render(renderer, job.view(), worker.view(), empty_file_view(), model);
    _ = handle_review_key(sdl.SDLK_RETURN, model, job, worker);
    try expect_record_confirmation(worker, model);
    try await_record(worker, .finished);
    const marker = try fixture.file_bytes("status-scan.marker");
    defer std.testing.allocator.free(marker);
    const duplicate: sdl.SDL_Event = .{ .key = .{ .type = sdl.SDL_EVENT_KEY_DOWN, .key = sdl.SDLK_RETURN, .down = true } };
    _ = try handle_event(&duplicate, model, job, worker, null, &running);
    try std.testing.expectEqual(RecordState.finished, worker.view().state);
    try expect_file_bytes(fixture, "status-scan.marker", marker);
    const view = worker.view();
    try std.testing.expectEqual(job.view().published_generation, view.status_generation);
    try std.testing.expect(view.status.len > 0);
    try request_metadata_refresh(job, worker);
    try std.testing.expectEqual(@as(usize, 0), worker.view().status.len);
    try await_job(job);
    try execute_action(model, job, worker, null, &running, .review_worktree_status);
    try await_record(worker, .review);
    try request_metadata_refresh(job, worker);
    try std.testing.expectEqual(RecordState.idle, worker.view().state);
    try await_job(job);
    try expect_file_bytes(fixture, "status-scan.marker", marker);
}

fn expect_record_confirmation(worker: *RecordWorker, model: *const Model) !void {
    const view = worker.view();
    if (view.state == .executing or view.state == .finished) return;
    std.debug.print("Synthetic confirmation refused: state={s}, visible={}, notice={s}\n", .{ @tagName(view.state), model.rendered_review_ready, model.notice orelse "none" });
    return view.failure orelse error.RecordNotConfirmed;
}

fn expect_status_marker_absent(fixture: *RecordFixture) !void {
    if (fixture.file_bytes("status-scan.marker")) |bytes| {
        std.testing.allocator.free(bytes);
        return error.UntrustedFilterExecuted;
    } else |err| if (err != error.FileNotFound) return err;
}

fn verify_record_staging(fixture: *RecordFixture, renderer: *sdl.SDL_Renderer, model: *Model, job: *Job, worker: *RecordWorker) !void {
    const baseline = try fixture.index_blob("tracked.txt");
    defer std.testing.allocator.free(baseline);
    try dispatch_key(sdl.SDLK_S, model, job, worker);
    try await_record(worker, .review);
    try expect_index_blob(fixture, "tracked.txt", baseline);
    try dispatch_key(sdl.SDLK_RETURN, model, job, worker);
    try std.testing.expectEqual(RecordState.review, worker.view().state);
    try render(renderer, job.view(), worker.view(), empty_file_view(), model);
    try dispatch_key(sdl.SDLK_RETURN, model, job, worker);
    try await_record(worker, .finished);
    try expect_index_blob(fixture, "tracked.txt", "dirty\r\n");
    try expect_file_bytes(fixture, "tracked.txt", "dirty\r\n");

    try job.request_refresh();
    try await_job(job);
    try confirm_worktree_status_scan(renderer, model, job, worker);
    try dispatch_key(sdl.SDLK_U, model, job, worker);
    try await_record(worker, .review);
    try render(renderer, job.view(), worker.view(), empty_file_view(), model);
    try dispatch_key(sdl.SDLK_RETURN, model, job, worker);
    try await_record(worker, .finished);
    try expect_index_blob(fixture, "tracked.txt", baseline);
    try expect_file_bytes(fixture, "tracked.txt", "dirty\r\n");

    var selected = [_]u8{ 't', 'r', 'a', 'c', 'k', 'e', 'd', '.', 't', 'x', 't' };
    try worker.prepare(job.request.git, fixture.path, .stage, &selected);
    @memset(&selected, 'x');
    try await_record(worker, .review);
    try render(renderer, job.view(), worker.view(), empty_file_view(), model);
    worker.revoke();
    try std.testing.expectEqual(RecordState.idle, worker.view().state);
    try expect_index_blob(fixture, "tracked.txt", baseline);
}

fn verify_record_branches(fixture: *RecordFixture, renderer: *sdl.SDL_Renderer, model: *Model, job: *Job, worker: *RecordWorker) !void {
    try dispatch_key(sdl.SDLK_B, model, job, worker);
    try dispatch_text("ui-created", model, job, worker);
    try dispatch_key(sdl.SDLK_RETURN, model, job, worker);
    try dispatch_text("HEAD", model, job, worker);
    try dispatch_key(sdl.SDLK_RETURN, model, job, worker);
    try await_record(worker, .review);
    try render(renderer, job.view(), worker.view(), empty_file_view(), model);
    try std.testing.expect(!try fixture.branch_exists("ui-created"));
    try dispatch_key(sdl.SDLK_RETURN, model, job, worker);
    try await_record(worker, .finished);
    try std.testing.expect(try fixture.branch_exists("ui-created"));

    try job.request_refresh();
    try await_job(job);
    model.branch_selected = branch_index(job.view().snapshot.?, "ui-created") orelse return error.BranchMissing;
    try dispatch_key(sdl.SDLK_N, model, job, worker);
    try dispatch_text("ui-renamed", model, job, worker);
    try dispatch_key(sdl.SDLK_RETURN, model, job, worker);
    try await_record(worker, .review);
    try render(renderer, job.view(), worker.view(), empty_file_view(), model);
    try std.testing.expect(try fixture.branch_exists("ui-created"));
    try std.testing.expect(!try fixture.branch_exists("ui-renamed"));
    try dispatch_key(sdl.SDLK_RETURN, model, job, worker);
    try await_record(worker, .finished);
    try std.testing.expect(try fixture.branch_exists("ui-renamed"));

    try job.request_refresh();
    try await_job(job);
    model.branch_selected = branch_index(job.view().snapshot.?, "ui-renamed") orelse return error.BranchMissing;
    try dispatch_key(sdl.SDLK_D, model, job, worker);
    try await_record(worker, .review);
    try render(renderer, job.view(), worker.view(), empty_file_view(), model);
    try std.testing.expect(try fixture.branch_exists("ui-renamed"));
    try dispatch_key(sdl.SDLK_RETURN, model, job, worker);
    try await_record(worker, .finished);
    try std.testing.expect(!try fixture.branch_exists("ui-renamed"));

    try fixture.run_git(&.{ "branch", "stale" });
    try job.request_refresh();
    try await_job(job);
    model.branch_selected = branch_index(job.view().snapshot.?, "stale") orelse return error.BranchMissing;
    try dispatch_key(sdl.SDLK_D, model, job, worker);
    try await_record(worker, .review);
    try render(renderer, job.view(), worker.view(), empty_file_view(), model);
    try fixture.run_git(&.{ "commit", "--allow-empty", "-m", "advance HEAD" });
    try dispatch_key(sdl.SDLK_RETURN, model, job, worker);
    try await_record(worker, .failed);
    try std.testing.expectEqual(error.StalePreflight, worker.view().failure.?);
    try std.testing.expect(try fixture.branch_exists("stale"));
}

fn branch_index(snapshot: inspect.Snapshot, wanted: []const u8) ?usize {
    for (snapshot.branches, 0..) |branch, index| if (std.mem.eql(u8, branch.name, wanted)) return index;
    return null;
}

fn dispatch_text(value: [:0]const u8, model: *Model, job: *Job, worker: *RecordWorker) !void {
    var injected: sdl.SDL_Event = .{ .text = .{ .type = sdl.SDL_EVENT_TEXT_INPUT, .text = value.ptr, .timestamp = sdl.SDL_GetTicksNS() } };
    if (!sdl.SDL_PushEvent(&injected)) return error.EventInjectionFailed;
    var received: sdl.SDL_Event = undefined;
    var running = true;
    for (0..64) |_| {
        if (!sdl.SDL_WaitEventTimeout(&received, 100)) return error.EventInjectionFailed;
        _ = try handle_event(&received, model, job, worker, null, &running);
        if (!running) return error.UnexpectedClose;
        if (received.type == injected.type and received.text.timestamp == injected.text.timestamp and std.mem.eql(u8, std.mem.span(received.text.text), value)) return;
    }
    return error.InjectedEventNotObserved;
}

fn expect_index_blob(fixture: *const RecordFixture, path: []const u8, expected: []const u8) !void {
    const actual = try fixture.index_blob(path);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

fn expect_file_bytes(fixture: *const RecordFixture, path: []const u8, expected: []const u8) !void {
    const actual = try fixture.file_bytes(path);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

fn await_job(job: *Job) !void {
    for (0..1_000) |_| {
        const view = job.view();
        if (view.state == .ready) return;
        if (view.state == .failed) return view.failure orelse error.InspectionFailed;
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .real) catch {};
    }
    return error.InspectionTimedOut;
}

fn await_record(worker: *RecordWorker, expected: RecordState) !void {
    for (0..3_000) |_| {
        const view = worker.view();
        if (view.state == expected) return;
        if (view.state == .failed) return view.failure orelse error.RecordFailed;
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .real) catch {};
    }
    const view = worker.view();
    std.debug.print("Synthetic record wait: expected={s}, state={s}, operation={s}, version={d}\n", .{ @tagName(expected), @tagName(view.state), @tagName(view.operation), view.version });
    return error.RecordTimedOut;
}

fn dispatch_key(key: sdl.SDL_Keycode, model: *Model, job: *Job, worker: *RecordWorker) !void {
    var injected: sdl.SDL_Event = .{ .key = .{ .type = sdl.SDL_EVENT_KEY_DOWN, .key = key, .down = true, .timestamp = sdl.SDL_GetTicksNS() } };
    if (!sdl.SDL_PushEvent(&injected)) return error.EventInjectionFailed;
    var received: sdl.SDL_Event = undefined;
    var running = true;
    for (0..64) |_| {
        if (!sdl.SDL_WaitEventTimeout(&received, 100)) return error.EventInjectionFailed;
        _ = try handle_event(&received, model, job, worker, null, &running);
        if (!running) return error.UnexpectedClose;
        if (received.type == injected.type and received.key.key == key and received.key.timestamp == injected.key.timestamp) return;
    }
    return error.InjectedEventNotObserved;
}

const RecordFixture = struct {
    path: []u8,
    global_config: []u8,
    system_config: []u8,

    fn init(io: std.Io) !RecordFixture {
        const root = "C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e";
        try std.Io.Dir.cwd().createDirPath(io, root);
        const path = try unique_fixture_path(io, root);
        errdefer std.testing.allocator.free(path);
        const global_config = try std.fmt.allocPrint(std.testing.allocator, "{s}/empty-global.config", .{path});
        errdefer std.testing.allocator.free(global_config);
        const system_config = try std.fmt.allocPrint(std.testing.allocator, "{s}/empty-system.config", .{path});
        errdefer std.testing.allocator.free(system_config);
        var fixture = RecordFixture{ .path = path, .global_config = global_config, .system_config = system_config };
        try fixture.write("empty-global.config", "");
        try fixture.write("empty-system.config", "");
        return fixture;
    }

    fn deinit(self: *RecordFixture, io: std.Io) void {
        std.Io.Dir.cwd().deleteTree(io, self.path) catch {};
        std.testing.allocator.free(self.system_config);
        std.testing.allocator.free(self.global_config);
        std.testing.allocator.free(self.path);
    }

    fn config_sources(self: *const RecordFixture) record.ConfigSources {
        return .{ .global = self.global_config, .system = self.system_config, .no_system = true };
    }

    fn run_git(self: *const RecordFixture, tail: []const []const u8) !void {
        const git = try fixture_git_executable() orelse return error.MissingGitExecutable;
        defer std.testing.allocator.free(git);
        const output = try self.git_output(git, tail);
        defer std.testing.allocator.free(output);
    }

    fn branch_exists(self: *const RecordFixture, name: []const u8) !bool {
        const pattern = try std.fmt.allocPrint(std.testing.allocator, "refs/heads/{s}", .{name});
        defer std.testing.allocator.free(pattern);
        const git = try fixture_git_executable() orelse return error.MissingGitExecutable;
        defer std.testing.allocator.free(git);
        const output = try self.git_output(git, &.{ "for-each-ref", "--format=%(refname)", pattern });
        defer std.testing.allocator.free(output);
        return output.len != 0;
    }

    fn index_blob(self: *const RecordFixture, path: []const u8) ![]u8 {
        const git = try fixture_git_executable() orelse return error.MissingGitExecutable;
        defer std.testing.allocator.free(git);
        const spec = try std.fmt.allocPrint(std.testing.allocator, ":{s}", .{path});
        defer std.testing.allocator.free(spec);
        return self.git_output(git, &.{ "show", spec });
    }

    fn ref_exists(self: *const RecordFixture, ref: []const u8) !bool {
        const git = try fixture_git_executable() orelse return error.MissingGitExecutable;
        defer std.testing.allocator.free(git);
        const output = try self.git_output(git, &.{ "for-each-ref", "--format=%(refname)", ref });
        defer std.testing.allocator.free(output);
        return std.mem.trim(u8, output, "\r\n").len != 0;
    }

    fn git_output(self: *const RecordFixture, executable: []const u8, tail: []const []const u8) ![]u8 {
        var args: [8][]const u8 = undefined;
        if (tail.len > args.len - 3) return error.TooManyArguments;
        args[0] = executable;
        args[1] = "-C";
        args[2] = self.path;
        @memcpy(args[3..][0..tail.len], tail);
        var environment = std.process.Environ.Map.init(std.testing.allocator);
        defer environment.deinit();
        try environment.put("GIT_CONFIG_GLOBAL", self.global_config);
        try environment.put("GIT_CONFIG_SYSTEM", self.system_config);
        try environment.put("GIT_CONFIG_NOSYSTEM", "1");
        const output = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = args[0 .. 3 + tail.len], .environ_map = &environment, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096), .timeout = .{ .duration = .{ .raw = .fromMilliseconds(10_000), .clock = .awake } } });
        defer std.testing.allocator.free(output.stderr);
        if (!output.term.success()) {
            std.testing.allocator.free(output.stdout);
            return error.FixtureGitFailed;
        }
        return output.stdout;
    }

    fn write(self: *const RecordFixture, name: []const u8, bytes: []const u8) !void {
        var directory = try std.Io.Dir.cwd().openDir(std.testing.io, self.path, .{ .access_sub_paths = true });
        defer directory.close(std.testing.io);
        var file = try directory.createFile(std.testing.io, name, .{ .exclusive = false });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, bytes);
    }

    fn file_bytes(self: *const RecordFixture, name: []const u8) ![]u8 {
        const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ self.path, name });
        defer std.testing.allocator.free(path);
        var workspace: [4096]u8 = undefined;
        const loaded = try files.load(std.testing.io, path, &workspace);
        const result = try std.testing.allocator.alloc(u8, loaded.bytes.len);
        @memcpy(result, loaded.bytes);
        return result;
    }
};

/// Exercises Fetch and normal Push only against synthetic local bare repositories.
pub fn gpu_repository_remote_review_test() !void {
    if (comptime builtin.os.tag != .windows) return;
    const git = try fixture_git_executable() orelse return;
    defer std.testing.allocator.free(git);
    var local = try RecordFixture.init(std.testing.io);
    defer local.deinit(std.testing.io);
    var remote = try RecordFixture.init(std.testing.io);
    defer remote.deinit(std.testing.io);
    try setup_remote_review_fixtures(&local, &remote);
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.GraphicsUnavailable;
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("warkocz remote review fixture", 1120, 720, sdl.SDL_WINDOW_HIDDEN) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const device = try create_device();
    defer sdl.SDL_DestroyGPUDevice(device);
    const renderer = sdl.SDL_CreateGPURenderer(device, window) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);
    try verify_remote_review_flow(renderer, window, git, &local, &remote);
}

fn setup_remote_review_fixtures(local: *RecordFixture, remote: *RecordFixture) !void {
    try remote.run_git(&.{ "init", "--bare" });
    try local.run_git(&.{ "init", "--initial-branch=fixture-seed" });
    try local.run_git(&.{ "config", "user.name", "warkocz fixture" });
    try local.run_git(&.{ "config", "user.email", "fixture@example.invalid" });
    try local.write("tracked.txt", "baseline\n");
    try local.run_git(&.{ "add", "--", "tracked.txt" });
    try local.run_git(&.{ "commit", "-m", "baseline" });
    try local.run_git(&.{ "push", remote.path, "HEAD:refs/heads/main" });
    try local.run_git(&.{ "remote", "add", "upstream-fixture", remote.path });
    try local.run_git(&.{ "config", "push.default", "simple" });
    const upload = try std.fmt.allocPrint(std.testing.allocator, "echo fetch-contact >> '{s}/fetch-contact.marker'; exec git-upload-pack", .{local.path});
    defer std.testing.allocator.free(upload);
    const receive = try std.fmt.allocPrint(std.testing.allocator, "echo push-contact >> '{s}/push-contact.marker'; exec git-receive-pack", .{local.path});
    defer std.testing.allocator.free(receive);
    try local.run_git(&.{ "config", "remote.upstream-fixture.uploadpack", upload });
    try local.run_git(&.{ "config", "remote.upstream-fixture.receivepack", receive });
}

fn verify_remote_review_flow(renderer: *sdl.SDL_Renderer, window: *sdl.SDL_Window, git: []const u8, local: *RecordFixture, remote: *RecordFixture) !void {
    var job = Job{ .io = std.testing.io, .request = .{ .path = local.path, .git = git, .history_limit = 4 } };
    try job.start();
    defer job.deinit();
    try await_job(&job);
    const worker = try std.heap.page_allocator.create(RecordWorker);
    defer std.heap.page_allocator.destroy(worker);
    worker.* = .{ .io = std.testing.io, .config_sources = local.config_sources() };
    try worker.start();
    defer worker.deinit();
    var model = Model{ .repository_path = local.path, .git_exe = git };
    try render(renderer, job.view(), worker.view(), empty_file_view(), &model);
    try prepare_undisplayed_remote_review(.fetch, renderer, window, &model, &job, worker);
    try std.testing.expect(!try local.ref_exists("refs/remotes/upstream-fixture/main"));
    try expect_remote_marker_absent(local, "fetch-contact.marker");
    try confirm_remote_review(renderer, &model, &job, worker);
    const fetched = try local.file_bytes("fetch-contact.marker");
    defer std.testing.allocator.free(fetched);
    try std.testing.expect(fetched.len > 0);
    try std.testing.expect(try local.ref_exists("refs/remotes/upstream-fixture/main"));
    try local.run_git(&.{ "checkout", "-b", "main", "--track", "upstream-fixture/main" });
    try local.write("tracked.txt", "pushed\n");
    try local.run_git(&.{ "add", "--", "tracked.txt" });
    try local.run_git(&.{ "commit", "-m", "push candidate" });
    const before = try remote.git_output(git, &.{ "rev-parse", "refs/heads/main" });
    defer std.testing.allocator.free(before);
    try prepare_undisplayed_remote_review(.push, renderer, window, &model, &job, worker);
    const unchanged = try remote.git_output(git, &.{ "rev-parse", "refs/heads/main" });
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings(before, unchanged);
    try expect_remote_marker_absent(local, "push-contact.marker");
    try confirm_remote_review(renderer, &model, &job, worker);
    const pushed = try local.file_bytes("push-contact.marker");
    defer std.testing.allocator.free(pushed);
    try std.testing.expect(pushed.len > 0);
    const local_head = try local.git_output(git, &.{ "rev-parse", "HEAD" });
    defer std.testing.allocator.free(local_head);
    const remote_head = try remote.git_output(git, &.{ "rev-parse", "refs/heads/main" });
    defer std.testing.allocator.free(remote_head);
    try std.testing.expectEqualStrings(local_head, remote_head);
}

fn prepare_undisplayed_remote_review(action: actions.RepositoryId, renderer: *sdl.SDL_Renderer, window: *sdl.SDL_Window, model: *Model, job: *Job, worker: *RecordWorker) !void {
    var running = true;
    try execute_action(model, job, worker, null, &running, action);
    try dispatch_text("upstream-fixture", model, job, worker);
    try dispatch_key(sdl.SDLK_RETURN, model, job, worker);
    try await_record(worker, .review);
    const view = worker.view();
    try std.testing.expectEqual(@as(usize, 1), view.remote_summary.items().len);
    try std.testing.expectEqual(if (action == .fetch) record.RemoteEndpoint.Role.fetch else .push, view.remote_summary.items()[0].role);
    try std.testing.expect(std.mem.indexOf(u8, view.remote_summary.items()[0].text(), job.request.path) == null);
    try dispatch_key(sdl.SDLK_RETURN, model, job, worker);
    try std.testing.expectEqual(RecordState.review, worker.view().state);
    try verify_remote_review_visibility(renderer, window, model, job, worker);
}

fn verify_remote_review_visibility(renderer: *sdl.SDL_Renderer, window: *sdl.SDL_Window, model: *Model, job: *Job, worker: *RecordWorker) !void {
    if (!sdl.SDL_SetWindowSize(window, 200, 100) or !sdl.SDL_SyncWindow(window)) return error.WindowResizeFailed;
    try render(renderer, job.view(), worker.view(), empty_file_view(), model);
    try std.testing.expect(!model.rendered_review_ready);
    try dispatch_key(sdl.SDLK_RETURN, model, job, worker);
    try std.testing.expectEqual(RecordState.review, worker.view().state);
    if (!sdl.SDL_SetWindowSize(window, 1120, 720) or !sdl.SDL_SyncWindow(window)) return error.WindowResizeFailed;
    try render(renderer, job.view(), worker.view(), empty_file_view(), model);
    try std.testing.expect(model.rendered_review_ready);
}

fn expect_remote_marker_absent(fixture: *RecordFixture, name: []const u8) !void {
    if (fixture.file_bytes(name)) |bytes| {
        std.testing.allocator.free(bytes);
        return error.UntrustedRemoteContact;
    } else |err| if (err != error.FileNotFound) return err;
}

fn confirm_remote_review(renderer: *sdl.SDL_Renderer, model: *Model, job: *Job, worker: *RecordWorker) !void {
    try dispatch_key(sdl.SDLK_RETURN, model, job, worker);
    try await_record(worker, .finished);
    try render(renderer, job.view(), worker.view(), empty_file_view(), model);
}

fn fixture_git_executable() !?[]u8 {
    const git = (std.process.Environ{ .block = .global }).getAlloc(std.testing.allocator, "WARKOCZ_TEST_GIT_EXE") catch return null;
    errdefer std.testing.allocator.free(git);
    if (git.len == 0) {
        std.testing.allocator.free(git);
        return null;
    }
    if (!std.fs.path.isAbsolute(git)) return error.InvalidConfiguredGitExecutable;
    return git;
}

fn unique_fixture_path(io: std.Io, root: []const u8) ![]u8 {
    var random: [8]u8 = undefined;
    const path = try std.testing.allocator.alloc(u8, root.len + 17);
    errdefer std.testing.allocator.free(path);
    @memcpy(path[0..root.len], root);
    path[root.len] = '/';
    for (0..16) |_| {
        try io.randomSecure(&random);
        hex_lower(path[root.len + 1 ..], &random);
        std.Io.Dir.cwd().createDir(io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return path;
    }
    return error.TemporaryNameExhausted;
}

fn hex_lower(destination: []u8, source: []const u8) void {
    const digits = "0123456789abcdef";
    std.debug.assert(destination.len == source.len * 2);
    for (source, 0..) |byte, index| {
        destination[index * 2] = digits[byte >> 4];
        destination[index * 2 + 1] = digits[byte & 0x0f];
    }
}

/// Synthetic owned-repository fixture covers selected-file history, literal search, and HEAD blame through GPU UI dispatch.
pub fn gpu_repository_file_history_blame_test() !void {
    if (comptime builtin.os.tag != .windows) return;
    const git = try fixture_git_executable() orelse return;
    defer std.testing.allocator.free(git);
    var fixture = try RecordFixture.init(std.testing.io);
    defer fixture.deinit(std.testing.io);
    try fixture.run_git(&.{"init"});
    try fixture.run_git(&.{ "config", "user.name", "Synthetic Fixture" });
    try fixture.run_git(&.{ "config", "user.email", "fixture@example.invalid" });
    try fixture.write("tracked.txt", "first\nstable\n");
    try fixture.run_git(&.{ "add", "--", "tracked.txt" });
    try fixture.run_git(&.{ "commit", "-m", "first revision" });
    try fixture.write("tracked.txt", "second\nchanged\n");
    try fixture.run_git(&.{ "add", "--", "tracked.txt" });
    try fixture.run_git(&.{ "commit", "-m", "second revision" });
    const expected_oid_raw = try fixture.git_output(git, &.{ "rev-parse", "HEAD" });
    defer std.testing.allocator.free(expected_oid_raw);
    const expected_oid = std.mem.trim(u8, expected_oid_raw, "\r\n");
    try fixture.write("tracked.txt", "worktree\nchanged\n");

    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.GraphicsUnavailable;
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("warkocz file history GPU integration", 1120, 720, sdl.SDL_WINDOW_HIDDEN) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const device = try create_device();
    defer sdl.SDL_DestroyGPUDevice(device);
    const renderer = sdl.SDL_CreateGPURenderer(device, window) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);

    var history_rows = [_]inspect.Commit{.{ .id = "0123456789abcdef", .parents = "", .unix_seconds = "0", .subject = "synthetic fixture" }};
    var job = Job{ .io = std.testing.io, .request = .{ .path = fixture.path, .git = git, .history_limit = file_history_capacity } };
    job.snapshots[0] = .{ .version = "synthetic fixture", .status = &.{}, .history = &history_rows, .branches = &.{}, .worktree_status_available = false };
    job.state = .ready;
    job.published_generation = 1;
    const worker = try std.heap.page_allocator.create(RecordWorker);
    defer std.heap.page_allocator.destroy(worker);
    worker.* = .{ .io = std.testing.io, .config_sources = fixture.config_sources() };
    try worker.start();
    defer worker.deinit();
    const backing = try std.heap.page_allocator.alloc(u8, @sizeOf(FileJob) + @alignOf(FileJob) - 1);
    defer std.heap.page_allocator.free(backing);
    var allocator = std.heap.FixedBufferAllocator.init(backing);
    const file_job = try allocator.allocator().create(FileJob);
    file_job.* = .{ .io = std.testing.io };
    try file_job.start();
    defer file_job.deinit();
    var model = Model{ .repository_path = fixture.path, .git_exe = git, .file_job = file_job };
    try confirm_worktree_status_scan(renderer, &model, &job, worker);
    try file_history_actions_test(renderer, &job, worker, file_job, &model, expected_oid);
}

fn file_history_actions_test(renderer: *sdl.SDL_Renderer, job: *Job, worker: *RecordWorker, file_job: *FileJob, model: *Model, expected_oid: []const u8) !void {
    var running = true;
    try render(renderer, job.view(), worker.view(), file_job.view(), model);
    sdl.SDL_FlushEvents(sdl.SDL_EVENT_FIRST, sdl.SDL_EVENT_LAST);

    try inject_test_key(.{ .key = .{ .type = sdl.SDL_EVENT_KEY_DOWN, .key = sdl.SDLK_P, .mod = sdl.SDL_KMOD_CTRL, .down = true } }, model, job, worker, file_job, &running);
    try inject_test_text("History selected file", model, job, worker, file_job, &running);
    try inject_test_key(.{ .key = .{ .type = sdl.SDL_EVENT_KEY_DOWN, .key = sdl.SDLK_RETURN, .down = true } }, model, job, worker, file_job, &running);
    const history_view = try file_job.await();
    if (history_view.state != .ready or history_view.commits.len != 2) return error.FileHistoryMismatch;
    try std.testing.expectEqualStrings("tracked.txt", history_view.path);
    try render(renderer, job.view(), worker.view(), history_view, model);

    try inject_test_key(.{ .key = .{ .type = sdl.SDL_EVENT_KEY_DOWN, .key = sdl.SDLK_P, .mod = sdl.SDL_KMOD_CTRL, .down = true } }, model, job, worker, file_job, &running);
    try inject_test_text("Blame selected file", model, job, worker, file_job, &running);
    try inject_test_key(.{ .key = .{ .type = sdl.SDL_EVENT_KEY_DOWN, .key = sdl.SDLK_RETURN, .down = true } }, model, job, worker, file_job, &running);
    const blame_view = try file_job.await();
    if (blame_view.failure) |err| return err;
    try std.testing.expectEqual(FileMode.blame, blame_view.mode);
    if (blame_view.state != .ready or blame_view.blame.len != 2) return error.FileBlameMismatch;
    try std.testing.expectEqual(@as(usize, 2), blame_view.blame[1].line_id);
    try std.testing.expectEqualStrings(expected_oid, blame_view.blame[1].commit_id);
    try std.testing.expectEqualStrings("changed", blame_view.blame[1].source);
    try render(renderer, job.view(), worker.view(), blame_view, model);

    try inject_test_key(.{ .key = .{ .type = sdl.SDL_EVENT_KEY_DOWN, .key = sdl.SDLK_P, .mod = sdl.SDL_KMOD_CTRL, .down = true } }, model, job, worker, file_job, &running);
    try inject_test_text("Search history", model, job, worker, file_job, &running);
    try inject_test_key(.{ .key = .{ .type = sdl.SDL_EVENT_KEY_DOWN, .key = sdl.SDLK_RETURN, .down = true } }, model, job, worker, file_job, &running);
    if (!model.file_querying) return error.FileSearchInputNotOpened;
    try inject_test_text("second revision", model, job, worker, file_job, &running);
    try inject_test_key(.{ .key = .{ .type = sdl.SDL_EVENT_KEY_DOWN, .key = sdl.SDLK_RETURN, .down = true } }, model, job, worker, file_job, &running);
    const search_view = try file_job.await();
    if (search_view.state != .ready or search_view.commits.len != 1) return error.FileHistorySearchMismatch;
    try std.testing.expectEqualStrings("second revision", search_view.commits[0].subject);
    try render(renderer, job.view(), worker.view(), search_view, model);
}

fn inject_test_key(value: sdl.SDL_Event, model: *Model, job: *Job, worker: *RecordWorker, file_job: *FileJob, running: *bool) !void {
    var injected = value;
    if (!sdl.SDL_PushEvent(&injected)) return error.EventInjectionFailed;
    var received: sdl.SDL_Event = undefined;
    for (0..64) |_| {
        if (!sdl.SDL_WaitEventTimeout(&received, 100)) return error.EventInjectionFailed;
        _ = try handle_event(&received, model, job, worker, file_job, running);
        if (received.type != value.type) continue;
        if (value.type == sdl.SDL_EVENT_KEY_DOWN and received.key.key != value.key.key) continue;
        if (value.type == sdl.SDL_EVENT_TEXT_INPUT and !std.mem.eql(u8, std.mem.span(received.text.text), std.mem.span(value.text.text))) continue;
        return;
    }
    return error.InjectedEventNotObserved;
}

fn inject_test_text(value: [:0]const u8, model: *Model, job: *Job, worker: *RecordWorker, file_job: *FileJob, running: *bool) !void {
    try inject_test_key(.{ .text = .{ .type = sdl.SDL_EVENT_TEXT_INPUT, .text = value.ptr } }, model, job, worker, file_job, running);
}

/// Pure injected-event routing test: no RecordWorker thread or repository mutation.
pub fn gpu_repository_event_integration_test() !void {
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.GraphicsUnavailable;
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("warkocz repository GUI integration", 1120, 720, sdl.SDL_WINDOW_HIDDEN) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const device = try create_device();
    defer sdl.SDL_DestroyGPUDevice(device);
    const renderer = sdl.SDL_CreateGPURenderer(device, window) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);

    const long_path = "a-very-long-path-that-is-clipped-in-the-debug-renderer-because-rows-remain-bounded-" ++ "a-very-long-path-that-is-clipped-in-the-debug-renderer-because-rows-remain-bounded-" ++ "a-very-long-path-that-is-clipped-in-the-debug-renderer-because-rows-remain-bounded-" ++ "a-very-long-path-that-is-clipped-in-the-debug-renderer-because-rows-remain-bounded-";
    var status_rows = [_]inspect.Status{.{ .kind = .changed, .xy = .{ ' ', 'M' }, .path = long_path }};
    var history_rows = [_]inspect.Commit{.{ .id = "0123456789abcdef", .parents = "", .unix_seconds = "0", .subject = "synthetic history" }};
    var job = Job{ .io = std.testing.io, .request = .{ .path = "C:/synthetic", .git = "C:/synthetic/git.exe", .history_limit = 1 } };
    job.snapshots[0] = .{ .version = "git version synthetic", .status = &status_rows, .history = &history_rows, .branches = &.{} };
    job.state = .ready;
    const worker = try std.heap.page_allocator.create(RecordWorker);
    defer std.heap.page_allocator.destroy(worker);
    worker.* = .{ .io = std.testing.io };
    var model = Model{};
    try render(renderer, job.view(), worker.view(), empty_file_view(), &model);

    var event: sdl.SDL_Event = undefined;
    while (sdl.SDL_PollEvent(&event)) {}
    var palette_event: sdl.SDL_Event = .{ .key = .{ .type = sdl.SDL_EVENT_KEY_DOWN, .key = sdl.SDLK_P, .mod = sdl.SDL_KMOD_CTRL, .down = true } };
    if (!sdl.SDL_PushEvent(&palette_event)) return error.EventInjectionFailed;
    if (!sdl.SDL_WaitEventTimeout(&event, 100)) return error.EventInjectionFailed;
    var running = true;
    _ = try handle_event(&event, &model, &job, worker, null, &running);
    if (!model.palette_open) return error.PaletteNotOpened;

    var text_event: sdl.SDL_Event = .{ .text = .{ .type = sdl.SDL_EVENT_TEXT_INPUT, .text = "reload" } };
    if (!sdl.SDL_PushEvent(&text_event)) return error.EventInjectionFailed;
    if (!sdl.SDL_WaitEventTimeout(&event, 100)) return error.EventInjectionFailed;
    _ = try handle_event(&event, &model, &job, worker, null, &running);
    if (actions.repository_actions[model.selected_action].id != .refresh) return error.RefreshNotSelected;

    model.palette_open = false;
    var click_event: sdl.SDL_Event = .{ .button = .{ .type = sdl.SDL_EVENT_MOUSE_BUTTON_DOWN, .button = sdl.SDL_BUTTON_LEFT, .x = 12, .y = 130 } };
    if (!sdl.SDL_PushEvent(&click_event)) return error.EventInjectionFailed;
    if (!sdl.SDL_WaitEventTimeout(&event, 100)) return error.EventInjectionFailed;
    _ = try handle_event(&event, &model, &job, worker, null, &running);
    if (model.status_selected != 0) return error.StatusNotSelected;

    var stage_event: sdl.SDL_Event = .{ .button = .{ .type = sdl.SDL_EVENT_MOUSE_BUTTON_DOWN, .button = sdl.SDL_BUTTON_LEFT, .x = 12, .y = 82 } };
    if (!sdl.SDL_PushEvent(&stage_event)) return error.EventInjectionFailed;
    if (!sdl.SDL_WaitEventTimeout(&event, 100)) return error.EventInjectionFailed;
    _ = try handle_event(&event, &model, &job, worker, null, &running);
    try std.testing.expectEqual(actions.RepositoryId.stage_selected, model.review_action orelse return error.StageReviewNotOpened);
    try std.testing.expect(model.review_path != null);
    try std.testing.expectEqualStrings(long_path, model.review_path.?);
    worker.ready = false;
    worker.state = .review;
    worker.token = .{ .preflight = undefined };
    try render(renderer, job.view(), worker.view(), empty_file_view(), &model);
    try verify_deliberate_confirmation(&model, &job, worker);
    var confirm_event: sdl.SDL_Event = .{ .key = .{ .type = sdl.SDL_EVENT_KEY_DOWN, .key = sdl.SDLK_RETURN, .down = true, .timestamp = sdl.SDL_GetTicksNS() } };
    if (!sdl.SDL_PushEvent(&confirm_event)) return error.EventInjectionFailed;
    if (!sdl.SDL_WaitEventTimeout(&event, 100)) return error.EventInjectionFailed;
    _ = try handle_event(&event, &model, &job, worker, null, &running);
    if (worker.view().state != .executing or model.review_action != null) return error.StageReviewNotConfirmed;
    try verify_withheld_status_render(renderer, &model, &job, worker);
}

fn verify_deliberate_confirmation(model: *Model, job: *Job, worker: *RecordWorker) !void {
    var running = true;
    var event: sdl.SDL_Event = .{ .key = .{ .type = sdl.SDL_EVENT_KEY_DOWN, .key = sdl.SDLK_RETURN, .down = true, .timestamp = 0 } };
    _ = try handle_event(&event, model, job, worker, null, &running);
    try std.testing.expectEqual(RecordState.review, worker.view().state);
    event.key.timestamp = sdl.SDL_GetTicksNS();
    event.key.repeat = true;
    _ = try handle_event(&event, model, job, worker, null, &running);
    try std.testing.expectEqual(RecordState.review, worker.view().state);
}

fn verify_withheld_status_render(renderer: *sdl.SDL_Renderer, model: *Model, job: *Job, worker: *RecordWorker) !void {
    job.snapshots[0].?.status = &.{};
    job.snapshots[0].?.worktree_status_available = false;
    model.status_scroll = 100;
    model.history_scroll = 100;
    try render(renderer, job.view(), worker.view(), empty_file_view(), model);
    try std.testing.expectEqual(@as(usize, 0), model.status_scroll);
    try std.testing.expectEqual(@as(usize, 0), model.history_scroll);
}

test "record request copy is bounded and exact" {
    var destination: [4]u8 = undefined;
    var length: usize = 0;
    try copy_request(&destination, &length, "abc");
    try std.testing.expectEqualStrings("abc", destination[0..length]);
    try std.testing.expectError(error.CapacityExceeded, copy_request(&destination, &length, "abcde"));
}

test "record lifecycle has explicit terminal states" {
    try std.testing.expect(RecordState.idle != .preparing);
    try std.testing.expect(RecordState.executing != .finished);
    try std.testing.expect(RecordState.failed != .finished);
}

test "palette matches aliases and selection stays bounded" {
    var model = Model{};
    append_query(&model, "reload");
    try std.testing.expect(matches(&model, model.selected_action));
    try std.testing.expectEqual(actions.RepositoryId.refresh, actions.repository_actions[model.selected_action].id);
}

test "selection scroll clamps to available rows" {
    var statuses: [3]inspect.Status = undefined;
    var commits: [1]inspect.Commit = undefined;
    const snapshot = inspect.Snapshot{ .version = "git", .status = &statuses, .history = &commits, .branches = &.{} };
    var model = Model{};
    scroll(&model, snapshot, 99);
    try std.testing.expectEqual(@as(usize, 2), model.status_selected);
    model.focus_history = true;
    scroll(&model, snapshot, 99);
    try std.testing.expectEqual(@as(usize, 0), model.history_selected);
}
