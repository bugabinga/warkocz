const std = @import("std");
const builtin = @import("builtin");
const files = @import("../files.zig");
const git_process = @import("git_process.zig");
const paths = @import("paths.zig");
const trust = @import("trust.zig");
const windows = std.os.windows;

pub const Operation = enum { worktree_status, stage, unstage, commit, branch_create, branch_rename, branch_delete, fetch, push };
pub const Fingerprint = trust.Fingerprint;

/// Caller-owned output and scratch regions.
/// Successful collection returns slices into `canonical_*`; no result borrows scratch.
pub const ConfigSources = struct {
    global: ?[]const u8 = null,
    system: ?[]const u8 = null,
    no_system: ?bool = null,
};

pub const Buffers = struct {
    config_sources: ConfigSources = .{},
    command: []u8,
    environment: []u8,
    file: []u8,
    canonical_executable: []u8,
    canonical_repository: []u8,
    canonical_git: []u8,
    canonical_worktree: []u8,
    canonical_common_dir: []u8,
};

/// Fixed owned commit identity captured with branch operation evidence.
pub const BranchTarget = struct {
    bytes: [64]u8 = undefined,
    len: u8 = 0,

    pub fn oid(self: *const BranchTarget) []const u8 {
        std.debug.assert(self.len == 40 or self.len == 64);
        return self.bytes[0..self.len];
    }
};

pub const Collected = struct {
    preflight: Preflight,
    /// Present for branch creation, rename, and deletion; never borrows scratch.
    branch_target: ?BranchTarget = null,
    remote_summary: RemoteSummary = .{},
    repository: []const u8,
    executable: []const u8,
    git_dir: []const u8,
    worktree: []const u8,
    common_dir: []const u8,
};

/// Immutable evidence collected before a record action is offered.
/// This detects observed change; it does not close filesystem/process TOCTOU races.
pub const RemoteEndpoint = struct {
    pub const Role = enum { fetch, push };
    role: Role,
    label: [160]u8 = undefined,
    label_len: u8 = 0,

    pub fn text(self: *const RemoteEndpoint) []const u8 {
        return self.label[0..self.label_len];
    }
};

/// Sanitized, owned presentation of effective configured remote URLs.
/// Limits are implementation bounds, not product-approved budgets.
pub const RemoteSummary = struct {
    endpoints: [8]RemoteEndpoint = undefined,
    count: u8 = 0,

    pub fn items(self: *const RemoteSummary) []const RemoteEndpoint {
        return self.endpoints[0..self.count];
    }
};

pub const Preflight = struct {
    repository: Fingerprint,
    worktree: Fingerprint,
    common_dir: Fingerprint,
    head: Fingerprint,
    index: Fingerprint,
    operation_state: Fingerprint,
    executable_config: Fingerprint,
    executable: Fingerprint,
    request: Fingerprint,
    target: Fingerprint,
    attributes: Fingerprint,
    hooks: Fingerprint,
    operation: Operation,
};

pub const Token = struct {
    preflight: Preflight,
    attempted: bool = false,

    pub fn init(preflight: Preflight) Token {
        return .{ .preflight = preflight };
    }

    pub fn verify(self: *const Token, current: Preflight) Error!void {
        if (self.attempted) return error.TokenExpired;
        if (self.preflight.operation != current.operation) return error.ScopeChanged;
        if (!same_preflight(self.preflight, current)) return error.StalePreflight;
    }

    pub fn consume(self: *Token) Error!void {
        if (self.attempted) return error.TokenExpired;
        self.attempted = true;
        std.debug.assert(self.attempted);
    }
};

pub const Request = union(Operation) {
    worktree_status: void,
    stage: struct { path: []const u8 },
    unstage: struct { path: []const u8 },
    commit: struct { message: []const u8 },
    branch_create: struct { name: []const u8, start_point: []const u8 },
    branch_rename: struct { old: []const u8, new: []const u8 },
    branch_delete: struct { target: []const u8 },
    /// Explicit configured remote only. The effective fetch/push policy remains Git's.
    fetch: struct { remote: []const u8 },
    push: struct { remote: []const u8 },
};

/// Deliberately excludes hook/filter output: it can contain paths, content, or credentials.
pub const Result = struct { succeeded: bool, exit_code: ?u8, stdout_bytes: usize, output_bytes: usize };

pub const Error = error{
    EmptyGitExecutable,
    EmptyRepositoryPath,
    GitExecutableNotAbsolute,
    RepositoryPathNotAbsolute,
    InvalidPath,
    InvalidMessage,
    NulByte,
    TokenExpired,
    ScopeChanged,
    StalePreflight,
    TrustDenied,
    OutputLimitExceeded,
    ChildTimeout,
    GitFailed,
    InvalidGitOutput,
    UnsupportedConfigContext,
    UnsupportedOperationState,
    UnsupportedMutationPlatform,
    UnsupportedTargetKind,
    UnsupportedHookDirectory,
    MutationLockBusy,
    IndexLockPresent,
    EvidenceReadFailed,
    AliasedBuffers,
    InvalidBranchName,
    InvalidStartPoint,
    BranchCollision,
    BranchCheckedOut,
    MissingRemote,
    MissingPushTarget,
    AmbiguousPushTarget,
    ForcePushNotSupported,
    RemoteSummaryLimitExceeded,
    DedicatedStatusRequired,
} || std.mem.Allocator.Error || std.process.RunError;

/// Collects stable caller-owned preflight evidence using installed Git read-only queries.
/// Global/system config remains effective; inherited GIT routing/config injection is removed.
pub fn collect(io: std.Io, absolute_git: []const u8, absolute_repository: []const u8, request: Request, buffers: Buffers) Error!Collected {
    try validate_location(absolute_git, absolute_repository);
    try validate_request(request);
    try validate_buffers(buffers);
    const git = try canonicalize(io, absolute_git, buffers.canonical_executable);
    const repository = try canonicalize(io, absolute_repository, buffers.canonical_repository);
    const locations = try git_locations(io, git, repository, buffers.command, buffers.environment, buffers.config_sources);
    const git_dir = try canonicalize(io, locations.git_dir, buffers.canonical_git);
    const worktree = try canonicalize(io, locations.worktree, buffers.canonical_worktree);
    const common_dir = try canonicalize(io, locations.common_dir, buffers.canonical_common_dir);
    // Git porcelain paths are worktree-root-relative, even when selected repository is a subdirectory.
    const head = try head_fingerprint(io, git, worktree, buffers.command, buffers.environment, buffers.config_sources);
    const index = try path_fingerprint(io, git_dir, "index", buffers.command, buffers.file);
    const operation_state = try operation_fingerprint(io, git_dir, buffers.command, buffers.file);
    const executable_config = try config_fingerprint(io, git, worktree, buffers.command, buffers.environment, buffers.file, buffers.config_sources);
    var remote_summary: RemoteSummary = .{};
    var branch_target: ?BranchTarget = null;
    const target = try target_fingerprint(io, git, worktree, worktree, request, buffers.command, buffers.environment, buffers.file, buffers.config_sources, &remote_summary, &branch_target);
    const attributes = try attributes_fingerprint(io, git, worktree, git_dir, worktree, request, buffers.command, buffers.environment, buffers.file, buffers.config_sources);
    const hooks = try hooks_fingerprint(io, git, worktree, request, buffers.command, buffers.environment, buffers.file, buffers.config_sources);
    const executable = try executable_fingerprint(io, git, buffers.file);
    return .{ .preflight = .{
        .repository = trust.fingerprint(repository),
        .worktree = trust.fingerprint(worktree),
        .common_dir = trust.fingerprint(common_dir),
        .head = head,
        .index = index,
        .operation_state = operation_state,
        .executable_config = executable_config,
        .executable = executable,
        .request = request_fingerprint(request),
        .target = target,
        .attributes = attributes,
        .hooks = hooks,
        .operation = std.meta.activeTag(request),
    }, .branch_target = branch_target, .remote_summary = remote_summary, .repository = repository, .executable = git, .git_dir = git_dir, .worktree = worktree, .common_dir = common_dir };
}

/// Produces literal installed-Git argv for one whole-file operation.
/// `--literal-pathspecs` is global because `--` does not disable Git path magic.
pub fn argv(request: Request, git_exe: []const u8, repository_path: []const u8, destination: [][]const u8) Error![]const []const u8 {
    return argv_resolved(request, git_exe, repository_path, null, destination);
}

test "branch-create argv keeps captured OID when symbolic start point later moves" {
    var symbolic = [_]u8{ 'r', 'e', 'f', 's', '/', 't', 'a', 'g', 's', '/', 'v', '1' };
    const request: Request = .{ .branch_create = .{ .name = "created", .start_point = &symbolic } };
    const captured = "0123456789012345678901234567890123456789";
    const git_exe = if (builtin.os.tag == .windows) "C:/git.exe" else "/git";
    const repository = if (builtin.os.tag == .windows) "C:/repo" else "/repo";
    var destination: [9][]const u8 = undefined;
    const command = try argv_resolved(request, git_exe, repository, captured, &destination);
    @memset(&symbolic, 'x');
    try std.testing.expectEqual(@as(usize, 8), command.len);
    try std.testing.expectEqualStrings(captured, command[7]);
    try std.testing.expect(!std.mem.eql(u8, command[7], request.branch_create.start_point));
}

test "branch target owns validated SHA1 and SHA256 bytes" {
    var scratch: [65]u8 = @splat('a');
    const expected: [64]u8 = @splat('a');
    for ([_]usize{ 40, 64 }) |length| {
        @memset(&scratch, 'a');
        const captured = try capture_branch_target(scratch[0..length]);
        @memset(&scratch, 'b');
        try std.testing.expectEqualStrings(expected[0..length], captured.oid());
    }
    try std.testing.expectError(error.InvalidGitOutput, capture_branch_target(scratch[0..39]));
    try std.testing.expectError(error.InvalidGitOutput, capture_branch_target(&scratch));
    scratch[0] = 'g';
    try std.testing.expectError(error.InvalidGitOutput, capture_branch_target(scratch[0..40]));
    try std.testing.expectError(error.InvalidGitOutput, capture_branch_target(scratch[0..64]));
}

fn argv_resolved(request: Request, git_exe: []const u8, repository_path: []const u8, resolved_start_point: ?[]const u8, destination: [][]const u8) Error![]const []const u8 {
    try validate_location(git_exe, repository_path);
    const common = [_][]const u8{ git_exe, "--literal-pathspecs", "-C", repository_path, "--no-pager" };
    if (destination.len < common.len + 4) return error.OutputLimitExceeded;
    @memcpy(destination[0..common.len], &common);
    switch (request) {
        .worktree_status => return error.DedicatedStatusRequired,
        .stage => |value| {
            try validate_path(value.path);
            destination[5] = "add";
            destination[6] = "--";
            destination[7] = value.path;
            return destination[0..8];
        },
        .unstage => |value| {
            try validate_path(value.path);
            if (destination.len < 9) return error.OutputLimitExceeded;
            destination[5] = "restore";
            destination[6] = "--staged";
            destination[7] = "--";
            destination[8] = value.path;
            return destination[0..9];
        },
        .commit => |value| {
            try validate_message(value.message);
            destination[5] = "commit";
            destination[6] = "-m";
            destination[7] = value.message;
            return destination[0..8];
        },
        .branch_create => |value| {
            try validate_branch_name(value.name);
            destination[5] = "branch";
            destination[6] = value.name;
            destination[7] = resolved_start_point orelse value.start_point;
            return destination[0..8];
        },
        .branch_rename => |value| {
            try validate_branch_name(value.old);
            try validate_branch_name(value.new);
            destination[5] = "branch";
            destination[6] = "-m";
            destination[7] = value.old;
            destination[8] = value.new;
            return destination[0..9];
        },
        .branch_delete => |value| {
            try validate_branch_name(value.target);
            destination[5] = "branch";
            destination[6] = "-d";
            destination[7] = value.target;
            return destination[0..8];
        },
        .fetch => |value| {
            try validate_remote_name(value.remote);
            destination[5] = "fetch";
            destination[6] = value.remote;
            return destination[0..7];
        },
        .push => |value| {
            try validate_remote_name(value.remote);
            destination[5] = "push";
            destination[6] = value.remote;
            return destination[0..7];
        },
    }
}

/// Legacy evidence-only route is disabled: callers must use execute_revalidated.
pub fn execute(_: std.Io, _: *const trust.Store, token: *Token, _: Preflight, _: []const u8, _: []const u8, _: Request, _: []u8, _: usize, _: usize, _: std.Io.Timeout) Error!Result {
    try token.consume();
    return error.UnsupportedMutationPlatform;
}

/// Revalidates evidence under a common-directory exclusive-create lock immediately before Git.
/// POSIX cleanup cannot safely unlink an attacker-swapped pathname through std.Io, so mutation is rejected there.
pub fn execute_revalidated(io: std.Io, store: *const trust.Store, token: *Token, initial: Collected, request: Request, buffers: Buffers, workspace: []u8, stdout_limit: usize, stderr_limit: usize, timeout: std.Io.Timeout) Error!Result {
    try token.consume();
    if (request == .worktree_status) return error.DedicatedStatusRequired;
    if (!store.allows(token.preflight.repository, token.preflight.executable_config, scope(request))) return error.TrustDenied;
    if (comptime builtin.os.tag != .windows) return error.UnsupportedMutationPlatform;
    const lock_file = create_lock(io, initial.common_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return error.MutationLockBusy,
        else => return error.EvidenceReadFailed,
    };
    const result = execute_with_lock(io, lock_file, token.preflight, initial, request, buffers, workspace, stdout_limit, stderr_limit, timeout);
    release_lock(lock_file) catch return error.EvidenceReadFailed;
    return result;
}

/// Executes a granted status scan under the same lock and fresh evidence as mutations.
/// `status_output` is caller-owned; Result never borrows process output.
pub fn execute_worktree_status_revalidated(io: std.Io, store: *const trust.Store, token: *Token, initial: Collected, buffers: Buffers, workspace: []u8, status_output: []u8, stdout_limit: usize, stderr_limit: usize, timeout: std.Io.Timeout) Error!Result {
    try token.consume();
    if (token.preflight.operation != .worktree_status or initial.preflight.operation != .worktree_status) return error.ScopeChanged;
    if (!store.allows(token.preflight.repository, token.preflight.executable_config, .worktree_status)) return error.TrustDenied;
    try validate_status_buffers(buffers, workspace, status_output, stdout_limit, stderr_limit);
    if (comptime builtin.os.tag != .windows) return error.UnsupportedMutationPlatform;
    const lock_file = create_lock(io, initial.common_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return error.MutationLockBusy,
        else => return error.EvidenceReadFailed,
    };
    const result = execute_status_with_lock(io, lock_file, token.preflight, initial, buffers, workspace, status_output, stdout_limit, stderr_limit, timeout);
    release_lock(lock_file) catch return error.EvidenceReadFailed;
    return result;
}

fn execute_status_with_lock(io: std.Io, lock_file: std.Io.File, preflight: Preflight, initial: Collected, buffers: Buffers, workspace: []u8, status_output: []u8, stdout_limit: usize, stderr_limit: usize, timeout: std.Io.Timeout) Error!Result {
    var nonce: [32]u8 = undefined;
    io.randomSecure(&nonce) catch return error.EvidenceReadFailed;
    lock_file.writeStreamingAll(io, &nonce) catch return error.EvidenceReadFailed;
    const fresh = try collect(io, initial.executable, initial.repository, .{ .worktree_status = {} }, buffers);
    if (!same_preflight(preflight, fresh.preflight) or !same_preflight(initial.preflight, fresh.preflight)) return error.StalePreflight;
    if (stdout_limit == 0 or stderr_limit == 0 or status_output.len < stdout_limit) return error.OutputLimitExceeded;
    const command = [_][]const u8{ fresh.executable, "--no-lazy-fetch", "--literal-pathspecs", "-C", fresh.worktree, "--no-pager", "-c", "core.fsmonitor=false", "status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignored=no" };
    const output = try run_status_command(io, &command, buffers.environment, buffers.config_sources, workspace, stdout_limit, stderr_limit, timeout);
    if (output.stdout.len > status_output.len) return error.OutputLimitExceeded;
    @memcpy(status_output[0..output.stdout.len], output.stdout);
    return .{ .succeeded = output.term.success(), .exit_code = switch (output.term) {
        .exited => |value| value,
        else => null,
    }, .stdout_bytes = output.stdout.len, .output_bytes = output.stdout.len + output.stderr.len };
}

fn run_status_command(io: std.Io, command: []const []const u8, environment_workspace: []u8, sources: ConfigSources, workspace: []u8, stdout_limit: usize, stderr_limit: usize, timeout: std.Io.Timeout) Error!std.process.RunResult {
    var environment_allocator = std.heap.FixedBufferAllocator.init(environment_workspace);
    var environment = try inherited_environment(environment_allocator.allocator());
    defer environment.deinit();
    sanitize_git_environment(&environment);
    apply_config_sources(&environment, sources) catch return error.OutputLimitExceeded;
    environment.put("GIT_OPTIONAL_LOCKS", "0") catch return error.OutputLimitExceeded;
    var allocator = std.heap.FixedBufferAllocator.init(workspace);
    return git_process.run(allocator.allocator(), io, .{ .argv = command, .environ_map = &environment, .cwd = .inherit, .stdout_limit = .limited(stdout_limit), .stderr_limit = .limited(stderr_limit), .reserve_amount = 64, .timeout = timeout }) catch |err| switch (err) {
        error.StreamTooLong, error.OutOfMemory => error.OutputLimitExceeded,
        error.Timeout => error.ChildTimeout,
        else => |unexpected| unexpected,
    };
}

fn execute_with_lock(io: std.Io, lock_file: std.Io.File, preflight: Preflight, initial: Collected, request: Request, buffers: Buffers, workspace: []u8, stdout_limit: usize, stderr_limit: usize, timeout: std.Io.Timeout) Error!Result {
    var nonce: [32]u8 = undefined;
    io.randomSecure(&nonce) catch return error.EvidenceReadFailed;
    lock_file.writeStreamingAll(io, &nonce) catch return error.EvidenceReadFailed;
    var lock_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const index_lock = try join_path(initial.git_dir, "index.lock", &lock_path);
    if (std.Io.Dir.cwd().statFile(io, index_lock, .{ .follow_symlinks = false })) |_| return error.IndexLockPresent else |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => return error.EvidenceReadFailed,
    }
    const fresh = try collect(io, initial.executable, initial.repository, request, buffers);
    if (!same_preflight(preflight, fresh.preflight) or !same_preflight(initial.preflight, fresh.preflight)) return error.StalePreflight;
    var args: [9][]const u8 = undefined;
    const captured_start_point: ?BranchTarget = if (request == .branch_create) fresh.branch_target orelse return error.ScopeChanged else null;
    const command = try argv_resolved(request, fresh.executable, fresh.worktree, if (captured_start_point) |*value| value.oid() else null, &args);
    if (stdout_limit == 0 or stderr_limit == 0) return error.OutputLimitExceeded;
    var environment_allocator = std.heap.FixedBufferAllocator.init(buffers.environment);
    var environment = try inherited_environment(environment_allocator.allocator());
    defer environment.deinit();
    sanitize_git_environment(&environment);
    apply_config_sources(&environment, buffers.config_sources) catch return error.OutputLimitExceeded;
    var allocator = std.heap.FixedBufferAllocator.init(workspace);
    const started = if (builtin.is_test) std.Io.Clock.awake.now(io) else undefined;
    const output = git_process.run(allocator.allocator(), io, .{ .argv = command, .environ_map = &environment, .cwd = .inherit, .stdout_limit = .limited(stdout_limit), .stderr_limit = .limited(stderr_limit), .reserve_amount = 64, .timeout = timeout }) catch |err| {
        if (builtin.is_test) log_subprocess_failure(io, "execute", command, started, err);
        return switch (err) {
            error.StreamTooLong, error.OutOfMemory => error.OutputLimitExceeded,
            error.Timeout => error.ChildTimeout,
            else => |unexpected| unexpected,
        };
    };
    return .{ .succeeded = output.term.success(), .exit_code = switch (output.term) {
        .exited => |value| value,
        else => null,
    }, .stdout_bytes = output.stdout.len, .output_bytes = output.stdout.len + output.stderr.len };
}

fn create_lock(io: std.Io, common_dir: []const u8) !std.Io.File {
    const parent = try std.Io.Dir.cwd().openDir(io, common_dir, .{ .access_sub_paths = true, .follow_symlinks = false });
    defer parent.close(io);
    const name_w = [_]u16{ 'w', 'a', 'r', 'k', 'o', 'c', 'z', '-', 'o', 'p', 'e', 'r', 'a', 't', 'i', 'o', 'n', '.', 'l', 'o', 'c', 'k' };
    var object_name = windows.UNICODE_STRING.init(&name_w);
    const attributes: windows.OBJECT.ATTRIBUTES = .{ .RootDirectory = parent.handle, .ObjectName = &object_name };
    var status_block: windows.IO_STATUS_BLOCK = undefined;
    var handle: windows.HANDLE = undefined;
    const status = windows.ntdll.NtCreateFile(&handle, .{ .STANDARD = .{ .RIGHTS = .{ .DELETE = true }, .SYNCHRONIZE = true }, .GENERIC = .{ .WRITE = true } }, &attributes, &status_block, null, .{ .NORMAL = true }, .{}, .CREATE, .{ .DELETE_ON_CLOSE = true, .NON_DIRECTORY_FILE = true, .IO = .SYNCHRONOUS_NONALERT }, null, 0);
    return switch (status) {
        .SUCCESS => .{ .handle = handle, .flags = .{ .nonblocking = false } },
        .OBJECT_NAME_COLLISION => error.PathAlreadyExists,
        .ACCESS_DENIED => error.AccessDenied,
        .OBJECT_PATH_NOT_FOUND, .OBJECT_NAME_NOT_FOUND => error.FileNotFound,
        .FILE_IS_A_DIRECTORY => error.IsDir,
        .NOT_A_DIRECTORY => error.NotDir,
        else => error.Unexpected,
    };
}

fn release_lock(file: std.Io.File) !void {
    if (windows.ntdll.NtClose(file.handle) != .SUCCESS) return error.Unexpected;
}

pub fn scope(request: Request) trust.Scope {
    return switch (request) {
        .worktree_status => .worktree_status,
        .stage => .stage,
        .unstage => .unstage,
        .commit => .commit,
        .branch_create => .branch_create,
        .branch_rename => .branch_rename,
        .branch_delete => .branch_delete,
        .fetch => .fetch,
        .push => .push,
    };
}

pub fn same_preflight(left: Preflight, right: Preflight) bool {
    return left.operation == right.operation and same(left.repository, right.repository) and same(left.worktree, right.worktree) and same(left.common_dir, right.common_dir) and same(left.head, right.head) and same(left.index, right.index) and same(left.operation_state, right.operation_state) and same(left.executable_config, right.executable_config) and same(left.executable, right.executable) and same(left.request, right.request) and same(left.target, right.target) and same(left.attributes, right.attributes) and same(left.hooks, right.hooks);
}

const Locations = struct { git_dir: []const u8, common_dir: []const u8, worktree: []const u8 };

fn git_locations(io: std.Io, git: []const u8, repository: []const u8, scratch: []u8, environment: []u8, sources: ConfigSources) Error!Locations {
    const command = [_][]const u8{ git, "-C", repository, "--no-pager", "-c", "core.fsmonitor=false", "rev-parse", "--path-format=absolute", "--absolute-git-dir", "--git-common-dir", "--show-toplevel" };
    const output = try run(io, &command, scratch, environment, sources);
    if (!output.success) return error.GitFailed;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, output.bytes, "\r\n"), '\n');
    const git_dir = lines.next() orelse return error.InvalidGitOutput;
    const common_dir = lines.next() orelse return error.InvalidGitOutput;
    const worktree = lines.next() orelse return error.InvalidGitOutput;
    if (lines.next() != null or !std.fs.path.isAbsolute(git_dir) or !std.fs.path.isAbsolute(common_dir) or !std.fs.path.isAbsolute(worktree)) return error.InvalidGitOutput;
    return .{ .git_dir = git_dir, .common_dir = common_dir, .worktree = worktree };
}

fn head_fingerprint(io: std.Io, git: []const u8, repository: []const u8, scratch: []u8, environment: []u8, sources: ConfigSources) Error!Fingerprint {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const resolved_command = [_][]const u8{ git, "-C", repository, "--no-pager", "-c", "core.fsmonitor=false", "rev-parse", "--verify", "-q", "HEAD" };
    const resolved = try run(io, &resolved_command, scratch, environment, sources);
    if (!resolved.success and resolved.exit_code != 1) return error.GitFailed;
    hash.update("resolved\x00");
    hash.update(if (resolved.success) std.mem.trimEnd(u8, resolved.bytes, "\r\n") else "unborn");
    const symbolic_command = [_][]const u8{ git, "-C", repository, "--no-pager", "-c", "core.fsmonitor=false", "symbolic-ref", "-q", "HEAD" };
    const symbolic = try run(io, &symbolic_command, scratch, environment, sources);
    if (!symbolic.success and symbolic.exit_code != 1) return error.GitFailed;
    hash.update("symbolic\x00");
    hash.update(if (symbolic.success) std.mem.trimEnd(u8, symbolic.bytes, "\r\n") else "detached-or-unborn");
    var result: Fingerprint = undefined;
    hash.final(&result);
    return result;
}

fn operation_fingerprint(io: std.Io, git_dir: []const u8, path_scratch: []u8, file_scratch: []u8) Error!Fingerprint {
    const markers = [_][]const u8{ "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "sequencer", "rebase-merge", "rebase-apply" };
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (markers) |marker| {
        const path = try join_path(git_dir, marker, path_scratch);
        hash.update(marker);
        const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                hash.update("absent");
                continue;
            },
            else => return error.EvidenceReadFailed,
        };
        hash.update("present");
        if (stat.kind == .file) {
            const loaded = files.load(io, path, file_scratch) catch return error.EvidenceReadFailed;
            hash.update(&loaded.digest);
        }
        var value: Fingerprint = undefined;
        hash.final(&value);
        return error.UnsupportedOperationState;
    }
    var result: Fingerprint = undefined;
    hash.final(&result);
    return result;
}

fn config_fingerprint(io: std.Io, git: []const u8, repository: []const u8, scratch: []u8, environment: []u8, file_scratch: []u8, sources: ConfigSources) Error!Fingerprint {
    const command = [_][]const u8{ git, "-C", repository, "--no-pager", "-c", "core.fsmonitor=false", "config", "--null", "--show-origin", "--show-scope", "--list" };
    const output = try run(io, &command, scratch, environment, sources);
    if (!output.success) return error.GitFailed;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(output.bytes);
    hash.update(sources.global orelse "inherited global config");
    hash.update(sources.system orelse "inherited system config");
    hash.update(if (sources.no_system) |value| (if (value) "no-system" else "system-enabled") else "inherited system selector");
    const environment_fingerprint = try execution_environment_fingerprint(environment, sources);
    hash.update(&environment_fingerprint);
    var records = std.mem.splitScalar(u8, output.bytes, 0);
    while (records.next()) |scope_name| {
        if (scope_name.len == 0) continue;
        const origin = records.next() orelse return error.InvalidGitOutput;
        const entry = records.next() orelse return error.InvalidGitOutput;
        if (entry.len == 0) return error.InvalidGitOutput;
        if (std.mem.startsWith(u8, origin, "file:")) {
            const path = try config_origin_path(repository, origin["file:".len..], environment);
            const loaded = files.load(io, path, file_scratch) catch return error.EvidenceReadFailed;
            hash.update(origin);
            hash.update(&loaded.digest);
        } else if (!std.mem.eql(u8, origin, "command line:") and !std.mem.eql(u8, origin, "standard input:") and !std.mem.eql(u8, origin, "blob:")) return error.UnsupportedConfigContext;
    }
    var result: Fingerprint = undefined;
    hash.final(&result);
    return result;
}

fn config_origin_path(repository: []const u8, origin_path: []const u8, destination: []u8) Error![]const u8 {
    if (std.fs.path.isAbsolute(origin_path)) return origin_path;
    if (origin_path.len == 0 or std.mem.indexOfScalar(u8, origin_path, 0) != null) return error.UnsupportedConfigContext;
    return join_path(repository, origin_path, destination);
}

fn executable_fingerprint(io: std.Io, git: []const u8, scratch: []u8) Error!Fingerprint {
    const loaded = files.load(io, git, scratch) catch return error.EvidenceReadFailed;
    return loaded.digest;
}

fn path_fingerprint(io: std.Io, parent: []const u8, leaf: []const u8, path_scratch: []u8, file_scratch: []u8) Error!Fingerprint {
    const path = try join_path(parent, leaf, path_scratch);
    const loaded = files.load(io, path, file_scratch) catch |err| switch (err) {
        error.FileNotFound => return trust.fingerprint("absent\x00"),
        else => return error.EvidenceReadFailed,
    };
    return loaded.digest;
}

/// Binds stage to exact regular-file bytes, or explicit absence for a deletion.
/// Unstage binds the selected index entry; whole-index identity remains separately bound.
fn target_fingerprint(io: std.Io, git: []const u8, repository: []const u8, worktree: []const u8, request: Request, path_scratch: []u8, environment: []u8, file_scratch: []u8, sources: ConfigSources, remote_summary: *RemoteSummary, branch_target: *?BranchTarget) Error!Fingerprint {
    std.debug.assert(branch_target.* == null);
    switch (request) {
        .worktree_status => return trust.fingerprint("worktree status target\x00"),
        .branch_create, .branch_rename, .branch_delete => return branch_fingerprint(io, git, repository, request, path_scratch, environment, sources, branch_target),
        .fetch, .push => return remote_fingerprint(io, git, repository, request, path_scratch, environment, file_scratch, sources, remote_summary),
        .commit => return trust.fingerprint("commit target: staged index\x00"),
        .unstage => |value| {
            const command = [_][]const u8{ git, "--literal-pathspecs", "-C", repository, "--no-pager", "ls-files", "-s", "-z", "--", value.path };
            const output = try run(io, &command, path_scratch, environment, sources);
            if (!output.success) return error.GitFailed;
            return trust.fingerprint(output.bytes);
        },
        .stage => |value| {
            const path = try join_path(worktree, value.path, path_scratch);
            const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return trust.fingerprint("stage deletion: absent\x00"),
                else => return error.EvidenceReadFailed,
            };
            if (stat.kind != .file) return error.UnsupportedTargetKind;
            const loaded = files.load(io, path, file_scratch) catch return error.EvidenceReadFailed;
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hash.update("stage regular file\x00");
            hash.update(&loaded.digest);
            hash.update(std.mem.asBytes(&stat.size));
            var result: Fingerprint = undefined;
            hash.final(&result);
            return result;
        },
    }
}

fn capture_branch_target(oid: []const u8) Error!BranchTarget {
    if (oid.len != 40 and oid.len != 64) return error.InvalidGitOutput;
    for (oid) |byte| if (!std.ascii.isHex(byte)) return error.InvalidGitOutput;
    var result = BranchTarget{ .len = @intCast(oid.len) };
    @memcpy(result.bytes[0..result.len], oid);
    std.debug.assert(std.mem.eql(u8, result.oid(), oid));
    return result;
}

pub fn resolve_start_point(io: std.Io, git: []const u8, repository: []const u8, start_point: []const u8, scratch: []u8, environment: []u8, sources: ConfigSources) Error![]const u8 {
    var expression: [4096]u8 = undefined;
    if (start_point.len + "^{commit}".len > expression.len) return error.InvalidStartPoint;
    @memcpy(expression[0..start_point.len], start_point);
    @memcpy(expression[start_point.len..][0.."^{commit}".len], "^{commit}");
    const operand = expression[0 .. start_point.len + "^{commit}".len];
    const command = [_][]const u8{ git, "-C", repository, "--no-pager", "rev-parse", "--verify", "--end-of-options", operand };
    const output = try run(io, &command, scratch, environment, sources);
    if (!output.success) return error.InvalidStartPoint;
    const oid = std.mem.trimEnd(u8, output.bytes, "\r\n");
    if (oid.len != 40 and oid.len != 64) return error.InvalidGitOutput;
    for (oid) |byte| if (!std.ascii.isHex(byte)) return error.InvalidGitOutput;
    return oid;
}

fn branch_fingerprint(io: std.Io, git: []const u8, repository: []const u8, request: Request, scratch: []u8, environment: []u8, sources: ConfigSources, branch_target: *?BranchTarget) Error!Fingerprint {
    var inventory: Run = undefined;
    var destination: ?[]const u8 = null;
    var source: ?[]const u8 = null;
    switch (request) {
        .branch_create => |value| destination = value.name,
        .branch_rename => |value| {
            source = value.old;
            destination = value.new;
        },
        .branch_delete => |value| source = value.target,
        else => return error.InvalidGitOutput,
    }
    if (destination) |name| try check_branch_name(io, git, repository, name, scratch, environment, sources);
    if (source) |name| try check_branch_name(io, git, repository, name, scratch, environment, sources);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("refs-inventory-and-worktrees\x00");
    if (request == .branch_create) {
        const oid = try resolve_start_point(io, git, repository, request.branch_create.start_point, scratch, environment, sources);
        branch_target.* = try capture_branch_target(oid);
        hash.update("branch-create-start-point\x00");
        hash.update(branch_target.*.?.oid());
    }
    if (source) |name| {
        const worktree_command = [_][]const u8{ git, "-C", repository, "--no-pager", "worktree", "list", "--porcelain", "-z" };
        const worktrees = try run(io, &worktree_command, scratch, environment, sources);
        if (!worktrees.success) return error.GitFailed;
        hash.update(worktrees.bytes);
        var fields = std.mem.splitScalar(u8, worktrees.bytes, 0);
        while (fields.next()) |field| {
            if (std.mem.startsWith(u8, field, "branch ") and is_branch_ref(field["branch ".len..], name)) return error.BranchCheckedOut;
        }
    }
    const inventory_command = [_][]const u8{ git, "-C", repository, "--no-pager", "for-each-ref", "--format=%(refname)%00%(objectname)", "refs/heads" };
    inventory = try run(io, &inventory_command, scratch, environment, sources);
    if (!inventory.success) return error.GitFailed;
    hash.update(inventory.bytes);
    const source_ref = source;
    const destination_ref = destination;
    var records = std.mem.splitScalar(u8, inventory.bytes, '\n');
    var found_source = false;
    var found_destination = false;
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const separator = std.mem.indexOfScalar(u8, record, 0) orelse return error.InvalidGitOutput;
        const ref = record[0..separator];
        if (source_ref) |wanted| {
            if (is_branch_ref(ref, wanted)) {
                found_source = true;
                branch_target.* = try capture_branch_target(std.mem.trimEnd(u8, record[separator + 1 ..], "\r"));
                hash.update(record);
            }
        }
        if (destination_ref) |wanted| {
            if (is_branch_ref(ref, wanted)) found_destination = true;
        }
    }
    if (source != null and !found_source) return error.InvalidBranchName;
    if (destination != null and found_destination and (source == null or !std.mem.eql(u8, source.?, destination.?))) return error.BranchCollision;
    if (source != null and destination != null and std.mem.eql(u8, source.?, destination.?)) return error.InvalidBranchName;
    var result: Fingerprint = undefined;
    hash.final(&result);
    return result;
}

/// Binds exact configured remote data and local refs without contacting that remote.
/// Endpoint/refspec bytes remain only in scratch and fingerprint input.
fn remote_fingerprint(io: std.Io, git: []const u8, repository: []const u8, request: Request, scratch: []u8, environment: []u8, source_scratch: []u8, sources: ConfigSources, summary: *RemoteSummary) Error!Fingerprint {
    const remote = switch (request) {
        .fetch => |value| value.remote,
        .push => |value| value.remote,
        else => return error.InvalidGitOutput,
    };
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("configured-remote\x00");
    hash.update(remote);
    if (request == .push and try remote_mirror_enabled(io, git, repository, remote, scratch, environment, sources, &hash)) return error.ForcePushNotSupported;
    const endpoint_command = [_][]const u8{ git, "-C", repository, "--no-pager", "remote", "get-url", "--all", remote };
    const endpoints = try run(io, &endpoint_command, scratch, environment, sources);
    if (!endpoints.success or endpoints.bytes.len == 0) return error.MissingRemote;
    hash.update(endpoints.bytes);
    var presentation: RemoteSummary = .{};
    if (request == .fetch) try append_remote_endpoints(&presentation, .fetch, endpoints.bytes);
    const push_endpoint_command = [_][]const u8{ git, "-C", repository, "--no-pager", "remote", "get-url", "--push", "--all", remote };
    const push_endpoints = try run(io, &push_endpoint_command, scratch, environment, sources);
    if (!push_endpoints.success or push_endpoints.bytes.len == 0) return error.MissingRemote;
    hash.update(push_endpoints.bytes);
    if (request == .push) try append_remote_endpoints(&presentation, .push, push_endpoints.bytes);
    var key: [4096]u8 = undefined;
    const fetch_key = std.fmt.bufPrint(&key, "remote.{s}.fetch", .{remote}) catch return error.OutputLimitExceeded;
    const fetch = try config_values(io, git, repository, fetch_key, scratch, environment, sources);
    if (!fetch.success or fetch.bytes.len == 0) return error.MissingRemote;
    hash.update(fetch.bytes);
    const push_key = std.fmt.bufPrint(&key, "remote.{s}.push", .{remote}) catch return error.OutputLimitExceeded;
    const push = try config_values(io, git, repository, push_key, scratch, environment, sources);
    if (push.success) {
        if (push_refspecs_include_force_or_deletion(push.bytes, request == .push)) return error.ForcePushNotSupported;
        hash.update(push.bytes);
        if (request == .push) {
            if (push.bytes.len > source_scratch.len) return error.OutputLimitExceeded;
            @memcpy(source_scratch[0..push.bytes.len], push.bytes);
            try hash_push_sources(io, git, repository, source_scratch[0..push.bytes.len], scratch, environment, sources, &hash);
        }
    } else if (push.exit_code != 1) return error.GitFailed;
    var refs: Run = undefined;
    if (request == .push) {
        const refs_command = [_][]const u8{ git, "-C", repository, "--no-pager", "for-each-ref", "--format=%(refname)%00%(objectname)" };
        refs = try run(io, &refs_command, scratch, environment, sources);
    } else {
        const refs_command = [_][]const u8{ git, "-C", repository, "--no-pager", "for-each-ref", "--format=%(refname)%00%(objectname)", "refs/heads", "refs/remotes" };
        refs = try run(io, &refs_command, scratch, environment, sources);
    }
    if (!refs.success) return error.GitFailed;
    hash.update(refs.bytes);
    if (request == .push) try validate_push_target(io, git, repository, remote, scratch, environment, sources, &hash);
    var result: Fingerprint = undefined;
    hash.final(&result);
    summary.* = presentation;
    return result;
}

/// Explicit sources can name pseudorefs or reflog expressions outside the ordinary ref inventory.
/// Wildcard sources are covered by that complete inventory; Git validates their refspec syntax.
fn hash_push_sources(io: std.Io, git: []const u8, repository: []const u8, refspecs: []const u8, scratch: []u8, environment: []u8, sources: ConfigSources, hash: *std.crypto.hash.sha2.Sha256) Error!void {
    std.debug.assert(!overlaps(refspecs, scratch));
    std.debug.assert(!overlaps(refspecs, environment));
    var lines = std.mem.splitScalar(u8, refspecs, '\n');
    while (lines.next()) |line| {
        const refspec = std.mem.trimEnd(u8, line, "\r");
        if (refspec.len == 0) continue;
        const separator = std.mem.lastIndexOfScalar(u8, refspec, ':') orelse refspec.len;
        const source = refspec[0..separator];
        if (source.len == 0) return error.ForcePushNotSupported;
        if (std.mem.indexOfScalar(u8, source, '*') != null) continue;
        const command = [_][]const u8{ git, "-C", repository, "--no-pager", "rev-parse", "--verify", "--end-of-options", source };
        const resolved = try run(io, &command, scratch, environment, sources);
        if (!resolved.success) return error.MissingPushTarget;
        const oid = try capture_branch_target(std.mem.trimEnd(u8, resolved.bytes, "\r\n"));
        hash.update("resolved-push-source\x00");
        hash.update(source);
        hash.update("\x00");
        hash.update(oid.oid());
    }
}

/// Preserves fetch's legacy rejection of any `+`; push additionally rejects deletions.
fn push_refspecs_include_force_or_deletion(bytes: []const u8, reject_deletion: bool) bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const refspec = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.indexOfScalar(u8, refspec, '+') != null) return true;
        if (reject_deletion and refspec.len > 0 and refspec[0] == ':') return true;
    }
    return false;
}

/// Git normalizes accepted boolean spellings to true or false; invalid config remains an error.
fn remote_mirror_enabled(io: std.Io, git: []const u8, repository: []const u8, remote: []const u8, scratch: []u8, environment: []u8, sources: ConfigSources, hash: *std.crypto.hash.sha2.Sha256) Error!bool {
    var key: [4096]u8 = undefined;
    const mirror_key = std.fmt.bufPrint(&key, "remote.{s}.mirror", .{remote}) catch return error.OutputLimitExceeded;
    const command = [_][]const u8{ git, "-C", repository, "--no-pager", "config", "--type=bool", "--get", mirror_key };
    const mirror = try run(io, &command, scratch, environment, sources);
    hash.update("remote-mirror\x00");
    if (!mirror.success) {
        if (mirror.exit_code != 1) return error.GitFailed;
        hash.update("unset\x00");
        return false;
    }
    hash.update(mirror.bytes);
    const value = std.mem.trimEnd(u8, mirror.bytes, "\r\n");
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidGitOutput;
}

test "configured push refspec policy rejects force and deletion" {
    const cases = .{
        .{ "refs/heads/main:refs/heads/main\n", false, false },
        .{ "+refs/heads/main:refs/heads/main\n", false, true },
        .{ "refs/heads/plus+name:refs/heads/main\n", false, true },
        .{ ":refs/heads/main\n", true, true },
        .{ "refs/heads/main:refs/heads/main\n:refs/tags/v1\n", true, true },
        .{ ":refs/heads/main\n", false, false },
    };
    inline for (cases) |case| try std.testing.expectEqual(case.@"2", push_refspecs_include_force_or_deletion(case.@"0", case.@"1"));
}

fn append_remote_endpoints(summary: *RemoteSummary, role: RemoteEndpoint.Role, bytes: []const u8) Error!void {
    var staged = summary.*;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, offset, '\n') orelse bytes.len;
        const raw_line = bytes[offset..end];
        const endpoint = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') raw_line[0 .. raw_line.len - 1] else raw_line;
        if (endpoint.len == 0) return error.MissingRemote;
        offset = if (end == bytes.len) end else end + 1;
        if (staged.count == staged.endpoints.len) return error.RemoteSummaryLimitExceeded;
        var row: RemoteEndpoint = .{ .role = role };
        const label_len = try sanitize_remote_endpoint(endpoint, &row.label);
        row.label_len = @intCast(label_len);
        staged.endpoints[staged.count] = row;
        staged.count += 1;
    }
    if (staged.count == summary.count) return error.MissingRemote;
    summary.* = staged;
}

fn sanitize_remote_endpoint(endpoint: []const u8, destination: *[160]u8) Error!usize {
    for (endpoint) |byte| if (byte < 0x20 or byte == 0x7f or byte >= 0x80) return copy_label(destination, "Unsupported endpoint (redacted)");
    if (is_unc_path(endpoint)) return copy_label(destination, "Network path (authority and path hidden)");
    if (is_windows_path(endpoint) or (std.mem.startsWith(u8, endpoint, "/") and !std.mem.startsWith(u8, endpoint, "//"))) return copy_label(destination, "Local path (hidden)");
    if (endpoint.len >= 7 and std.ascii.eqlIgnoreCase(endpoint[0..7], "file://")) {
        const authority = endpoint[7..];
        const end = std.mem.indexOfAny(u8, authority, "/?#") orelse authority.len;
        const host = authority[0..end];
        if (host.len == 0 or std.ascii.eqlIgnoreCase(host, "localhost")) return copy_label(destination, "Local file endpoint (path hidden)");
        if (safe_authority(host)) return copy_label(destination, "Network file endpoint (authority and path hidden)");
        return copy_label(destination, "Unsupported endpoint (redacted)");
    }
    if (std.mem.indexOf(u8, endpoint, "://")) |separator| {
        const scheme = endpoint[0..separator];
        if (!safe_scheme(scheme)) return copy_label(destination, "Unsupported endpoint (redacted)");
        const rest = endpoint[separator + 3 ..];
        const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        const authority = rest[0..end];
        const at = std.mem.lastIndexOfScalar(u8, authority, '@');
        const host = if (at) |index| authority[index + 1 ..] else authority;
        if (!safe_authority(host)) return copy_label(destination, "Unsupported endpoint (redacted)");
        if (std.ascii.eqlIgnoreCase(scheme, "ssh") or std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https") or std.ascii.eqlIgnoreCase(scheme, "git")) return format_label(destination, "{s}://{s}", .{ scheme, host });
        return copy_label(destination, "Custom endpoint (authority and path hidden)");
    }
    return sanitize_scp_or_path(endpoint, destination);
}

fn sanitize_scp_or_path(endpoint: []const u8, destination: *[160]u8) Error!usize {
    var colon = std.mem.indexOfScalar(u8, endpoint, ':') orelse return copy_label(destination, "Local path (hidden)");
    if (colon > 0 and colon + 1 < endpoint.len and endpoint[colon + 1] == ':' and std.mem.indexOfAny(u8, endpoint[0..colon], "/\\@[") == null) return copy_label(destination, "Custom helper endpoint (details hidden)");
    if (std.mem.indexOfScalar(u8, endpoint[0..colon], '[') != null) {
        const close = std.mem.indexOfScalar(u8, endpoint, ']') orelse return copy_label(destination, "Unsupported endpoint (redacted)");
        if (close + 1 >= endpoint.len or endpoint[close + 1] != ':') return copy_label(destination, "Unsupported endpoint (redacted)");
        colon = close + 1;
    }
    const authority = endpoint[0..colon];
    if (std.mem.indexOfAny(u8, authority, "/\\") != null) return copy_label(destination, "Local path (hidden)");
    const at = std.mem.lastIndexOfScalar(u8, authority, '@');
    const host = if (at) |index| authority[index + 1 ..] else authority;
    if (!safe_authority(host)) return copy_label(destination, "Unsupported endpoint (redacted)");
    return format_label(destination, "ssh://{s}", .{host});
}

fn copy_label(destination: *[160]u8, label: []const u8) Error!usize {
    if (label.len > destination.len) return error.RemoteSummaryLimitExceeded;
    @memcpy(destination[0..label.len], label);
    return label.len;
}

fn format_label(destination: *[160]u8, comptime format: []const u8, args: anytype) Error!usize {
    const label = std.fmt.bufPrint(destination, format, args) catch return error.RemoteSummaryLimitExceeded;
    return label.len;
}

fn is_windows_path(value: []const u8) bool {
    return builtin.os.tag == .windows and value.len >= 2 and std.ascii.isAlphabetic(value[0]) and value[1] == ':';
}

fn is_unc_path(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "\\\\") or std.mem.startsWith(u8, value, "//");
}

fn safe_scheme(value: []const u8) bool {
    if (value.len == 0 or !std.ascii.isAlphabetic(value[0])) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '.' and byte != '-') return false;
    return true;
}

fn safe_host(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-' and byte != '_') return false;
    return true;
}

fn safe_authority(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value[0] == '[') {
        const close = std.mem.indexOfScalar(u8, value, ']') orelse return false;
        switch (std.Io.net.Ip6Address.Unresolved.parse(value[1..close])) {
            .success => |parsed| if (parsed.interface_name != null) return false,
            else => return false,
        }
        const suffix = value[close + 1 ..];
        return suffix.len == 0 or safe_numeric_port(suffix);
    }
    const colon = std.mem.indexOfScalar(u8, value, ':');
    const host = if (colon) |index| value[0..index] else value;
    if (!safe_host(host) or std.mem.indexOfScalar(u8, host, '[') != null or std.mem.indexOfScalar(u8, host, ']') != null) return false;
    return if (colon) |index| safe_numeric_port(value[index..]) else true;
}

fn safe_numeric_port(value: []const u8) bool {
    if (value.len < 2 or value[0] != ':') return false;
    for (value[1..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    _ = std.fmt.parseInt(u16, value[1..], 10) catch return false;
    return true;
}

test "remote presentation redacts secrets and preserves safe authority" {
    var label: [160]u8 = undefined;
    const cases = .{
        .{ "https://user:secret@example.org:8443/private?token=x#frag", "https://example.org:8443" },
        .{ "ssh://user@example.org/private", "ssh://example.org" },
        .{ "git@example.org:private/repo.git", "ssh://example.org" },
        .{ "example.org:private/repo.git", "ssh://example.org" },
        .{ "git@[2001:db8::1]:private/repo.git", "ssh://[2001:db8::1]" },
        .{ "https://[user:secret]/private", "Unsupported endpoint (redacted)" },
        .{ "https://host:99999/private", "Unsupported endpoint (redacted)" },
        .{ "https://[2001:db8::1]:443/private", "https://[2001:db8::1]:443" },
        .{ "C:\\private\\repo.git", if (builtin.os.tag == .windows) "Local path (hidden)" else "ssh://C" },
        .{ "relative/dir:private", "Local path (hidden)" },
        .{ "FILE://localhost/private", "Local file endpoint (path hidden)" },
        .{ "\\\\server\\share\\repo.git", "Network path (authority and path hidden)" },
        .{ "file:///private/repo.git", "Local file endpoint (path hidden)" },
        .{ "file://server/share/repo.git", "Network file endpoint (authority and path hidden)" },
        .{ "helper::token=secret", "Custom helper endpoint (details hidden)" },
        .{ "custom_helper::token=secret", "Custom helper endpoint (details hidden)" },
        .{ "custom://user:secret@host/path?token=x", "Custom endpoint (authority and path hidden)" },
        .{ "https://host/path\nsecret", "Unsupported endpoint (redacted)" },
        .{ "https:///bad", "Unsupported endpoint (redacted)" },
        .{ "../private/repo.git", "Local path (hidden)" },
    };
    inline for (cases) |case| {
        const length = try sanitize_remote_endpoint(case.@"0", &label);
        try std.testing.expectEqualStrings(case.@"1", label[0..length]);
        try std.testing.expect(length <= label.len);
    }
}

test "remote summary exhaustion rejects without committing partial summary" {
    var summary: RemoteSummary = .{};
    var many: [9 * 2]u8 = undefined;
    for (0..9) |index| {
        many[index * 2] = 'x';
        many[index * 2 + 1] = '\n';
    }
    try std.testing.expectError(error.RemoteSummaryLimitExceeded, append_remote_endpoints(&summary, .fetch, &many));
    try std.testing.expectEqual(@as(u8, 0), summary.count);
    try std.testing.expectError(error.MissingRemote, append_remote_endpoints(&summary, .fetch, "\nhttps://host/private\n"));
    try std.testing.expectError(error.MissingRemote, append_remote_endpoints(&summary, .fetch, "https://host/private\n\n"));
    try std.testing.expectEqual(@as(u8, 0), summary.count);
    var too_long: [168]u8 = @splat('a');
    @memcpy(too_long[0..8], "https://");
    var label: [160]u8 = undefined;
    try std.testing.expectError(error.RemoteSummaryLimitExceeded, sanitize_remote_endpoint(&too_long, &label));
}

fn config_values(io: std.Io, git: []const u8, repository: []const u8, key: []const u8, scratch: []u8, environment: []u8, sources: ConfigSources) Error!Run {
    const command = [_][]const u8{ git, "-C", repository, "--no-pager", "config", "--get-all", key };
    return run(io, &command, scratch, environment, sources);
}

fn validate_push_target(io: std.Io, git: []const u8, repository: []const u8, remote: []const u8, scratch: []u8, environment: []u8, sources: ConfigSources, hash: *std.crypto.hash.sha2.Sha256) Error!void {
    const head_command = [_][]const u8{ git, "-C", repository, "--no-pager", "symbolic-ref", "-q", "--short", "HEAD" };
    const head = try run(io, &head_command, scratch, environment, sources);
    if (!head.success or head.bytes.len == 0) return error.MissingPushTarget;
    hash.update(head.bytes);
    const policy_command = [_][]const u8{ git, "-C", repository, "--no-pager", "config", "--get", "push.default" };
    const policy = try run(io, &policy_command, scratch, environment, sources);
    if (!policy.success and policy.exit_code != 1) return error.GitFailed;
    const value = if (policy.success) std.mem.trimEnd(u8, policy.bytes, "\r\n") else "simple";
    hash.update(value);
    if (std.mem.eql(u8, value, "nothing")) return error.MissingPushTarget;
    if (!std.mem.eql(u8, value, "simple") and !std.mem.eql(u8, value, "current") and !std.mem.eql(u8, value, "upstream") and !std.mem.eql(u8, value, "matching")) return error.AmbiguousPushTarget;
    if (std.mem.eql(u8, value, "current") or std.mem.eql(u8, value, "matching")) return;
    const upstream_command = [_][]const u8{ git, "-C", repository, "--no-pager", "rev-parse", "--symbolic-full-name", "@{upstream}" };
    const upstream = try run(io, &upstream_command, scratch, environment, sources);
    if (!upstream.success or upstream.bytes.len == 0) return error.MissingPushTarget;
    hash.update(upstream.bytes);
    const branch_output = std.mem.trimEnd(u8, head.bytes, "\x00\r\n");
    var branch_storage: [1024]u8 = undefined;
    if (branch_output.len == 0 or branch_output.len > branch_storage.len) return error.MissingPushTarget;
    @memcpy(branch_storage[0..branch_output.len], branch_output);
    _ = remote;
    hash.update(branch_storage[0..branch_output.len]);
}

fn is_branch_ref(ref: []const u8, name: []const u8) bool {
    return ref.len == "refs/heads/".len + name.len and std.mem.startsWith(u8, ref, "refs/heads/") and std.mem.eql(u8, ref["refs/heads/".len..], name);
}

fn check_branch_name(io: std.Io, git: []const u8, repository: []const u8, name: []const u8, scratch: []u8, environment: []u8, sources: ConfigSources) Error!void {
    const command = [_][]const u8{ git, "-C", repository, "--no-pager", "check-ref-format", "--branch", name };
    const output = try run(io, &command, scratch, environment, sources);
    if (!output.success or !std.mem.eql(u8, std.mem.trimEnd(u8, output.bytes, "\r\n"), name)) return error.InvalidBranchName;
}

/// Includes Git's effective attributes plus every local attribute source that can affect `path`.
/// All sources are regular files and bounded by caller scratch; unknown source types reject mutation.
fn attributes_fingerprint(io: std.Io, git: []const u8, repository: []const u8, git_dir: []const u8, worktree: []const u8, request: Request, path_scratch: []u8, environment: []u8, file_scratch: []u8, sources: ConfigSources) Error!Fingerprint {
    const path = switch (request) {
        .worktree_status => return status_attributes_fingerprint(io, git, repository, git_dir, worktree, path_scratch, environment, file_scratch, sources),
        .stage => |value| value.path,
        .unstage => |value| value.path,
        .commit => return trust.fingerprint("commit attributes: no target\x00"),
        .branch_create, .branch_rename, .branch_delete, .fetch, .push => return trust.fingerprint("non-file operation: no attributes\x00"),
    };
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const command = [_][]const u8{ git, "-C", repository, "--no-pager", "check-attr", "-z", "--all", "--", path };
    const output = try run(io, &command, path_scratch, environment, sources);
    if (!output.success) return error.GitFailed;
    hash.update("effective\x00");
    hash.update(output.bytes);
    try hash_attribute_file(io, &hash, worktree, ".gitattributes", path_scratch, file_scratch);
    var prefix_len: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, prefix_len, '/')) |separator| {
        const attribute_path = std.fmt.bufPrint(path_scratch, "{s}/{s}/.gitattributes", .{ worktree, path[0..separator] }) catch return error.OutputLimitExceeded;
        hash.update(attribute_path);
        try hash_absolute_file(io, &hash, attribute_path, file_scratch);
        prefix_len = separator + 1;
    }
    try hash_attribute_file(io, &hash, git_dir, "info/attributes", path_scratch, file_scratch);
    const external_command = [_][]const u8{ git, "-C", repository, "--no-pager", "config", "--path", "--get", "core.attributesFile" };
    const external = try run(io, &external_command, path_scratch, environment, sources);
    if (!external.success and external.exit_code != 1) return error.GitFailed;
    hash.update("external\x00");
    if (external.success) {
        const external_path = std.mem.trimEnd(u8, external.bytes, "\r\n");
        if (!std.fs.path.isAbsolute(external_path)) return error.UnsupportedConfigContext;
        try hash_absolute_file(io, &hash, external_path, file_scratch);
    } else hash.update("absent");
    var result: Fingerprint = undefined;
    hash.final(&result);
    return result;
}

fn status_attributes_fingerprint(io: std.Io, git: []const u8, repository: []const u8, git_dir: []const u8, worktree: []const u8, path_scratch: []u8, environment: []u8, file_scratch: []u8, sources: ConfigSources) Error!Fingerprint {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("worktree status attributes\x00");
    try hash_attribute_file(io, &hash, worktree, ".gitattributes", path_scratch, file_scratch);
    try hash_attribute_file(io, &hash, git_dir, "info/attributes", path_scratch, file_scratch);
    const command = [_][]const u8{ git, "-C", repository, "--no-pager", "config", "--path", "--get", "core.attributesFile" };
    const external = try run(io, &command, path_scratch, environment, sources);
    if (!external.success and external.exit_code != 1) return error.GitFailed;
    if (external.success) {
        const path = std.mem.trimEnd(u8, external.bytes, "\r\n");
        if (!std.fs.path.isAbsolute(path)) return error.UnsupportedConfigContext;
        try hash_absolute_file(io, &hash, path, file_scratch);
    } else hash.update("absent");
    var result: Fingerprint = undefined;
    hash.final(&result);
    return result;
}

fn hash_attribute_file(io: std.Io, hash: *std.crypto.hash.sha2.Sha256, parent: []const u8, leaf: []const u8, path_scratch: []u8, file_scratch: []u8) Error!void {
    const path = try join_path(parent, leaf, path_scratch);
    hash.update(path);
    try hash_absolute_file(io, hash, path, file_scratch);
}

fn hash_absolute_file(io: std.Io, hash: *std.crypto.hash.sha2.Sha256, path: []const u8, file_scratch: []u8) Error!void {
    const loaded = files.load(io, path, file_scratch) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            hash.update("absent\x00");
            return;
        },
        else => return error.EvidenceReadFailed,
    };
    hash.update("file\x00");
    hash.update(&loaded.digest);
}

/// Commit hooks are executable configuration. Every direct regular file in the resolved hook directory is bound.
fn hooks_fingerprint(io: std.Io, git: []const u8, repository: []const u8, request: Request, path_scratch: []u8, environment: []u8, file_scratch: []u8, sources: ConfigSources) Error!Fingerprint {
    if (std.meta.activeTag(request) != .commit) return trust.fingerprint("no commit hooks\x00");
    const command = [_][]const u8{ git, "-C", repository, "--no-pager", "rev-parse", "--path-format=absolute", "--git-path", "hooks" };
    const output = try run(io, &command, path_scratch, environment, sources);
    if (!output.success) return error.GitFailed;
    const hook_dir_output = std.mem.trimEnd(u8, output.bytes, "\r\n");
    if (!std.fs.path.isAbsolute(hook_dir_output) or hook_dir_output.len > std.Io.Dir.max_path_bytes) return error.InvalidGitOutput;
    var hook_dir_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    @memcpy(hook_dir_storage[0..hook_dir_output.len], hook_dir_output);
    const hook_dir = hook_dir_storage[0..hook_dir_output.len];
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(hook_dir);
    var directory = std.Io.Dir.cwd().openDir(io, hook_dir, .{ .access_sub_paths = true, .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            hash.update("absent\x00");
            var absent: Fingerprint = undefined;
            hash.final(&absent);
            return absent;
        },
        else => return error.EvidenceReadFailed,
    };
    defer directory.close(io);
    var iterator = directory.iterate();
    var count: usize = 0;
    var aggregate: Fingerprint = @splat(0);
    while (iterator.next(io) catch return error.EvidenceReadFailed) |entry| {
        count += 1;
        if (count > 64) return error.UnsupportedHookDirectory;
        if (entry.kind != .file) return error.UnsupportedHookDirectory;
        const path = try join_path(hook_dir, entry.name, path_scratch);
        const loaded = files.load(io, path, file_scratch) catch return error.EvidenceReadFailed;
        var item_hash = std.crypto.hash.sha2.Sha256.init(.{});
        item_hash.update(entry.name);
        item_hash.update(&loaded.digest);
        var item: Fingerprint = undefined;
        item_hash.final(&item);
        for (&aggregate, item) |*sum, value| sum.* ^= value;
    }
    hash.update(std.mem.asBytes(&count));
    hash.update(&aggregate);
    var result: Fingerprint = undefined;
    hash.final(&result);
    return result;
}

fn canonicalize(io: std.Io, absolute_path: []const u8, destination: []u8) Error![]const u8 {
    if (destination.len == 0) return error.OutputLimitExceeded;
    const length = std.Io.Dir.realPathFileAbsolute(io, absolute_path, destination) catch return error.EvidenceReadFailed;
    if (length == 0 or length > destination.len) return error.InvalidPath;
    return destination[0..length];
}

fn join_path(parent: []const u8, leaf: []const u8, destination: []u8) Error![]const u8 {
    const separator: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    const needs_separator = parent.len != 0 and parent[parent.len - 1] != '/' and parent[parent.len - 1] != '\\';
    const length = parent.len + leaf.len + @intFromBool(needs_separator);
    if (length > destination.len) return error.OutputLimitExceeded;
    @memcpy(destination[0..parent.len], parent);
    var cursor = parent.len;
    if (needs_separator) {
        destination[cursor] = separator;
        cursor += 1;
    }
    @memcpy(destination[cursor..][0..leaf.len], leaf);
    return destination[0..length];
}

const Run = struct { bytes: []const u8, success: bool, exit_code: ?u8 };
fn run(io: std.Io, command: []const []const u8, workspace: []u8, environment_workspace: []u8, sources: ConfigSources) Error!Run {
    if (command.len == 0 or command.len >= 64) return error.OutputLimitExceeded;
    var guarded_command: [64][]const u8 = undefined;
    guarded_command[0] = command[0];
    guarded_command[1] = "--no-lazy-fetch";
    @memcpy(guarded_command[2..][0 .. command.len - 1], command[1..]);
    var environment_allocator = std.heap.FixedBufferAllocator.init(environment_workspace);
    var environment = try inherited_environment(environment_allocator.allocator());
    var allocator = std.heap.FixedBufferAllocator.init(workspace);
    defer environment.deinit();
    sanitize_git_environment(&environment);
    try apply_config_sources(&environment, sources);
    const started = if (builtin.is_test) std.Io.Clock.awake.now(io) else undefined;
    const output = git_process.run(allocator.allocator(), io, .{ .argv = guarded_command[0 .. command.len + 1], .environ_map = &environment, .cwd = .inherit, .stdout_limit = .limited(workspace.len / 2), .stderr_limit = .limited(workspace.len / 2), .reserve_amount = 64, .timeout = .{ .duration = .{ .raw = .fromMilliseconds(10_000), .clock = .awake } } }) catch |err| {
        if (builtin.is_test) log_subprocess_failure(io, "preflight", guarded_command[0 .. command.len + 1], started, err);
        return switch (err) {
            error.StreamTooLong, error.OutOfMemory => error.OutputLimitExceeded,
            error.Timeout => error.ChildTimeout,
            else => |unexpected| unexpected,
        };
    };
    return .{ .bytes = output.stdout, .success = output.term.success(), .exit_code = switch (output.term) {
        .exited => |code| code,
        else => null,
    } };
}

fn log_subprocess_failure(io: std.Io, phase: []const u8, command: []const []const u8, started: std.Io.Timestamp, err: anyerror) void {
    const elapsed = started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
    std.debug.print("record subprocess phase={s} command={s} error={s} elapsed_ms={d}\n", .{ phase, command_label(command), @errorName(err), @divTrunc(elapsed, 1_000_000) });
}

fn command_label(command: []const []const u8) []const u8 {
    for (command) |argument| {
        if (std.mem.eql(u8, argument, "config")) return "config";
        if (std.mem.eql(u8, argument, "rev-parse")) return "rev-parse";
        if (std.mem.eql(u8, argument, "check-attr")) return "check-attr";
        if (std.mem.eql(u8, argument, "add")) return "add";
    }
    return "other";
}

fn inherited_environment(allocator: std.mem.Allocator) Error!std.process.Environ.Map {
    if (comptime builtin.os.tag == .windows) return std.process.Environ.createMap(.{ .block = .global }, allocator) catch return error.OutputLimitExceeded;
    return error.UnsupportedMutationPlatform;
}

fn apply_config_sources(environment: *std.process.Environ.Map, sources: ConfigSources) std.mem.Allocator.Error!void {
    if (sources.global) |path| try environment.put("GIT_CONFIG_GLOBAL", path);
    if (sources.system) |path| try environment.put("GIT_CONFIG_SYSTEM", path);
    if (sources.no_system) |disabled| try environment.put("GIT_CONFIG_NOSYSTEM", if (disabled) "1" else "0");
}

/// Remove only repository-routing and config-injection overrides.
/// Credential, SSH, askpass, and signing executable settings remain effective and fingerprinted.
fn sanitize_git_environment(environment: *std.process.Environ.Map) void {
    var index: usize = 0;
    while (index < environment.keys().len) {
        const key = environment.keys()[index];
        if (git_routing_override(key)) {
            _ = environment.swapRemove(key);
            continue;
        }
        index += 1;
    }
}

fn git_routing_override(key: []const u8) bool {
    return environment_key_equal(key, "GIT_DIR") or environment_key_equal(key, "GIT_WORK_TREE") or environment_key_equal(key, "GIT_COMMON_DIR") or environment_key_equal(key, "GIT_INDEX_FILE") or environment_key_equal(key, "GIT_OBJECT_DIRECTORY") or environment_key_equal(key, "GIT_ALTERNATE_OBJECT_DIRECTORIES") or environment_key_equal(key, "GIT_CEILING_DIRECTORIES") or environment_key_equal(key, "GIT_DISCOVERY_ACROSS_FILESYSTEM") or environment_key_equal(key, "GIT_CONFIG_COUNT") or environment_key_starts_with(key, "GIT_CONFIG_KEY_") or environment_key_starts_with(key, "GIT_CONFIG_VALUE_");
}

fn execution_environment_fingerprint(workspace: []u8, sources: ConfigSources) Error!Fingerprint {
    var allocator = std.heap.FixedBufferAllocator.init(workspace);
    var environment = try inherited_environment(allocator.allocator());
    defer environment.deinit();
    sanitize_git_environment(&environment);
    apply_config_sources(&environment, sources) catch return error.OutputLimitExceeded;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const keys = [_][]const u8{ "GIT_SSH", "GIT_SSH_COMMAND", "GIT_ASKPASS", "SSH_ASKPASS", "GIT_TERMINAL_PROMPT", "GIT_GPG", "GPG_TTY", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM" };
    for (keys) |key| {
        hash.update(key);
        hash.update("\x00");
        hash.update(environment.get(key) orelse "absent");
        hash.update("\x00");
    }
    var result: Fingerprint = undefined;
    hash.final(&result);
    return result;
}

fn environment_key_equal(left: []const u8, right: []const u8) bool {
    return if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(left, right) else std.mem.eql(u8, left, right);
}

fn environment_key_starts_with(key: []const u8, prefix: []const u8) bool {
    if (builtin.os.tag != .windows) return std.mem.startsWith(u8, key, prefix);
    return key.len >= prefix.len and std.ascii.eqlIgnoreCase(key[0..prefix.len], prefix);
}

fn request_fingerprint(request: Request) Fingerprint {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    switch (request) {
        .worktree_status => hash.update("worktree-status\x00"),
        .stage => |value| {
            hash.update("stage\x00");
            hash.update(value.path);
        },
        .unstage => |value| {
            hash.update("unstage\x00");
            hash.update(value.path);
        },
        .commit => |value| {
            hash.update("commit\x00");
            hash.update(value.message);
        },
        .branch_create => |value| {
            hash.update("branch-create\x00");
            hash.update(value.name);
            hash.update("\x00");
            hash.update(value.start_point);
        },
        .branch_rename => |value| {
            hash.update("branch-rename\x00");
            hash.update(value.old);
            hash.update("\x00");
            hash.update(value.new);
        },
        .branch_delete => |value| {
            hash.update("branch-delete\x00");
            hash.update(value.target);
        },
        .fetch => |value| {
            hash.update("fetch\x00");
            hash.update(value.remote);
        },
        .push => |value| {
            hash.update("push\x00");
            hash.update(value.remote);
        },
    }
    var result: Fingerprint = undefined;
    hash.final(&result);
    return result;
}

fn validate_buffers(buffers: Buffers) Error!void {
    const regions = [_][]u8{ buffers.command, buffers.environment, buffers.file, buffers.canonical_executable, buffers.canonical_repository, buffers.canonical_git, buffers.canonical_worktree, buffers.canonical_common_dir };
    for (regions, 0..) |left, index| {
        if (left.len == 0) return error.OutputLimitExceeded;
        for (regions[index + 1 ..]) |right| if (overlaps(left, right)) return error.AliasedBuffers;
    }
}

fn validate_status_buffers(buffers: Buffers, workspace: []u8, status_output: []u8, stdout_limit: usize, stderr_limit: usize) Error!void {
    try validate_buffers(buffers);
    if (workspace.len == 0 or stdout_limit == 0 or stderr_limit == 0 or status_output.len < stdout_limit) return error.OutputLimitExceeded;
    if (overlaps(workspace, status_output)) return error.AliasedBuffers;
    const regions = [_][]const u8{ buffers.command, buffers.environment, buffers.file, buffers.canonical_executable, buffers.canonical_repository, buffers.canonical_git, buffers.canonical_worktree, buffers.canonical_common_dir };
    for (regions) |region| if (overlaps(status_output, region)) return error.AliasedBuffers;
    // Command/file scratch may be recycled after collection; environment and argv identities remain live.
    for (regions[1..], 1..) |region, index| {
        if (index == 2) continue;
        if (overlaps(workspace, region)) return error.AliasedBuffers;
    }
}

fn overlaps(left: []const u8, right: []const u8) bool {
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    return left_start < right_start + right.len and right_start < left_start + left.len;
}

fn validate_location(git_exe: []const u8, repository_path: []const u8) Error!void {
    if (git_exe.len == 0) return error.EmptyGitExecutable;
    if (repository_path.len == 0) return error.EmptyRepositoryPath;
    if (std.mem.indexOfScalar(u8, git_exe, 0) != null or std.mem.indexOfScalar(u8, repository_path, 0) != null) return error.NulByte;
    if (!std.fs.path.isAbsolute(git_exe)) return error.GitExecutableNotAbsolute;
    if (!std.fs.path.isAbsolute(repository_path)) return error.RepositoryPathNotAbsolute;
}
fn validate_request(request: Request) Error!void {
    switch (request) {
        .worktree_status => {},
        .stage => |value| try validate_path(value.path),
        .unstage => |value| try validate_path(value.path),
        .commit => |value| try validate_message(value.message),
        .branch_create => |value| {
            try validate_branch_name(value.name);
            try validate_start_point(value.start_point);
        },
        .branch_rename => |value| {
            try validate_branch_name(value.old);
            try validate_branch_name(value.new);
        },
        .branch_delete => |value| try validate_branch_name(value.target),
        .fetch => |value| try validate_remote_name(value.remote),
        .push => |value| try validate_remote_name(value.remote),
    }
}
fn validate_remote_name(name: []const u8) Error!void {
    if (name.len == 0 or name[0] == '-') return error.MissingRemote;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.NulByte;
    for (name) |byte| if (byte < 0x20 or byte == 0x7f) return error.MissingRemote;
}
fn validate_start_point(value: []const u8) Error!void {
    if (value.len == 0 or value[0] == '-') return error.InvalidStartPoint;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.NulByte;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidStartPoint;
}
fn validate_branch_name(name: []const u8) Error!void {
    if (name.len == 0 or name[0] == '-') return error.InvalidBranchName;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.NulByte;
    for (name) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidBranchName;
}
fn validate_path(path: []const u8) Error!void {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.NulByte;
    if (paths.preflight_repository_relative(path, .windows) != .lexically_valid) return error.InvalidPath;
}
fn validate_message(message: []const u8) Error!void {
    if (message.len == 0) return error.InvalidMessage;
    if (std.mem.indexOfScalar(u8, message, 0) != null) return error.NulByte;
}
fn same(left: Fingerprint, right: Fingerprint) bool {
    return std.mem.eql(u8, &left, &right);
}

test "whole-file argv has literal pathspec mode and separator" {
    const git_exe = if (builtin.os.tag == .windows) "C:/Git/bin/git.exe" else "/git/bin/git";
    const repository = if (builtin.os.tag == .windows) "C:/fixture" else "/fixture";
    var storage: [9][]const u8 = undefined;
    const command = try argv(.{ .stage = .{ .path = "dir/file.txt" } }, git_exe, repository, &storage);
    try std.testing.expectEqualStrings("--literal-pathspecs", command[1]);
    try std.testing.expectEqualStrings("--", command[6]);
}
test "non-Windows inherited environment is unsupported" {
    if (comptime builtin.os.tag == .windows) return;
    try std.testing.expectError(error.UnsupportedMutationPlatform, inherited_environment(std.testing.allocator));
}

test "branch requests reject option-like and control-byte names" {
    try std.testing.expectError(error.InvalidBranchName, validate_request(.{ .branch_delete = .{ .target = "--help" } }));
    try std.testing.expectError(error.InvalidBranchName, validate_request(.{ .branch_create = .{ .name = "bad\nname", .start_point = "HEAD" } }));
    try std.testing.expectError(error.InvalidStartPoint, validate_request(.{ .branch_create = .{ .name = "valid", .start_point = "-option" } }));
    try std.testing.expectError(error.NulByte, validate_request(.{ .branch_rename = .{ .old = "valid", .new = "bad\x00name" } }));
}

test "request identity rejects same operation with changed target" {
    const value = trust.fingerprint("same");
    const initial = Preflight{ .repository = value, .worktree = value, .common_dir = value, .head = value, .index = value, .operation_state = value, .executable_config = value, .executable = value, .request = request_fingerprint(.{ .stage = .{ .path = "one" } }), .target = value, .attributes = value, .hooks = value, .operation = .stage };
    var changed = initial;
    changed.request = request_fingerprint(.{ .stage = .{ .path = "two" } });
    var token = Token.init(initial);
    try std.testing.expectError(error.StalePreflight, token.verify(changed));
    try token.consume();
    try std.testing.expectError(error.TokenExpired, token.verify(initial));
}
test "collector buffers reject aliases before Git execution" {
    var storage: [16]u8 = undefined;
    var separate: [16]u8 = undefined;
    const buffers = Buffers{ .command = &storage, .environment = &separate, .file = &storage, .canonical_executable = &separate, .canonical_repository = &separate, .canonical_git = &separate, .canonical_worktree = &separate, .canonical_common_dir = &separate };
    try std.testing.expectError(error.AliasedBuffers, validate_buffers(buffers));
}

test "request identity distinguishes commit messages" {
    const left = request_fingerprint(.{ .commit = .{ .message = "x" } });
    const right = request_fingerprint(.{ .commit = .{ .message = "y" } });
    try std.testing.expect(!std.mem.eql(u8, &left, &right));
}

test "installed Git branch mutations create rename safe-delete and reject stale or unmerged refs" {
    if (comptime builtin.os.tag != .windows) return;
    if (!test_git_enabled()) return;
    const git = try test_git_executable();
    defer std.testing.allocator.free(git);
    const io = std.testing.io;
    var fixture_memory: ["C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e".len + 1 + 16]u8 = undefined;
    const fixture = try test_fixture(io, &fixture_memory);
    defer std.Io.Dir.cwd().deleteTree(io, fixture) catch {};
    try test_git(io, git, fixture, &.{ "init", "--initial-branch=main" });
    try test_git(io, git, fixture, &.{ "config", "user.email", "fixture@example.invalid" });
    try test_git(io, git, fixture, &.{ "config", "user.name", "Fixture" });
    try test_write(io, fixture, "base.txt", "base\n");
    try test_git(io, git, fixture, &.{ "add", "--", "base.txt" });
    try test_git(io, git, fixture, &.{ "commit", "-m", "base" });

    var create_buffers = try TestBuffers.init(io, fixture);
    defer create_buffers.deinit();
    const create_request: Request = .{ .branch_create = .{ .name = "created", .start_point = "HEAD" } };
    const created = try collect(io, git, fixture, create_request, create_buffers.value());
    var create_grants: [1]trust.Grant = undefined;
    var create_store = trust.Store.init(&create_grants);
    try create_store.grant(.{ .repository = created.preflight.repository, .config = created.preflight.executable_config, .scope = .branch_create });
    var create_token = Token.init(created.preflight);
    try std.testing.expect((try execute_revalidated(io, &create_store, &create_token, created, create_request, create_buffers.value(), create_buffers.workspace, 4096, 4096, test_timeout())).succeeded);
    try test_git(io, git, fixture, &.{ "show-ref", "--verify", "refs/heads/created" });

    var rename_buffers = try TestBuffers.init(io, fixture);
    defer rename_buffers.deinit();
    const rename_request: Request = .{ .branch_rename = .{ .old = "created", .new = "renamed" } };
    const renamed = try collect(io, git, fixture, rename_request, rename_buffers.value());
    var rename_grants: [1]trust.Grant = undefined;
    var rename_store = trust.Store.init(&rename_grants);
    try rename_store.grant(.{ .repository = renamed.preflight.repository, .config = renamed.preflight.executable_config, .scope = .branch_rename });
    var rename_token = Token.init(renamed.preflight);
    try std.testing.expect((try execute_revalidated(io, &rename_store, &rename_token, renamed, rename_request, rename_buffers.value(), rename_buffers.workspace, 4096, 4096, test_timeout())).succeeded);
    try test_git(io, git, fixture, &.{ "show-ref", "--verify", "refs/heads/renamed" });

    var delete_buffers = try TestBuffers.init(io, fixture);
    defer delete_buffers.deinit();
    const delete_request: Request = .{ .branch_delete = .{ .target = "renamed" } };
    const deleted = try collect(io, git, fixture, delete_request, delete_buffers.value());
    var delete_grants: [1]trust.Grant = undefined;
    var delete_store = trust.Store.init(&delete_grants);
    try delete_store.grant(.{ .repository = deleted.preflight.repository, .config = deleted.preflight.executable_config, .scope = .branch_delete });
    var delete_token = Token.init(deleted.preflight);
    try std.testing.expect((try execute_revalidated(io, &delete_store, &delete_token, deleted, delete_request, delete_buffers.value(), delete_buffers.workspace, 4096, 4096, test_timeout())).succeeded);
    try test_git_expect_failure(io, git, fixture, &.{ "show-ref", "--verify", "refs/heads/renamed" });

    try test_git(io, git, fixture, &.{ "branch", "unmerged" });
    try test_git(io, git, fixture, &.{ "checkout", "unmerged" });
    try test_write(io, fixture, "unmerged.txt", "unmerged\n");
    try test_git(io, git, fixture, &.{ "add", "--", "unmerged.txt" });
    try test_git(io, git, fixture, &.{ "commit", "-m", "unmerged" });
    try test_git(io, git, fixture, &.{ "checkout", "main" });
    var refusal_buffers = try TestBuffers.init(io, fixture);
    defer refusal_buffers.deinit();
    const refusal_request: Request = .{ .branch_delete = .{ .target = "unmerged" } };
    const refusal = try collect(io, git, fixture, refusal_request, refusal_buffers.value());
    var refusal_grants: [1]trust.Grant = undefined;
    var refusal_store = trust.Store.init(&refusal_grants);
    try refusal_store.grant(.{ .repository = refusal.preflight.repository, .config = refusal.preflight.executable_config, .scope = .branch_delete });
    var refusal_token = Token.init(refusal.preflight);
    const rejected = try execute_revalidated(io, &refusal_store, &refusal_token, refusal, refusal_request, refusal_buffers.value(), refusal_buffers.workspace, 4096, 4096, test_timeout());
    try std.testing.expect(!rejected.succeeded);

    try test_git(io, git, fixture, &.{ "branch", "stale" });
    var stale_buffers = try TestBuffers.init(io, fixture);
    defer stale_buffers.deinit();
    const stale_request: Request = .{ .branch_delete = .{ .target = "stale" } };
    const stale = try collect(io, git, fixture, stale_request, stale_buffers.value());
    var stale_grants: [1]trust.Grant = undefined;
    var stale_store = trust.Store.init(&stale_grants);
    try stale_store.grant(.{ .repository = stale.preflight.repository, .config = stale.preflight.executable_config, .scope = .branch_delete });
    var stale_token = Token.init(stale.preflight);
    try test_git(io, git, fixture, &.{ "commit", "--allow-empty", "-m", "advance" });
    try test_git(io, git, fixture, &.{ "update-ref", "refs/heads/stale", "HEAD^" });
    try std.testing.expectError(error.StalePreflight, execute_revalidated(io, &stale_store, &stale_token, stale, stale_request, stale_buffers.value(), stale_buffers.workspace, 4096, 4096, test_timeout()));
}

test "installed Git branch creation rejects moved tags and remote-tracking refs" {
    if (comptime builtin.os.tag != .windows) return;
    if (!test_git_enabled()) return;
    const git = try test_git_executable();
    defer std.testing.allocator.free(git);
    const io = std.testing.io;
    var fixture_memory: ["C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e".len + 1 + 16]u8 = undefined;
    const fixture = try test_fixture(io, &fixture_memory);
    defer std.Io.Dir.cwd().deleteTree(io, fixture) catch {};
    try test_git(io, git, fixture, &.{ "init", "--initial-branch=main" });
    try test_git(io, git, fixture, &.{ "config", "user.email", "fixture@example.invalid" });
    try test_git(io, git, fixture, &.{ "config", "user.name", "Fixture" });
    try test_write(io, fixture, "base.txt", "base\n");
    try test_git(io, git, fixture, &.{ "add", "--", "base.txt" });
    try test_git(io, git, fixture, &.{ "commit", "-m", "base" });
    try test_write(io, fixture, "next.txt", "next\n");
    try test_git(io, git, fixture, &.{ "add", "--", "next.txt" });
    try test_git(io, git, fixture, &.{ "commit", "-m", "next" });
    try test_git(io, git, fixture, &.{ "tag", "moving-tag", "HEAD^" });
    try test_git(io, git, fixture, &.{ "update-ref", "refs/remotes/origin/moving", "HEAD^" });
    inline for (.{ .{ "moving-tag", "from-tag", "refs/tags/moving-tag" }, .{ "origin/moving", "from-remote", "refs/remotes/origin/moving" } }) |case| {
        var buffers = try TestBuffers.init(io, fixture);
        defer buffers.deinit();
        const request: Request = .{ .branch_create = .{ .name = case.@"1", .start_point = case.@"0" } };
        const reviewed = try collect(io, git, fixture, request, buffers.value());
        try std.testing.expect(reviewed.branch_target != null);
        var grants: [1]trust.Grant = undefined;
        var store = trust.Store.init(&grants);
        try store.grant(.{ .repository = reviewed.preflight.repository, .config = reviewed.preflight.executable_config, .scope = .branch_create });
        var token = Token.init(reviewed.preflight);
        try test_git(io, git, fixture, &.{ "update-ref", case.@"2", "HEAD" });
        try std.testing.expectError(error.StalePreflight, execute_revalidated(io, &store, &token, reviewed, request, buffers.value(), buffers.workspace, 4096, 4096, test_timeout()));
        try test_git_expect_failure(io, git, fixture, &.{ "show-ref", "--verify", std.fmt.comptimePrint("refs/heads/{s}", .{case.@"1"}) });
        const renewed = try collect(io, git, fixture, request, buffers.value());
        try std.testing.expect(!std.mem.eql(u8, reviewed.branch_target.?.oid(), renewed.branch_target.?.oid()));
        var renewed_grants: [1]trust.Grant = undefined;
        var renewed_store = trust.Store.init(&renewed_grants);
        try renewed_store.grant(.{ .repository = renewed.preflight.repository, .config = renewed.preflight.executable_config, .scope = .branch_create });
        var renewed_token = Token.init(renewed.preflight);
        try std.testing.expect((try execute_revalidated(io, &renewed_store, &renewed_token, renewed, request, buffers.value(), buffers.workspace, 4096, 4096, test_timeout())).succeeded);
        try test_expect_output(io, git, fixture, &.{ "rev-parse", std.fmt.comptimePrint("refs/heads/{s}", .{case.@"1"}) }, renewed.branch_target.?.oid());
    }
}

test "configured nonorigin remote fetches and pushes only after scoped review" {
    if (comptime builtin.os.tag != .windows) return;
    if (!test_git_enabled()) return;
    const git = try test_git_executable();
    defer std.testing.allocator.free(git);
    const io = std.testing.io;
    var fixture_memory: ["C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e".len + 1 + 16]u8 = undefined;
    const fixture = try test_fixture(io, &fixture_memory);
    defer std.Io.Dir.cwd().deleteTree(io, fixture) catch {};
    try test_git(io, git, fixture, &.{ "init", "--initial-branch=main" });
    try test_git(io, git, fixture, &.{ "config", "user.email", "fixture@example.invalid" });
    try test_git(io, git, fixture, &.{ "config", "user.name", "Fixture" });
    try test_write(io, fixture, "base.txt", "base\n");
    try test_git(io, git, fixture, &.{ "add", "--", "base.txt" });
    try test_git(io, git, fixture, &.{ "commit", "-m", "base" });
    try test_git(io, git, fixture, &.{ "init", "--bare", "remote.git" });
    var remote_path: [512]u8 = undefined;
    const remote = try std.fmt.bufPrint(&remote_path, "{s}/remote.git", .{fixture});
    try test_git(io, git, fixture, &.{ "remote", "add", "satellite", remote });
    try test_git(io, git, fixture, &.{ "push", "-u", "satellite", "main" });
    try test_git(io, git, fixture, &.{ "config", "branch.main.remote", "satellite" });
    try test_git(io, git, fixture, &.{ "config", "branch.main.merge", "refs/heads/main" });
    try test_git(io, git, fixture, &.{ "config", "push.default", "simple" });
    try test_git(io, git, fixture, &.{ "clone", "--branch", "main", "remote.git", "peer" });
    var peer_path: [512]u8 = undefined;
    const peer = try std.fmt.bufPrint(&peer_path, "{s}/peer", .{fixture});
    try test_git(io, git, peer, &.{ "config", "user.email", "peer@example.invalid" });
    try test_git(io, git, peer, &.{ "config", "user.name", "Peer" });
    try test_write(io, peer, "peer.txt", "peer\n");
    try test_git(io, git, peer, &.{ "add", "--", "peer.txt" });
    try test_git(io, git, peer, &.{ "commit", "-m", "peer" });
    try test_git(io, git, peer, &.{"push"});

    var buffers = try TestBuffers.init(io, fixture);
    defer buffers.deinit();
    const fetch_request: Request = .{ .fetch = .{ .remote = "satellite" } };
    const fetched = try collect(io, git, fixture, fetch_request, buffers.value());
    var fetch_grants: [1]trust.Grant = undefined;
    var fetch_store = trust.Store.init(&fetch_grants);
    try fetch_store.grant(.{ .repository = fetched.preflight.repository, .config = fetched.preflight.executable_config, .scope = .fetch });
    var fetch_token = Token.init(fetched.preflight);
    try std.testing.expect((try execute_revalidated(io, &fetch_store, &fetch_token, fetched, fetch_request, buffers.value(), buffers.workspace, 4096, 4096, test_timeout())).succeeded);
    try test_git(io, git, fixture, &.{ "show-ref", "--verify", "refs/remotes/satellite/main" });
    try test_git(io, git, fixture, &.{ "merge", "--ff-only", "satellite/main" });
    try test_write(io, fixture, "local.txt", "local\n");
    try test_git(io, git, fixture, &.{ "add", "--", "local.txt" });
    try test_git(io, git, fixture, &.{ "commit", "-m", "local" });

    const push_request: Request = .{ .push = .{ .remote = "satellite" } };
    const pushed = try collect(io, git, fixture, push_request, buffers.value());
    var push_grants: [1]trust.Grant = undefined;
    var push_store = trust.Store.init(&push_grants);
    try push_store.grant(.{ .repository = pushed.preflight.repository, .config = pushed.preflight.executable_config, .scope = .push });
    var push_token = Token.init(pushed.preflight);
    try std.testing.expect((try execute_revalidated(io, &push_store, &push_token, pushed, push_request, buffers.value(), buffers.workspace, 4096, 4096, test_timeout())).succeeded);
    try test_git(io, git, peer, &.{ "pull", "--ff-only" });
    try test_write(io, peer, "peer-divergent.txt", "peer divergent\n");
    try test_git(io, git, peer, &.{ "add", "--", "peer-divergent.txt" });
    try test_git(io, git, peer, &.{ "commit", "-m", "peer divergent" });
    try test_git(io, git, peer, &.{"push"});
    try test_write(io, fixture, "local-divergent.txt", "local divergent\n");
    try test_git(io, git, fixture, &.{ "add", "--", "local-divergent.txt" });
    try test_git(io, git, fixture, &.{ "commit", "-m", "local divergent" });
    const remote_before = try test_git_output(io, git, remote, &.{ "rev-parse", "HEAD" });
    defer std.testing.allocator.free(remote_before.stdout);
    defer std.testing.allocator.free(remote_before.stderr);
    const rejected = try collect(io, git, fixture, push_request, buffers.value());
    var rejected_grants: [1]trust.Grant = undefined;
    var rejected_store = trust.Store.init(&rejected_grants);
    try rejected_store.grant(.{ .repository = rejected.preflight.repository, .config = rejected.preflight.executable_config, .scope = .push });
    var rejected_token = Token.init(rejected.preflight);
    try std.testing.expect(!(try execute_revalidated(io, &rejected_store, &rejected_token, rejected, push_request, buffers.value(), buffers.workspace, 4096, 4096, test_timeout())).succeeded);
    const remote_after = try test_git_output(io, git, remote, &.{ "rev-parse", "HEAD" });
    defer std.testing.allocator.free(remote_after.stdout);
    defer std.testing.allocator.free(remote_after.stderr);
    try std.testing.expectEqualStrings(remote_before.stdout, remote_after.stdout);

    const stale = try collect(io, git, fixture, fetch_request, buffers.value());
    try test_git(io, git, fixture, &.{ "remote", "set-url", "satellite", "changed.git" });
    var stale_grants: [1]trust.Grant = undefined;
    var stale_store = trust.Store.init(&stale_grants);
    try stale_store.grant(.{ .repository = stale.preflight.repository, .config = stale.preflight.executable_config, .scope = .fetch });
    var stale_token = Token.init(stale.preflight);
    try std.testing.expectError(error.StalePreflight, execute_revalidated(io, &stale_store, &stale_token, stale, fetch_request, buffers.value(), buffers.workspace, 4096, 4096, test_timeout()));
}

test "installed Git push rejects moved refs pseudorefs and reflog sources" {
    if (comptime builtin.os.tag != .windows) return;
    if (!test_git_enabled()) return;
    const git = try test_git_executable();
    defer std.testing.allocator.free(git);
    const io = std.testing.io;
    var fixture_memory: ["C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e".len + 1 + 16]u8 = undefined;
    const fixture = try test_fixture(io, &fixture_memory);
    defer std.Io.Dir.cwd().deleteTree(io, fixture) catch {};
    try test_git(io, git, fixture, &.{ "init", "--initial-branch=main" });
    try test_git(io, git, fixture, &.{ "config", "user.email", "fixture@example.invalid" });
    try test_git(io, git, fixture, &.{ "config", "user.name", "Fixture" });
    try test_git(io, git, fixture, &.{ "commit", "--allow-empty", "-m", "base" });
    try test_git(io, git, fixture, &.{ "commit", "--allow-empty", "-m", "next" });
    try test_git(io, git, fixture, &.{ "init", "--bare", "remote.git" });
    var remote_path: [512]u8 = undefined;
    const remote = try std.fmt.bufPrint(&remote_path, "{s}/remote.git", .{fixture});
    try test_git(io, git, fixture, &.{ "remote", "add", "satellite", remote });
    try test_git(io, git, fixture, &.{ "config", "push.default", "current" });
    var buffers = try TestBuffers.init(io, fixture);
    defer buffers.deinit();
    const request: Request = .{ .push = .{ .remote = "satellite" } };
    try test_git(io, git, fixture, &.{ "commit", "--allow-empty", "-m", "latest" });
    inline for (.{
        .{ "refs/tags/v1", "refs/tags/v1" },
        .{ "refs/review/candidate", "refs/review/candidate" },
        .{ "FETCH_HEAD", "refs/review/from-fetch" },
        .{ "main@{1}", "refs/review/from-reflog" },
    }) |case| {
        const source = case.@"0";
        const destination = case.@"1";
        const reflog = std.mem.eql(u8, source, "main@{1}");
        const fetched = std.mem.eql(u8, source, "FETCH_HEAD");
        if (fetched) try test_fetch_revision(io, git, fixture, "HEAD^") else if (!reflog) try test_git(io, git, fixture, &.{ "update-ref", source, "HEAD^" });
        try test_git(io, git, fixture, &.{ "config", "remote.satellite.push", source ++ ":" ++ destination });
        const reviewed = try collect(io, git, fixture, request, buffers.value());
        if (reflog) try test_git(io, git, fixture, &.{ "reflog", "delete", "--rewrite", "main@{1}" }) else if (fetched) try test_fetch_revision(io, git, fixture, "HEAD") else try test_git(io, git, fixture, &.{ "update-ref", source, "HEAD" });
        try std.testing.expectError(error.StalePreflight, test_execute_reviewed(io, reviewed, request, &buffers));
        try test_git_expect_failure(io, git, remote, &.{ "show-ref", "--verify", destination });
        const fresh = try collect(io, git, fixture, request, buffers.value());
        try std.testing.expect(!same(reviewed.preflight.target, fresh.preflight.target));
        try std.testing.expect(same(reviewed.preflight.head, fresh.preflight.head));
        try std.testing.expect(same(reviewed.preflight.index, fresh.preflight.index));
        try std.testing.expect(same(reviewed.preflight.executable_config, fresh.preflight.executable_config));
        try std.testing.expect((try test_execute_reviewed(io, fresh, request, &buffers)).succeeded);
        const expected = try test_git_output(io, git, fixture, &.{ "rev-parse", source });
        defer std.testing.allocator.free(expected.stdout);
        defer std.testing.allocator.free(expected.stderr);
        try std.testing.expect(expected.succeeded);
        try test_expect_exact_output(io, git, remote, &.{ "rev-parse", destination }, expected.stdout);
    }
}

test "installed Git subdirectory review stages root paths and preserves shadows" {
    if (comptime builtin.os.tag != .windows) return;
    if (!test_git_enabled()) return;
    const git = try test_git_executable();
    defer std.testing.allocator.free(git);
    const io = std.testing.io;
    var fixture_memory: ["C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e".len + 1 + 16]u8 = undefined;
    const fixture = try test_fixture(io, &fixture_memory);
    defer std.Io.Dir.cwd().deleteTree(io, fixture) catch {};
    try test_git(io, git, fixture, &.{ "init", "--initial-branch=main" });
    try test_git(io, git, fixture, &.{ "config", "user.email", "fixture@example.invalid" });
    try test_git(io, git, fixture, &.{ "config", "user.name", "Fixture" });
    var sub_path: [512]u8 = undefined;
    const sub = try std.fmt.bufPrint(&sub_path, "{s}/sub", .{fixture});
    try std.Io.Dir.cwd().createDir(io, sub, .default_dir);
    try test_write(io, fixture, ".gitattributes", "file.txt -text\n");
    try test_write(io, sub, ".gitattributes", "file.txt text eol=lf\n");
    try test_write(io, fixture, "file.txt", "root base\r\n");
    try test_write(io, sub, "file.txt", "shadow base\n");
    try test_git(io, git, fixture, &.{ "add", "--", "." });
    try test_git(io, git, fixture, &.{ "commit", "-m", "base" });
    try test_write(io, fixture, "file.txt", "root change\r\n");
    try test_write(io, sub, "file.txt", "shadow change\n");
    var buffers = try TestBuffers.init(io, fixture);
    defer buffers.deinit();
    try test_subdirectory_status(io, git, sub, &buffers);
    const stage: Request = .{ .stage = .{ .path = "file.txt" } };
    const root_review = try collect(io, git, fixture, stage, buffers.value());
    const reviewed = try collect(io, git, sub, stage, buffers.value());
    try std.testing.expect(!same(root_review.preflight.repository, reviewed.preflight.repository));
    try std.testing.expect(same(root_review.preflight.worktree, reviewed.preflight.worktree));
    try std.testing.expect(same(root_review.preflight.target, reviewed.preflight.target));
    try std.testing.expect(same(root_review.preflight.attributes, reviewed.preflight.attributes));
    try std.testing.expect((try test_execute_reviewed(io, reviewed, stage, &buffers)).succeeded);
    try test_expect_exact_output(io, git, fixture, &.{ "show", ":file.txt" }, "root change\r\n");
    try test_expect_exact_output(io, git, fixture, &.{ "show", ":sub/file.txt" }, "shadow base\n");
    const unstage: Request = .{ .unstage = .{ .path = "file.txt" } };
    const staged = try collect(io, git, sub, unstage, buffers.value());
    const root_staged = try collect(io, git, fixture, unstage, buffers.value());
    try std.testing.expect(same(staged.preflight.target, root_staged.preflight.target));
    const unstaged = try collect(io, git, sub, unstage, buffers.value());
    try std.testing.expect((try test_execute_reviewed(io, unstaged, unstage, &buffers)).succeeded);
    try test_expect_output(io, git, fixture, &.{ "diff", "--cached", "--name-only" }, "");
    try test_expect_exact_output(io, git, fixture, &.{ "show", ":file.txt" }, "root base\r\n");
    try test_expect_exact_output(io, git, fixture, &.{ "show", ":sub/file.txt" }, "shadow base\n");
    var bytes: [64]u8 = undefined;
    var path: [512]u8 = undefined;
    const shadow = try files.load(io, try join_path(sub, "file.txt", &path), &bytes);
    try std.testing.expectEqualStrings("shadow change\n", shadow.bytes);
    const root = try files.load(io, try join_path(fixture, "file.txt", &path), &bytes);
    try std.testing.expectEqualStrings("root change\r\n", root.bytes);
}

fn test_fetch_revision(io: std.Io, git: []const u8, fixture: []const u8, revision: []const u8) !void {
    const output = try test_git_output(io, git, fixture, &.{ "rev-parse", "--verify", revision });
    defer std.testing.allocator.free(output.stdout);
    defer std.testing.allocator.free(output.stderr);
    try std.testing.expect(output.succeeded);
    try test_git(io, git, fixture, &.{ "fetch", "--no-tags", ".", std.mem.trimEnd(u8, output.stdout, "\r\n") });
}

fn test_expect_exact_output(io: std.Io, git: []const u8, fixture: []const u8, tail: []const []const u8, expected: []const u8) !void {
    const output = try test_git_output(io, git, fixture, tail);
    defer std.testing.allocator.free(output.stdout);
    defer std.testing.allocator.free(output.stderr);
    try std.testing.expect(output.succeeded);
    try std.testing.expectEqualStrings(expected, output.stdout);
}

fn test_execute_reviewed(io: std.Io, reviewed: Collected, request: Request, buffers: *TestBuffers) !Result {
    var grants: [1]trust.Grant = undefined;
    var store = trust.Store.init(&grants);
    try store.grant(.{ .repository = reviewed.preflight.repository, .config = reviewed.preflight.executable_config, .scope = scope(request) });
    var token = Token.init(reviewed.preflight);
    return execute_revalidated(io, &store, &token, reviewed, request, buffers.value(), buffers.workspace, 4096, 4096, test_timeout());
}

fn test_subdirectory_status(io: std.Io, git: []const u8, repository: []const u8, buffers: *TestBuffers) !void {
    const reviewed = try collect(io, git, repository, .{ .worktree_status = {} }, buffers.value());
    var grants: [1]trust.Grant = undefined;
    var store = trust.Store.init(&grants);
    try store.grant(.{ .repository = reviewed.preflight.repository, .config = reviewed.preflight.executable_config, .scope = .worktree_status });
    var token = Token.init(reviewed.preflight);
    var status: [4096]u8 = undefined;
    const result = try execute_worktree_status_revalidated(io, &store, &token, reviewed, buffers.value(), buffers.workspace, &status, status.len, 4096, test_timeout());
    try std.testing.expect(result.succeeded);
    try std.testing.expect(std.mem.indexOf(u8, status[0..result.stdout_bytes], " file.txt\x00") != null);
    try std.testing.expect(std.mem.indexOf(u8, status[0..result.stdout_bytes], " sub/file.txt\x00") != null);
}

test "installed Git push preflight rejects deletion and mirror before transport" {
    if (comptime builtin.os.tag != .windows) return;
    if (!test_git_enabled()) return;
    const git = try test_git_executable();
    defer std.testing.allocator.free(git);
    const io = std.testing.io;
    var fixture_memory: ["C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e".len + 1 + 16]u8 = undefined;
    const fixture = try test_fixture(io, &fixture_memory);
    defer std.Io.Dir.cwd().deleteTree(io, fixture) catch {};
    try test_git(io, git, fixture, &.{ "init", "--initial-branch=main" });
    try test_git(io, git, fixture, &.{ "config", "user.email", "fixture@example.invalid" });
    try test_git(io, git, fixture, &.{ "config", "user.name", "Fixture" });
    try test_write(io, fixture, "base.txt", "base\n");
    try test_git(io, git, fixture, &.{ "add", "--", "base.txt" });
    try test_git(io, git, fixture, &.{ "commit", "-m", "base" });
    try test_git(io, git, fixture, &.{ "init", "--bare", "remote.git" });
    var remote_path: [512]u8 = undefined;
    const remote = try std.fmt.bufPrint(&remote_path, "{s}/remote.git", .{fixture});
    try test_git(io, git, fixture, &.{ "remote", "add", "satellite", remote });
    try test_git(io, git, fixture, &.{ "push", "-u", "satellite", "main" });
    const request: Request = .{ .push = .{ .remote = "satellite" } };
    const before = try test_git_output(io, git, remote, &.{ "rev-parse", "refs/heads/main" });
    defer std.testing.allocator.free(before.stdout);
    defer std.testing.allocator.free(before.stderr);
    try test_git(io, git, fixture, &.{ "config", "remote.satellite.push", ":refs/heads/main" });
    var deletion_buffers = try TestBuffers.init(io, fixture);
    defer deletion_buffers.deinit();
    try std.testing.expectError(error.ForcePushNotSupported, collect(io, git, fixture, request, deletion_buffers.value()));
    try test_expect_output(io, git, remote, &.{ "rev-parse", "refs/heads/main" }, before.stdout);
    try test_git(io, git, fixture, &.{ "config", "--unset-all", "remote.satellite.push" });
    for ([_][]const u8{ "true", "yes", "on", "1" }) |value| {
        try test_git(io, git, fixture, &.{ "config", "remote.satellite.mirror", value });
        var buffers = try TestBuffers.init(io, fixture);
        defer buffers.deinit();
        try std.testing.expectError(error.ForcePushNotSupported, collect(io, git, fixture, request, buffers.value()));
        try test_expect_output(io, git, remote, &.{ "rev-parse", "refs/heads/main" }, before.stdout);
    }
    try test_git(io, git, fixture, &.{ "config", "remote.satellite.mirror", "false" });
    var false_buffers = try TestBuffers.init(io, fixture);
    defer false_buffers.deinit();
    _ = try collect(io, git, fixture, request, false_buffers.value());
    try test_git(io, git, fixture, &.{ "config", "remote.satellite.mirror", "invalid" });
    var invalid_buffers = try TestBuffers.init(io, fixture);
    defer invalid_buffers.deinit();
    try std.testing.expectError(error.GitFailed, collect(io, git, fixture, request, invalid_buffers.value()));
    try test_expect_output(io, git, remote, &.{ "rev-parse", "refs/heads/main" }, before.stdout);
}

test "installed Git record stages CRLF literal paths, unstages, and commits" {
    if (comptime builtin.os.tag != .windows) return;
    if (!test_git_enabled()) return;
    const git = try test_git_executable();
    defer std.testing.allocator.free(git);
    const io = std.testing.io;
    var fixture_memory: ["C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e".len + 1 + 16]u8 = undefined;
    const fixture = try test_fixture(io, &fixture_memory);
    defer std.Io.Dir.cwd().deleteTree(io, fixture) catch {};
    try test_git(io, git, fixture, &.{ "init", "--initial-branch=main" });
    try test_git(io, git, fixture, &.{ "config", "user.email", "fixture@example.invalid" });
    try test_git(io, git, fixture, &.{ "config", "user.name", "Fixture" });
    try test_git(io, git, fixture, &.{ "config", "core.autocrlf", "false" });
    try test_write(io, fixture, "bracket[1].txt", "base\r\n");
    try test_git(io, git, fixture, &.{ "add", "--", "bracket[1].txt" });
    try test_git(io, git, fixture, &.{ "commit", "-m", "base" });
    const changed = "changed\r\n";
    try test_write(io, fixture, "bracket[1].txt", changed);

    var buffers = try TestBuffers.init(io, fixture);
    defer buffers.deinit();
    const request = Request{ .stage = .{ .path = "bracket[1].txt" } };
    const collected = try collect(io, git, fixture, request, buffers.value());
    var grants: [1]trust.Grant = undefined;
    var store = trust.Store.init(&grants);
    try store.grant(.{ .repository = collected.preflight.repository, .config = collected.preflight.executable_config, .scope = .stage });
    var token = Token.init(collected.preflight);
    const staged = try execute_revalidated(io, &store, &token, collected, request, buffers.value(), buffers.workspace, 4096, 4096, test_timeout());
    try std.testing.expect(staged.succeeded);
    try test_expect_lock_absent(io, collected.common_dir);
    try test_expect_output(io, git, fixture, &.{ "diff", "--cached", "--", "bracket[1].txt" }, "+changed\r\n");

    var unstage_buffers = try TestBuffers.init(io, fixture);
    defer unstage_buffers.deinit();
    const unstage_request = Request{ .unstage = .{ .path = "bracket[1].txt" } };
    const unstage_collected = try collect(io, git, fixture, unstage_request, unstage_buffers.value());
    var unstage_grants: [1]trust.Grant = undefined;
    var unstage_store = trust.Store.init(&unstage_grants);
    try unstage_store.grant(.{ .repository = unstage_collected.preflight.repository, .config = unstage_collected.preflight.executable_config, .scope = .unstage });
    var unstage_token = Token.init(unstage_collected.preflight);
    const unstage_result = try execute_revalidated(io, &unstage_store, &unstage_token, unstage_collected, unstage_request, unstage_buffers.value(), unstage_buffers.workspace, 4096, 4096, test_timeout());
    try std.testing.expect(unstage_result.succeeded);
    try test_expect_lock_absent(io, unstage_collected.common_dir);
    try test_expect_output(io, git, fixture, &.{ "diff", "--cached", "--name-only" }, "");
    var work_bytes: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const work_path = try std.fmt.bufPrint(&work_bytes, "{s}/bracket[1].txt", .{fixture});
    var file_bytes: [32]u8 = undefined;
    const loaded = try files.load(io, work_path, &file_bytes);
    try std.testing.expectEqualStrings(changed, loaded.bytes);

    var commit_buffers = try TestBuffers.init(io, fixture);
    defer commit_buffers.deinit();
    const restage = try collect(io, git, fixture, request, commit_buffers.value());
    var restage_grants: [1]trust.Grant = undefined;
    var restage_store = trust.Store.init(&restage_grants);
    try restage_store.grant(.{ .repository = restage.preflight.repository, .config = restage.preflight.executable_config, .scope = .stage });
    var restage_token = Token.init(restage.preflight);
    try std.testing.expect((try execute_revalidated(io, &restage_store, &restage_token, restage, request, commit_buffers.value(), commit_buffers.workspace, 4096, 4096, test_timeout())).succeeded);
    const commit_request = Request{ .commit = .{ .message = "record fixture" } };
    const commit_collected = try collect(io, git, fixture, commit_request, commit_buffers.value());
    var commit_grants: [1]trust.Grant = undefined;
    var commit_store = trust.Store.init(&commit_grants);
    try commit_store.grant(.{ .repository = commit_collected.preflight.repository, .config = commit_collected.preflight.executable_config, .scope = .commit });
    var commit_token = Token.init(commit_collected.preflight);
    try std.testing.expect((try execute_revalidated(io, &commit_store, &commit_token, commit_collected, commit_request, commit_buffers.value(), commit_buffers.workspace, 4096, 4096, test_timeout())).succeeded);
    try test_expect_output(io, git, fixture, &.{ "log", "-1", "--format=%s" }, "record fixture\n");
}

test "installed Git record preserves staged index when pre-commit rejects" {
    if (comptime builtin.os.tag != .windows) return;
    if (!test_git_enabled()) return;
    const git = try test_git_executable();
    defer std.testing.allocator.free(git);
    const io = std.testing.io;
    var fixture_memory: ["C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e".len + 1 + 16]u8 = undefined;
    const fixture = try test_fixture(io, &fixture_memory);
    defer std.Io.Dir.cwd().deleteTree(io, fixture) catch {};
    try test_git(io, git, fixture, &.{ "init", "--initial-branch=main" });
    try test_git(io, git, fixture, &.{ "config", "user.email", "fixture@example.invalid" });
    try test_git(io, git, fixture, &.{ "config", "user.name", "Fixture" });
    try test_write(io, fixture, "tracked.txt", "base\n");
    try test_git(io, git, fixture, &.{ "add", "--", "tracked.txt" });
    try test_git(io, git, fixture, &.{ "commit", "-m", "base" });
    const changed = "staged change\n";
    try test_write(io, fixture, "tracked.txt", changed);
    try test_git(io, git, fixture, &.{ "add", "--", "tracked.txt" });
    try test_write(io, fixture, ".git/hooks/pre-commit", "#!/bin/sh\nexit 1\n");
    const head_before = try test_git_output(io, git, fixture, &.{ "rev-parse", "HEAD" });
    defer std.testing.allocator.free(head_before.stdout);
    defer std.testing.allocator.free(head_before.stderr);

    var buffers = try TestBuffers.init(io, fixture);
    defer buffers.deinit();
    const request = Request{ .commit = .{ .message = "must be rejected" } };
    const collected = try collect(io, git, fixture, request, buffers.value());
    var grants: [1]trust.Grant = undefined;
    var store = trust.Store.init(&grants);
    try store.grant(.{ .repository = collected.preflight.repository, .config = collected.preflight.executable_config, .scope = .commit });
    var token = Token.init(collected.preflight);
    const result = try execute_revalidated(io, &store, &token, collected, request, buffers.value(), buffers.workspace, 4096, 4096, test_timeout());
    try std.testing.expect(!result.succeeded);
    const head_after = try test_git_output(io, git, fixture, &.{ "rev-parse", "HEAD" });
    defer std.testing.allocator.free(head_after.stdout);
    defer std.testing.allocator.free(head_after.stderr);
    try std.testing.expectEqualStrings(head_before.stdout, head_after.stdout);
    try test_expect_output(io, git, fixture, &.{ "diff", "--cached", "--", "tracked.txt" }, "+staged change\n");
}

test "installed Git required clean filter failure does not index plaintext" {
    if (comptime builtin.os.tag != .windows) return;
    if (!test_git_enabled()) return;
    const git = try test_git_executable();
    defer std.testing.allocator.free(git);
    const io = std.testing.io;
    var fixture_memory: ["C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e".len + 1 + 16]u8 = undefined;
    const fixture = try test_fixture(io, &fixture_memory);
    defer std.Io.Dir.cwd().deleteTree(io, fixture) catch {};
    try test_git(io, git, fixture, &.{ "init", "--initial-branch=main" });
    try test_write(io, fixture, ".gitattributes", "secret.txt filter=reject\n");
    try test_git(io, git, fixture, &.{ "config", "filter.reject.clean", "exit 1" });
    try test_git(io, git, fixture, &.{ "config", "filter.reject.required", "true" });
    const plaintext = "must not enter index\n";
    try test_write(io, fixture, "secret.txt", plaintext);
    const hash = try test_git_output(io, git, fixture, &.{ "hash-object", "--no-filters", "--", "secret.txt" });
    defer std.testing.allocator.free(hash.stdout);
    defer std.testing.allocator.free(hash.stderr);
    try std.testing.expect(hash.succeeded);
    const plaintext_hash = std.mem.trimEnd(u8, hash.stdout, "\r\n");
    try std.testing.expectEqual(@as(usize, 40), plaintext_hash.len);

    var buffers = try TestBuffers.init(io, fixture);
    defer buffers.deinit();
    const request = Request{ .stage = .{ .path = "secret.txt" } };
    const collected = try collect(io, git, fixture, request, buffers.value());
    var grants: [1]trust.Grant = undefined;
    var store = trust.Store.init(&grants);
    try store.grant(.{ .repository = collected.preflight.repository, .config = collected.preflight.executable_config, .scope = .stage });
    var token = Token.init(collected.preflight);
    const result = try execute_revalidated(io, &store, &token, collected, request, buffers.value(), buffers.workspace, 4096, 4096, test_timeout());
    try std.testing.expect(!result.succeeded);
    try test_git_expect_failure(io, git, fixture, &.{ "cat-file", "-e", plaintext_hash });
    try test_expect_output(io, git, fixture, &.{ "diff", "--cached", "--name-only" }, "");
}

test "installed Git record rejects changed stage bytes, symbolic HEAD, and attributes" {
    if (comptime builtin.os.tag != .windows) return;
    if (!test_git_enabled()) return;
    const git = try test_git_executable();
    defer std.testing.allocator.free(git);
    const io = std.testing.io;
    var fixture_memory: ["C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e".len + 1 + 16]u8 = undefined;
    const fixture = try test_fixture(io, &fixture_memory);
    defer std.Io.Dir.cwd().deleteTree(io, fixture) catch {};
    try test_git(io, git, fixture, &.{ "init", "--initial-branch=main" });
    try test_git(io, git, fixture, &.{ "config", "user.email", "fixture@example.invalid" });
    try test_git(io, git, fixture, &.{ "config", "user.name", "Fixture" });
    try test_write(io, fixture, "target.txt", "base\n");
    try test_git(io, git, fixture, &.{ "add", "--", "target.txt" });
    try test_git(io, git, fixture, &.{ "commit", "-m", "base" });
    try test_write(io, fixture, "target.txt", "first\n");
    const request = Request{ .stage = .{ .path = "target.txt" } };

    var byte_buffers = try TestBuffers.init(io, fixture);
    defer byte_buffers.deinit();
    const byte_collected = try collect(io, git, fixture, request, byte_buffers.value());
    var byte_grants: [1]trust.Grant = undefined;
    var byte_store = trust.Store.init(&byte_grants);
    try byte_store.grant(.{ .repository = byte_collected.preflight.repository, .config = byte_collected.preflight.executable_config, .scope = .stage });
    var byte_token = Token.init(byte_collected.preflight);
    try test_write(io, fixture, "target.txt", "other\n");
    try std.testing.expectError(error.StalePreflight, execute_revalidated(io, &byte_store, &byte_token, byte_collected, request, byte_buffers.value(), byte_buffers.workspace, 4096, 4096, test_timeout()));
    try test_expect_output(io, git, fixture, &.{ "diff", "--cached", "--name-only" }, "");

    var head_buffers = try TestBuffers.init(io, fixture);
    defer head_buffers.deinit();
    const head_collected = try collect(io, git, fixture, request, head_buffers.value());
    var head_grants: [1]trust.Grant = undefined;
    var head_store = trust.Store.init(&head_grants);
    try head_store.grant(.{ .repository = head_collected.preflight.repository, .config = head_collected.preflight.executable_config, .scope = .stage });
    var head_token = Token.init(head_collected.preflight);
    try test_git(io, git, fixture, &.{ "branch", "same-commit" });
    try test_git(io, git, fixture, &.{ "checkout", "same-commit" });
    try std.testing.expectError(error.StalePreflight, execute_revalidated(io, &head_store, &head_token, head_collected, request, head_buffers.value(), head_buffers.workspace, 4096, 4096, test_timeout()));
    try test_expect_output(io, git, fixture, &.{ "diff", "--cached", "--name-only" }, "");

    try test_write(io, fixture, ".gitattributes", "secret.txt filter=reject\n");
    try test_git(io, git, fixture, &.{ "config", "filter.reject.clean", "exit 1" });
    try test_git(io, git, fixture, &.{ "config", "filter.reject.required", "true" });
    const plaintext = "must not enter index\n";
    try test_write(io, fixture, "secret.txt", plaintext);
    const hash = try test_git_output(io, git, fixture, &.{ "hash-object", "--no-filters", "--", "secret.txt" });
    defer std.testing.allocator.free(hash.stdout);
    defer std.testing.allocator.free(hash.stderr);
    const plaintext_hash = std.mem.trimEnd(u8, hash.stdout, "\r\n");
    var attribute_buffers = try TestBuffers.init(io, fixture);
    defer attribute_buffers.deinit();
    const secret_request = Request{ .stage = .{ .path = "secret.txt" } };
    const attribute_collected = try collect(io, git, fixture, secret_request, attribute_buffers.value());
    var attribute_grants: [1]trust.Grant = undefined;
    var attribute_store = trust.Store.init(&attribute_grants);
    try attribute_store.grant(.{ .repository = attribute_collected.preflight.repository, .config = attribute_collected.preflight.executable_config, .scope = .stage });
    var attribute_token = Token.init(attribute_collected.preflight);
    try test_write(io, fixture, ".gitattributes", "secret.txt -filter\n");
    try std.testing.expectError(error.StalePreflight, execute_revalidated(io, &attribute_store, &attribute_token, attribute_collected, secret_request, attribute_buffers.value(), attribute_buffers.workspace, 4096, 4096, test_timeout()));
    try test_git_expect_failure(io, git, fixture, &.{ "cat-file", "-e", plaintext_hash });
    try test_expect_output(io, git, fixture, &.{ "diff", "--cached", "--name-only" }, "");
}

test "installed Git record rejects stale config, request, and existing locks" {
    if (comptime builtin.os.tag != .windows) return;
    if (!test_git_enabled()) return;
    const git = try test_git_executable();
    defer std.testing.allocator.free(git);
    const io = std.testing.io;
    var fixture_memory: ["C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e".len + 1 + 16]u8 = undefined;
    const fixture = try test_fixture(io, &fixture_memory);
    defer std.Io.Dir.cwd().deleteTree(io, fixture) catch {};
    try test_git(io, git, fixture, &.{"init"});
    try test_git(io, git, fixture, &.{ "config", "user.email", "fixture@example.invalid" });
    try test_git(io, git, fixture, &.{ "config", "user.name", "Fixture" });
    try test_write(io, fixture, "one.txt", "one\n");
    var buffers = try TestBuffers.init(io, fixture);
    defer buffers.deinit();
    const request = Request{ .stage = .{ .path = "one.txt" } };
    const collected = try collect(io, git, fixture, request, buffers.value());
    var grants: [1]trust.Grant = undefined;
    var store = trust.Store.init(&grants);
    try store.grant(.{ .repository = collected.preflight.repository, .config = collected.preflight.executable_config, .scope = .stage });
    var token = Token.init(collected.preflight);
    try test_git(io, git, fixture, &.{ "config", "user.name", "Otherxx" });
    try std.testing.expectError(error.StalePreflight, execute_revalidated(io, &store, &token, collected, request, buffers.value(), buffers.workspace, 4096, 4096, test_timeout()));
    try test_expect_lock_absent(io, collected.common_dir);
    try std.testing.expectError(error.TokenExpired, execute_revalidated(io, &store, &token, collected, request, buffers.value(), buffers.workspace, 4096, 4096, test_timeout()));

    var lock_path: [512]u8 = undefined;
    const lock = try std.fmt.bufPrint(&lock_path, "{s}/.git/index.lock", .{fixture});
    var lock_file = try std.Io.Dir.cwd().createFile(io, lock, .{ .exclusive = true });
    try lock_file.writeStreamingAll(io, "external index lock");
    lock_file.close(io);
    var locked_buffers = try TestBuffers.init(io, fixture);
    defer locked_buffers.deinit();
    const locked_collected = try collect(io, git, fixture, request, locked_buffers.value());
    var locked_grants: [1]trust.Grant = undefined;
    var locked_store = trust.Store.init(&locked_grants);
    try locked_store.grant(.{ .repository = locked_collected.preflight.repository, .config = locked_collected.preflight.executable_config, .scope = .stage });
    var locked_token = Token.init(locked_collected.preflight);
    try std.testing.expectError(error.IndexLockPresent, execute_revalidated(io, &locked_store, &locked_token, locked_collected, request, locked_buffers.value(), locked_buffers.workspace, 4096, 4096, test_timeout()));
    try test_expect_lock_absent(io, locked_collected.common_dir);
    var index_lock_bytes: [32]u8 = undefined;
    const index_lock_loaded = try files.load(io, lock, &index_lock_bytes);
    try std.testing.expectEqualStrings("external index lock", index_lock_loaded.bytes);
}

const TestBuffers = struct {
    command: []u8,
    environment: []u8,
    file: []u8,
    executable: []u8,
    repository: []u8,
    git: []u8,
    worktree: []u8,
    common: []u8,
    workspace: []u8,
    global_config: []u8,
    system_config: []u8,

    fn init(io: std.Io, fixture: []const u8) !TestBuffers {
        try test_write(io, fixture, "empty-global.config", "");
        try test_write(io, fixture, "empty-system.config", "");
        const global_config = try std.fmt.allocPrint(std.testing.allocator, "{s}/empty-global.config", .{fixture});
        errdefer std.testing.allocator.free(global_config);
        const system_config = try std.fmt.allocPrint(std.testing.allocator, "{s}/empty-system.config", .{fixture});
        errdefer std.testing.allocator.free(system_config);
        return .{ .command = try std.testing.allocator.alloc(u8, 64 * 1024), .environment = try std.testing.allocator.alloc(u8, 64 * 1024), .file = try std.testing.allocator.alloc(u8, 8 * 1024 * 1024), .executable = try std.testing.allocator.alloc(u8, 4096), .repository = try std.testing.allocator.alloc(u8, 4096), .git = try std.testing.allocator.alloc(u8, 4096), .worktree = try std.testing.allocator.alloc(u8, 4096), .common = try std.testing.allocator.alloc(u8, 4096), .workspace = try std.testing.allocator.alloc(u8, 128 * 1024), .global_config = global_config, .system_config = system_config };
    }
    fn deinit(self: *TestBuffers) void {
        std.testing.allocator.free(self.command);
        std.testing.allocator.free(self.environment);
        std.testing.allocator.free(self.file);
        std.testing.allocator.free(self.executable);
        std.testing.allocator.free(self.repository);
        std.testing.allocator.free(self.git);
        std.testing.allocator.free(self.worktree);
        std.testing.allocator.free(self.common);
        std.testing.allocator.free(self.workspace);
        std.testing.allocator.free(self.global_config);
        std.testing.allocator.free(self.system_config);
    }
    fn value(self: *TestBuffers) Buffers {
        return .{ .config_sources = .{ .global = self.global_config, .system = self.system_config, .no_system = true }, .command = self.command, .environment = self.environment, .file = self.file, .canonical_executable = self.executable, .canonical_repository = self.repository, .canonical_git = self.git, .canonical_worktree = self.worktree, .canonical_common_dir = self.common };
    }
};

fn encode_hex_lower(destination: []u8, source: []const u8) void {
    const digits = "0123456789abcdef";
    std.debug.assert(destination.len == source.len * 2);
    for (source, 0..) |byte, index| {
        destination[index * 2] = digits[byte >> 4];
        destination[index * 2 + 1] = digits[byte & 0x0f];
    }
}

fn test_timeout() std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(10_000), .clock = .awake } };
}
fn test_git_enabled() bool {
    const value = (std.process.Environ{ .block = .global }).getAlloc(std.testing.allocator, "WARKOCZ_TEST_GIT_EXE") catch return false;
    defer std.testing.allocator.free(value);
    return value.len != 0;
}
fn test_git_executable() ![]u8 {
    const path = try (std.process.Environ{ .block = .global }).getAlloc(std.testing.allocator, "WARKOCZ_TEST_GIT_EXE");
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return error.InvalidConfiguredGitExecutable;
    return path;
}
fn test_fixture(io: std.Io, memory: []u8) ![]const u8 {
    const root = "C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e";
    try std.Io.Dir.cwd().createDirPath(io, root);
    @memcpy(memory[0..root.len], root);
    memory[root.len] = '/';
    var random: [8]u8 = undefined;
    for (0..16) |_| {
        try io.randomSecure(&random);
        encode_hex_lower(memory[root.len + 1 ..], &random);
        std.Io.Dir.cwd().createDir(io, memory, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return memory;
    }
    return error.TemporaryNameExhausted;
}
fn test_git(io: std.Io, git: []const u8, fixture: []const u8, tail: []const []const u8) !void {
    const output = try test_git_output(io, git, fixture, tail);
    defer std.testing.allocator.free(output.stdout);
    defer std.testing.allocator.free(output.stderr);
    if (!output.succeeded) {
        std.debug.print("Synthetic Git command failure: {s}\n", .{output.stderr[0..@min(output.stderr.len, 2048)]});
        return error.FixtureGitFailed;
    }
}
const TestGitOutput = struct { stdout: []u8, stderr: []u8, succeeded: bool };
fn test_git_output(io: std.Io, git: []const u8, fixture: []const u8, tail: []const []const u8) !TestGitOutput {
    var args: [10][]const u8 = undefined;
    args[0] = git;
    args[1] = "-C";
    args[2] = fixture;
    @memcpy(args[3..][0..tail.len], tail);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("GIT_CONFIG_GLOBAL", "");
    try environment.put("GIT_CONFIG_NOSYSTEM", "1");
    try environment.put("GIT_TERMINAL_PROMPT", "0");
    try environment.put("GIT_PAGER", "");
    const result = try std.process.run(std.testing.allocator, io, .{ .argv = args[0 .. 3 + tail.len], .environ_map = &environment, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096), .timeout = test_timeout() });
    return .{ .stdout = result.stdout, .stderr = result.stderr, .succeeded = result.term.success() };
}
fn test_git_expect_failure(io: std.Io, git: []const u8, fixture: []const u8, tail: []const []const u8) !void {
    const output = try test_git_output(io, git, fixture, tail);
    defer std.testing.allocator.free(output.stdout);
    defer std.testing.allocator.free(output.stderr);
    try std.testing.expect(!output.succeeded);
}
fn test_expect_output(io: std.Io, git: []const u8, fixture: []const u8, tail: []const []const u8, expected: []const u8) !void {
    const output = try test_git_output(io, git, fixture, tail);
    defer std.testing.allocator.free(output.stdout);
    defer std.testing.allocator.free(output.stderr);
    try std.testing.expect(output.succeeded);
    if (expected.len == 0) try std.testing.expectEqualStrings("", output.stdout) else try std.testing.expect(std.mem.indexOf(u8, output.stdout, expected) != null);
}
fn test_expect_lock_absent(io: std.Io, common_dir: []const u8) !void {
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const lock_path = try join_path(common_dir, "warkocz-operation.lock", &path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, lock_path, .{ .follow_symlinks = false }));
}

fn test_write(io: std.Io, fixture: []const u8, name: []const u8, bytes: []const u8) !void {
    var directory = try std.Io.Dir.cwd().openDir(io, fixture, .{ .access_sub_paths = true });
    defer directory.close(io);
    var file = try directory.createFile(io, name, .{ .exclusive = false });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}
