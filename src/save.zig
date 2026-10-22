const std = @import("std");
const files = @import("files.zig");
const output = @import("output.zig");
const session = @import("session.zig");

pub const path_capacity = std.Io.Dir.max_path_bytes;
pub const path_storage_capacity = path_capacity * 4;
pub const content_capacity = 192 * 1024;
const temporary_name_capacity = 48;

pub const InputPaths = struct { base: ?[]const u8, left: []const u8, right: []const u8 };
pub const State = enum { idle, pending, succeeded, failed };
pub const JobKind = enum { save, verify };
pub const Error = error{ Busy, PathTooLong, ContentTooLong, ScratchTooSmall, StorageAliased, InputStorageAliased, PathAliasesInput, NulByte };
pub const Result = union(enum) {
    idle,
    pending,
    succeeded: output.Receipt,
    failed: anyerror,
};
pub const Observed = struct {
    kind: JobKind,
    id: u64,
    generation: u64,
    identity: session.InputIdentity,
    result: Result,
};

/// One bounded worker owns external-input revalidation and new-file publication.
/// It copies result, source paths, and source identities before signaling, so UI
/// changes cannot mutate a queued job. Revalidation observes files before publish;
/// it is not a filesystem snapshot or a TOCTOU guarantee.
pub const Controller = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    stopping: bool = false,
    job_ready: bool = false,
    running: bool = false,
    state: State = .idle,
    job_kind: JobKind = .save,
    job_id: u64 = 0,
    generation: u64 = 0,
    identity: session.InputIdentity = std.mem.zeroes(session.InputIdentity),
    paths: []u8,
    content: []u8,
    preflight_scratch: []u8,
    path_lens: [4]usize = .{ 0, 0, 0, 0 }, // output, base, left, right
    content_len: usize = 0,
    receipt: output.Receipt = undefined,
    expected_receipt: output.Receipt = undefined,
    failure: anyerror = error.Unexpected,
    temporary_name: [temporary_name_capacity]u8 = undefined,

    pub fn init(self: *Controller, io: std.Io, paths: []u8, content: []u8, preflight_scratch: []u8) Error!void {
        if (paths.len < path_storage_capacity) return error.PathTooLong;
        if (content.len < content_capacity) return error.ContentTooLong;
        if (preflight_scratch.len < content_capacity) return error.ScratchTooSmall;
        if (slices_overlap(paths, content) or slices_overlap(paths, preflight_scratch) or slices_overlap(content, preflight_scratch)) return error.StorageAliased;
        self.* = .{ .io = io, .paths = paths[0..path_storage_capacity], .content = content[0..content_capacity], .preflight_scratch = preflight_scratch[0..content_capacity] };
        self.thread = std.Thread.spawn(.{}, worker, .{self}) catch return error.Busy;
        std.debug.assert(self.thread != null);
        std.debug.assert(self.paths.len == path_storage_capacity and self.content.len == content_capacity and self.preflight_scratch.len == content_capacity);
    }

    /// Stops accepting work, waits for any revalidation/publication step, then joins.
    pub fn deinit(self: *Controller) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.wake.signal(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        std.debug.assert(self.stopping);
    }

    pub fn request(self: *Controller, generation: u64, identity: session.InputIdentity, input_paths: InputPaths, destination: []const u8, bytes: []const u8) Error!void {
        try validate_request_paths(identity, input_paths, destination);
        if (bytes.len > self.content.len) return error.ContentTooLong;
        if (self.input_aliases_storage(input_paths, destination, bytes)) return error.InputStorageAliased;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping or self.job_ready or self.running) return error.Busy;
        self.copy_path(0, destination);
        if (input_paths.base) |base| self.copy_path(1, base) else self.path_lens[1] = 0;
        self.copy_path(2, input_paths.left);
        self.copy_path(3, input_paths.right);
        @memcpy(self.content[0..bytes.len], bytes);
        self.content_len = bytes.len;
        self.job_kind = .save;
        self.job_id +%= 1;
        self.generation = generation;
        self.identity = identity;
        self.state = .pending;
        self.job_ready = true;
        self.wake.signal(self.io);
        std.debug.assert(self.path_lens[0] > 0 and self.path_lens[2] > 0 and self.path_lens[3] > 0);
        std.debug.assert((self.path_lens[1] != 0) == (identity.base != null));
    }

    /// Reports single immutable job identity even after UI state advances.
    pub fn observe(self: *Controller) Observed {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const result: Result = switch (self.state) {
            .idle => .idle,
            .pending => .pending,
            .succeeded => .{ .succeeded = self.receipt },
            .failed => .{ .failed = self.failure },
        };
        return .{ .kind = self.job_kind, .id = self.job_id, .generation = self.generation, .identity = self.identity, .result = result };
    }

    /// Schedules a distinct verification job even for a saved generation.
    /// Verification rereads source paths and output; it does not publish or rewrite.
    pub fn request_verify(self: *Controller, generation: u64, identity: session.InputIdentity, input_paths: InputPaths, destination: []const u8, receipt: output.Receipt) Error!u64 {
        try validate_request_paths(identity, input_paths, destination);
        if (self.input_aliases_storage(input_paths, destination, &.{})) return error.InputStorageAliased;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping or self.job_ready or self.running) return error.Busy;
        self.copy_path(0, destination);
        if (input_paths.base) |base| self.copy_path(1, base) else self.path_lens[1] = 0;
        self.copy_path(2, input_paths.left);
        self.copy_path(3, input_paths.right);
        self.job_kind = .verify;
        self.job_id +%= 1;
        self.generation = generation;
        self.identity = identity;
        self.expected_receipt = receipt;
        self.state = .pending;
        self.job_ready = true;
        self.wake.signal(self.io);
        return self.job_id;
    }

    fn input_aliases_storage(self: *const Controller, input_paths: InputPaths, destination: []const u8, bytes: []const u8) bool {
        const storage = [_][]const u8{ self.paths, self.content, self.preflight_scratch, &self.temporary_name };
        const inputs = [_][]const u8{ destination, input_paths.left, input_paths.right, bytes };
        for (storage) |owned| {
            for (inputs) |input| if (slices_overlap(owned, input)) return true;
            if (input_paths.base) |base| if (slices_overlap(owned, base)) return true;
        }
        return false;
    }

    fn copy_path(self: *Controller, index: usize, source: []const u8) void {
        std.debug.assert(index < self.path_lens.len and source.len > 0 and source.len < path_capacity);
        const destination = self.paths[index * path_capacity ..][0..source.len];
        @memcpy(destination, source);
        self.path_lens[index] = source.len;
    }

    fn worker(self: *Controller) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.stopping and !self.job_ready) self.wake.waitUncancelable(self.io, &self.mutex);
            if (self.stopping and !self.job_ready) {
                self.mutex.unlock(self.io);
                return;
            }
            self.job_ready = false;
            self.running = true;
            self.mutex.unlock(self.io);
            const outcome = switch (self.job_kind) {
                .save => self.preflight_and_publish(),
                .verify => self.revalidate_completion(),
            };

            self.mutex.lockUncancelable(self.io);
            self.running = false;
            if (outcome) |receipt| {
                self.receipt = receipt;
                self.state = .succeeded;
            } else |err| {
                self.failure = err;
                self.state = .failed;
            }
            self.mutex.unlock(self.io);
        }
    }

    fn preflight_and_publish(self: *Controller) !output.Receipt {
        try self.revalidate_input(1, self.identity.base);
        try self.revalidate_input(2, self.identity.left);
        try self.revalidate_input(3, self.identity.right);
        return output.publish_new(self.io, self.path(0), self.content[0..self.content_len], &self.temporary_name);
    }

    fn revalidate_completion(self: *Controller) !output.Receipt {
        try self.revalidate_input(1, self.identity.base);
        try self.revalidate_input(2, self.identity.left);
        try self.revalidate_input(3, self.identity.right);
        const loaded = try files.load(self.io, self.path(0), self.preflight_scratch);
        if (loaded.bytes.len != self.expected_receipt.bytes_written or !std.mem.eql(u8, &loaded.digest, &self.expected_receipt.digest)) return error.OutputChanged;
        return self.expected_receipt;
    }

    fn revalidate_input(self: *Controller, index: usize, expected: ?[32]u8) !void {
        if (expected == null) {
            std.debug.assert(index == 1 and self.path_lens[index] == 0);
            return;
        }
        std.debug.assert(index > 0 and index < self.path_lens.len and self.path_lens[index] > 0);
        const loaded = try files.load(self.io, self.path(index), self.preflight_scratch);
        if (!std.mem.eql(u8, &loaded.digest, &expected.?)) return error.InputChanged;
        std.debug.assert(loaded.bytes.len <= self.preflight_scratch.len);
    }

    fn path(self: *const Controller, index: usize) []const u8 {
        std.debug.assert(index < self.path_lens.len and self.path_lens[index] > 0 and self.path_lens[index] < path_capacity);
        return self.paths[index * path_capacity ..][0..self.path_lens[index]];
    }
};

fn validate_request_paths(identity: session.InputIdentity, input_paths: InputPaths, destination: []const u8) Error!void {
    try validate_path(destination);
    try validate_path(input_paths.left);
    try validate_path(input_paths.right);
    if ((input_paths.base != null) != (identity.base != null)) return error.PathAliasesInput;
    if (input_paths.base) |base| try validate_path(base);
    if (std.mem.eql(u8, destination, input_paths.left) or std.mem.eql(u8, destination, input_paths.right) or (input_paths.base != null and std.mem.eql(u8, destination, input_paths.base.?))) return error.PathAliasesInput;
    std.debug.assert(destination.len > 0 and input_paths.left.len > 0 and input_paths.right.len > 0);
}

fn validate_path(path: []const u8) Error!void {
    if (path.len == 0 or path.len >= path_capacity) return error.PathTooLong;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.NulByte;
    std.debug.assert(path.len > 0 and path.len < path_capacity);
}

fn slices_overlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch return true;
    const right_end = std.math.add(usize, right_start, right.len) catch return true;
    return left_start < right_end and right_start < left_end;
}

test "controller requires disjoint fixed-capacity storage before starting worker" {
    var short_paths: [path_storage_capacity - 1]u8 = undefined;
    var paths: [path_storage_capacity]u8 = undefined;
    var content: [content_capacity]u8 = undefined;
    var scratch: [content_capacity]u8 = undefined;
    var controller: Controller = undefined;
    try std.testing.expectError(error.PathTooLong, controller.init(std.testing.io, &short_paths, &content, &scratch));
    var short_content: [content_capacity - 1]u8 = undefined;
    try std.testing.expectError(error.ContentTooLong, controller.init(std.testing.io, &paths, &short_content, &scratch));
    var short_scratch: [content_capacity - 1]u8 = undefined;
    try std.testing.expectError(error.ScratchTooSmall, controller.init(std.testing.io, &paths, &content, &short_scratch));
}

test "request rejects NUL paths and controller-owned input before copying" {
    const identity: session.InputIdentity = .{ .base = null, .left = std.mem.zeroes([32]u8), .right = std.mem.zeroes([32]u8) };
    const paths: InputPaths = .{ .base = null, .left = "left", .right = "right" };
    try std.testing.expectError(error.NulByte, validate_request_paths(identity, paths, "result\x00suffix"));

    var path_storage: [path_storage_capacity]u8 = undefined;
    var content: [content_capacity]u8 = undefined;
    var scratch: [content_capacity]u8 = undefined;
    var controller: Controller = undefined;
    try controller.init(std.testing.io, &path_storage, &content, &scratch);
    defer controller.deinit();
    try std.testing.expectError(error.InputStorageAliased, controller.request(1, identity, paths, "result", controller.content[0..1]));
}

test "native save preflight blocks changed or missing sources before publication" {
    if (comptime @import("builtin").os.tag != .windows) return;
    if (!native_e2e_enabled()) return;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e";
    try cwd.createDirPath(io, root);
    var fixture_memory: [root.len + 1 + 16]u8 = undefined;
    const fixture = try create_fixture(io, cwd, root, &fixture_memory);
    defer cleanup_dir(cwd, io, fixture);

    var base_memory: [root.len + 1 + 16 + 9]u8 = undefined;
    var left_memory: [root.len + 1 + 16 + 9]u8 = undefined;
    var right_memory: [root.len + 1 + 16 + 10]u8 = undefined;
    var output_memory: [root.len + 1 + 16 + 12]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_memory, "{s}/base.bin", .{fixture});
    const left = try std.fmt.bufPrint(&left_memory, "{s}/left.bin", .{fixture});
    const right = try std.fmt.bufPrint(&right_memory, "{s}/right.bin", .{fixture});
    const destination = try std.fmt.bufPrint(&output_memory, "{s}/result.bin", .{fixture});
    defer cleanup_file(cwd, io, destination);
    defer cleanup_file(cwd, io, right);
    defer cleanup_file(cwd, io, left);
    defer cleanup_file(cwd, io, base);

    try write_file(io, base, "base\n");
    try write_file(io, left, "left\n");
    try write_file(io, right, "right\n");
    const three_way = try input_identity(io, .{ .base = base, .left = left, .right = right });
    try expect_published(io, three_way, .{ .base = base, .left = left, .right = right }, destination, "result\n");
    try expect_file(io, destination, "result\n");
    cleanup_file(cwd, io, destination);

    try write_file(io, left, "LefT\n");
    try expect_blocked(io, three_way, .{ .base = base, .left = left, .right = right }, destination);
    try expect_file(io, base, "base\n");
    try expect_file(io, left, "LefT\n");
    try expect_file(io, right, "right\n");
    try expect_absent(io, destination);
    try write_file(io, left, "left\n");

    try cwd.deleteFile(io, right);
    try expect_blocked(io, three_way, .{ .base = base, .left = left, .right = right }, destination);
    try expect_absent(io, destination);
    try write_file(io, right, "right\n");

    const two_way = try input_identity(io, .{ .base = null, .left = left, .right = right });
    try expect_published(io, two_way, .{ .base = null, .left = left, .right = right }, destination, "two-way\n");
    try expect_file(io, destination, "two-way\n");
}

fn native_e2e_enabled() bool {
    const environ: std.process.Environ = .{ .block = .global };
    const value = environ.getAlloc(std.testing.allocator, "WARKOCZ_NATIVE_E2E") catch return false;
    defer std.testing.allocator.free(value);
    return std.mem.eql(u8, value, "1");
}

fn create_fixture(io: std.Io, cwd: std.Io.Dir, root: []const u8, memory: []u8) ![]const u8 {
    std.debug.assert(memory.len == root.len + 1 + 16);
    @memcpy(memory[0..root.len], root);
    memory[root.len] = '/';
    var random: [8]u8 = undefined;
    for (0..16) |_| {
        try io.randomSecure(&random);
        fixture_hex(memory[root.len + 1 ..], &random);
        cwd.createDir(io, memory, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |unexpected| return unexpected,
        };
        return memory;
    }
    return error.Busy;
}

fn fixture_hex(destination: []u8, source: []const u8) void {
    const alphabet = "0123456789abcdef";
    std.debug.assert(destination.len == source.len * 2);
    for (source, 0..) |byte, index| {
        destination[index * 2] = alphabet[byte >> 4];
        destination[index * 2 + 1] = alphabet[byte & 15];
    }
}

fn write_file(io: std.Io, path: []const u8, bytes: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |unexpected| return unexpected,
    };
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
}

fn input_identity(io: std.Io, paths: InputPaths) !session.InputIdentity {
    var scratch: [content_capacity]u8 = undefined;
    const base = if (paths.base) |path| (try files.load(io, path, &scratch)).digest else null;
    const left = (try files.load(io, paths.left, &scratch)).digest;
    const right = (try files.load(io, paths.right, &scratch)).digest;
    return .{ .base = base, .left = left, .right = right };
}

fn expect_published(io: std.Io, identity: session.InputIdentity, paths: InputPaths, destination: []const u8, result: []const u8) !void {
    var path_storage: [path_storage_capacity]u8 = undefined;
    var content: [content_capacity]u8 = undefined;
    var scratch: [content_capacity]u8 = undefined;
    var controller: Controller = undefined;
    try controller.init(io, &path_storage, &content, &scratch);
    defer controller.deinit();
    try controller.request(1, identity, paths, destination, result);
    const observed = try wait_for_result(&controller);
    switch (observed) {
        .succeeded => {},
        .failed => |err| return err,
        .idle, .pending => unreachable,
    }
}

fn expect_blocked(io: std.Io, identity: session.InputIdentity, paths: InputPaths, destination: []const u8) !void {
    var path_storage: [path_storage_capacity]u8 = undefined;
    var content: [content_capacity]u8 = undefined;
    var scratch: [content_capacity]u8 = undefined;
    var controller: Controller = undefined;
    try controller.init(io, &path_storage, &content, &scratch);
    defer controller.deinit();
    try controller.request(1, identity, paths, destination, "blocked\n");
    const observed = try wait_for_result(&controller);
    switch (observed) {
        .failed => {},
        .succeeded => return error.TestUnexpectedResult,
        .idle, .pending => unreachable,
    }
}

fn wait_for_result(controller: *Controller) !Result {
    for (0..5000) |_| {
        const result = controller.observe().result;
        if (result != .pending) return result;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .real);
    }
    return error.TestUnexpectedResult;
}

fn expect_file(io: std.Io, path: []const u8, expected: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [64]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const actual = try reader.interface.allocRemaining(std.testing.allocator, .limited(expected.len));
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualSlices(u8, expected, actual);
}

fn expect_absent(io: std.Io, path: []const u8) !void {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |unexpected| return unexpected,
    };
    file.close(io);
    return error.TestUnexpectedResult;
}

fn cleanup_file(cwd: std.Io.Dir, io: std.Io, path: []const u8) void {
    cwd.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => @panic(@errorName(err)),
    };
}

fn cleanup_dir(cwd: std.Io.Dir, io: std.Io, path: []const u8) void {
    cwd.deleteDir(io, path) catch |err| @panic(@errorName(err));
}
