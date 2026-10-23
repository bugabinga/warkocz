const std = @import("std");
const builtin = @import("builtin");
const git_process = @import("git_process.zig");
const git_record = @import("record.zig");
const trust = @import("trust.zig");

pub const Limits = struct {
    stdout_bytes: usize,
    stderr_bytes: usize,
    status_rows: usize,
    history_rows: usize,
    timeout: std.Io.Timeout,
};

pub const Buffers = struct {
    version_workspace: []u8,
    status_workspace: []u8,
    history_workspace: []u8,
    status_rows: []Status,
    history_rows: []Commit,
    branch_workspace: []u8,
    branch_rows: []Branch,
};

pub const Request = struct {
    /// Must be an explicit installed-Git executable path, not a shell command.
    git_exe: []const u8,
    repository_path: []const u8,
    history_limit: usize,
    limits: Limits,
};

pub const Snapshot = struct {
    version: []const u8,
    status: []const Status,
    history: []const Commit,
    branches: []const Branch,
    worktree_status_available: bool = true,
};

pub const Branch = struct { name: []const u8, oid: []const u8, current: bool, worktree_path: []const u8 };

pub const Status = struct {
    kind: Kind,
    xy: [2]u8 = .{ ' ', ' ' },
    path: []const u8,
    original_path: ?[]const u8 = null,

    pub const Kind = enum { changed, renamed, unmerged, untracked, ignored };
};

pub const Commit = struct {
    id: []const u8,
    parents: []const u8,
    unix_seconds: []const u8,
    subject: []const u8,
};

pub const FileRequest = struct {
    git_exe: []const u8,
    repository_path: []const u8,
    path: []const u8,
    history_limit: usize,
    limits: Limits,
};

pub const BlameSpan = struct {
    line_id: usize,
    commit_id: []const u8,
    author: []const u8,
    summary: []const u8,
    source: []const u8,
};

pub const Error = error{
    EmptyGitExecutable,
    EmptyRepositoryPath,
    GitExecutableNotAbsolute,
    RepositoryPathNotAbsolute,
    NulByte,
    InvalidHistoryLimit,
    StatusRowLimitExceeded,
    HistoryRowLimitExceeded,
    BranchRowLimitExceeded,
    MalformedBranches,
    MalformedStatus,
    MalformedHistory,
    GitFailed,
    OutputLimitExceeded,
    ChildTimeout,
    EmptyFilePath,
    InvalidFilePath,
    InvalidSearchQuery,
    MalformedBlame,
    BlameRowLimitExceeded,
} || git_record.Error || std.mem.Allocator.Error || std.process.RunError;

/// Runs metadata-only installed-Git reads through native argv.
/// Worktree status is always withheld until execute_worktree_status_revalidated receives a scoped grant.
pub fn inspect(io: std.Io, request: Request, buffers: Buffers) Error!Snapshot {
    try validate_request(request, buffers);
    const version = try run_version(io, request, buffers.version_workspace);
    const status = buffers.status_rows[0..0];
    const history = if (try has_head(io, request, buffers.history_workspace))
        try parse_history(try run_history(io, request, buffers.history_workspace), buffers.history_rows, request.limits.history_rows)
    else
        buffers.history_rows[0..0];
    const branches = try parse_branches(try run_branches(io, request, buffers.branch_workspace), buffers.branch_rows, buffers.branch_rows.len);
    std.debug.assert(status.len <= buffers.status_rows.len and history.len <= buffers.history_rows.len and branches.len <= buffers.branch_rows.len);
    return .{ .version = version, .status = status, .history = history, .branches = branches, .worktree_status_available = false };
}

/// Parses only caller-owned bytes produced after record's scoped revalidation.
pub fn execute_worktree_status_revalidated(io: std.Io, store: *const trust.Store, token: *git_record.Token, initial: git_record.Collected, record_buffers: git_record.Buffers, workspace: []u8, status_workspace: []u8, status_rows: []Status, limits: Limits) Error![]const Status {
    const result = try git_record.execute_worktree_status_revalidated(io, store, token, initial, record_buffers, workspace, status_workspace, limits.stdout_bytes, limits.stderr_bytes, limits.timeout);
    if (!result.succeeded) return error.GitFailed;
    std.debug.assert(result.stdout_bytes <= status_workspace.len);
    return parse_status(status_workspace[0..result.stdout_bytes], status_rows, limits.status_rows);
}

pub fn validate_request(request: Request, buffers: Buffers) Error!void {
    if (request.git_exe.len == 0) return error.EmptyGitExecutable;
    if (request.repository_path.len == 0) return error.EmptyRepositoryPath;
    if (std.mem.indexOfScalar(u8, request.git_exe, 0) != null or std.mem.indexOfScalar(u8, request.repository_path, 0) != null) return error.NulByte;
    if (!std.fs.path.isAbsolute(request.git_exe)) return error.GitExecutableNotAbsolute;
    if (!std.fs.path.isAbsolute(request.repository_path)) return error.RepositoryPathNotAbsolute;
    if (request.history_limit == 0) return error.InvalidHistoryLimit;
    if (request.limits.status_rows > buffers.status_rows.len or request.limits.history_rows > buffers.history_rows.len) return error.OutputLimitExceeded;
    if (request.limits.stdout_bytes == 0 or request.limits.stderr_bytes == 0) return error.OutputLimitExceeded;
    std.debug.assert(request.limits.status_rows <= buffers.status_rows.len);
    std.debug.assert(request.limits.history_rows <= buffers.history_rows.len);
}

fn run_version(io: std.Io, request: Request, workspace: []u8) Error![]const u8 {
    const argv = [_][]const u8{ request.git_exe, "--version" };
    const output = try run(io, request, &argv, workspace);
    if (!output.term.success()) return error.GitFailed;
    return std.mem.trimEnd(u8, output.stdout, "\r\n");
}

fn has_head(io: std.Io, request: Request, workspace: []u8) Error!bool {
    const argv = [_][]const u8{ request.git_exe, "-C", request.repository_path, "--no-pager", "rev-parse", "--verify", "-q", "HEAD" };
    const output = try run(io, request, &argv, workspace);
    return output.term.success();
}

fn run_branches(io: std.Io, request: Request, workspace: []u8) Error![]const u8 {
    const argv = [_][]const u8{ request.git_exe, "-C", request.repository_path, "--no-pager", "for-each-ref", "--format=%(refname:short)%00%(objectname)%00%(HEAD)%00%(worktreepath)%00", "refs/heads" };
    const output = try run(io, request, &argv, workspace);
    if (!output.term.success()) return error.GitFailed;
    return output.stdout;
}

fn run_history(io: std.Io, request: Request, workspace: []u8) Error![]const u8 {
    var count_memory: [20]u8 = undefined;
    const count = std.fmt.bufPrint(&count_memory, "{d}", .{request.history_limit}) catch unreachable;
    const argv = [_][]const u8{ request.git_exe, "-C", request.repository_path, "--no-pager", "log", "-z", "--no-decorate", "--no-ext-diff", "--no-show-signature", "--format=%H%x00%P%x00%ct%x00%s%x00", "-n", count };
    const output = try run(io, request, &argv, workspace);
    if (!output.term.success()) return error.GitFailed;
    return output.stdout;
}

fn run(io: std.Io, request: Request, argv: []const []const u8, workspace: []u8) Error!std.process.RunResult {
    if (argv.len == 0 or argv.len >= 64) return error.OutputLimitExceeded;
    var guarded_argv: [64][]const u8 = undefined;
    guarded_argv[0] = argv[0];
    guarded_argv[1] = "--no-lazy-fetch";
    @memcpy(guarded_argv[2..][0 .. argv.len - 1], argv[1..]);
    var allocator = std.heap.FixedBufferAllocator.init(workspace);
    var environment = std.process.Environ.Map.init(allocator.allocator());
    defer environment.deinit();
    try sanitized_environment(&environment);
    return git_process.run(allocator.allocator(), io, .{
        .argv = guarded_argv[0 .. argv.len + 1],
        .environ_map = &environment,
        .cwd = .inherit,
        .stdout_limit = .limited(request.limits.stdout_bytes),
        .stderr_limit = .limited(request.limits.stderr_bytes),
        .reserve_amount = 64,
        .timeout = request.limits.timeout,
    }) catch |err| switch (err) {
        error.StreamTooLong, error.OutOfMemory => error.OutputLimitExceeded,
        error.Timeout => error.ChildTimeout,
        else => |unexpected| unexpected,
    };
}

fn sanitized_environment(environment: *std.process.Environ.Map) std.mem.Allocator.Error!void {
    try environment.put("GIT_CONFIG_NOSYSTEM", "1");
    try environment.put("GIT_CONFIG_GLOBAL", "");
    try environment.put("GIT_OPTIONAL_LOCKS", "0");
    try environment.put("GIT_NO_LAZY_FETCH", "1");
    try environment.put("GIT_PAGER", "cat");
    try environment.put("GIT_TERMINAL_PROMPT", "0");
    try environment.put("GIT_ASKPASS", "");
}

/// Blame only committed HEAD content, never workspace bytes that may trigger filters.
pub fn blame(io: std.Io, request: FileRequest, workspace: []u8, destination: []BlameSpan) Error![]const BlameSpan {
    try validate_file_request(request, workspace, destination.len, null);
    const argv = [_][]const u8{ request.git_exe, "-C", request.repository_path, "--no-pager", "--literal-pathspecs", "-c", "core.fsmonitor=false", "blame", "--line-porcelain", "--no-ext-diff", "--no-textconv", "HEAD", "--", request.path };
    const output = try run(io, .{ .git_exe = request.git_exe, .repository_path = request.repository_path, .history_limit = request.history_limit, .limits = request.limits }, &argv, workspace);
    if (!output.term.success()) return error.GitFailed;
    return parse_blame(output.stdout, destination, destination.len);
}

/// File history follows only the selected literal path; query, when present, is a literal subject/body substring.
pub fn file_history(io: std.Io, request: FileRequest, workspace: []u8, destination: []Commit, query: ?[]const u8) Error![]const Commit {
    try validate_file_request(request, workspace, destination.len, query);
    var count_memory: [20]u8 = undefined;
    const count = std.fmt.bufPrint(&count_memory, "{d}", .{request.history_limit}) catch unreachable;
    const base = [_][]const u8{ request.git_exe, "-C", request.repository_path, "--no-pager", "--literal-pathspecs", "-c", "core.fsmonitor=false", "log", "-z", "--no-decorate", "--no-ext-diff", "--no-textconv", "--no-show-signature", "--format=%H%x00%P%x00%ct%x00%s%x00", "-n", count };
    var argv: [base.len + 6][]const u8 = undefined;
    @memcpy(argv[0..base.len], &base);
    var length = base.len;
    if (query) |text| {
        argv[length] = "--fixed-strings";
        argv[length + 1] = "--grep";
        argv[length + 2] = text;
        length += 3;
    }
    argv[length] = "--follow";
    argv[length + 1] = "--";
    argv[length + 2] = request.path;
    length += 3;
    const output = try run(io, .{ .git_exe = request.git_exe, .repository_path = request.repository_path, .history_limit = request.history_limit, .limits = request.limits }, argv[0..length], workspace);
    if (!output.term.success()) return error.GitFailed;
    return parse_history(output.stdout, destination, request.history_limit);
}

pub fn parse_blame(input: []const u8, destination: []BlameSpan, limit: usize) Error![]const BlameSpan {
    if (limit > destination.len) return error.BlameRowLimitExceeded;
    var cursor: usize = 0;
    var count: usize = 0;
    var author: []const u8 = "";
    var summary: []const u8 = "";
    while (cursor < input.len) {
        const header = trim_cr(next_line(input, &cursor) orelse return error.MalformedBlame);
        if (header.len == 0) continue;
        var fields = std.mem.tokenizeScalar(u8, header, ' ');
        const commit = fields.next() orelse return error.MalformedBlame;
        _ = fields.next() orelse return error.MalformedBlame;
        const final_text = fields.next() orelse return error.MalformedBlame;
        const line_id = std.fmt.parseInt(usize, final_text, 10) catch return error.MalformedBlame;
        if (!is_hex_oid(commit)) return error.MalformedBlame;
        while (cursor < input.len) {
            const metadata_raw = next_line(input, &cursor) orelse return error.MalformedBlame;
            if (metadata_raw.len > 0 and metadata_raw[0] == '\t') {
                const metadata = metadata_raw;
                if (count == limit) return error.BlameRowLimitExceeded;
                destination[count] = .{ .line_id = line_id, .commit_id = commit, .author = author, .summary = summary, .source = metadata[1..] };
                count += 1;
                break;
            }
            const metadata = trim_cr(metadata_raw);
            if (std.mem.startsWith(u8, metadata, "author ")) author = metadata[7..];
            if (std.mem.startsWith(u8, metadata, "summary ")) summary = metadata[8..];
        }
    }
    return destination[0..count];
}

fn validate_file_request(request: FileRequest, workspace: []u8, rows: usize, query: ?[]const u8) Error!void {
    if (request.path.len == 0) return error.EmptyFilePath;
    if (request.history_limit == 0) return error.InvalidHistoryLimit;
    if (std.mem.indexOfScalar(u8, request.path, 0) != null or (query != null and std.mem.indexOfScalar(u8, query.?, 0) != null)) return error.NulByte;
    if (std.fs.path.isAbsolute(request.path) or std.mem.eql(u8, request.path, "..") or std.mem.startsWith(u8, request.path, "../") or std.mem.indexOf(u8, request.path, "/../") != null) return error.InvalidFilePath;
    if (query != null and query.?.len == 0) return error.InvalidSearchQuery;
    if (workspace.len == 0 or request.history_limit > rows or request.limits.stdout_bytes == 0) return error.OutputLimitExceeded;
    if (request.git_exe.len == 0) return error.EmptyGitExecutable;
    if (request.repository_path.len == 0) return error.EmptyRepositoryPath;
    if (!std.fs.path.isAbsolute(request.git_exe)) return error.GitExecutableNotAbsolute;
    if (!std.fs.path.isAbsolute(request.repository_path)) return error.RepositoryPathNotAbsolute;
}

fn next_line(input: []const u8, cursor: *usize) ?[]const u8 {
    if (cursor.* >= input.len) return null;
    const end = std.mem.indexOfScalarPos(u8, input, cursor.*, '\n') orelse input.len;
    const line = input[cursor.*..end];
    cursor.* = @min(end + 1, input.len);
    return line;
}

fn trim_cr(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

fn is_hex_oid(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

/// Parses Git porcelain v2 `-z` bytes without interpreting path encoding.
pub fn parse_status(input: []const u8, destination: []Status, limit: usize) Error![]const Status {
    if (limit > destination.len) return error.StatusRowLimitExceeded;
    var records = NulRecords{ .bytes = input };
    var count: usize = 0;
    while (records.next()) |record| {
        if (record.len == 0 or record[0] == '#') continue;
        if (count == limit) return error.StatusRowLimitExceeded;
        destination[count] = try parse_status_record(record, &records);
        count += 1;
    }
    std.debug.assert(count <= limit and count <= destination.len);
    return destination[0..count];
}

fn parse_status_record(record: []const u8, records: *NulRecords) Error!Status {
    if (std.mem.startsWith(u8, record, "? ")) return .{ .kind = .untracked, .path = record[2..] };
    if (std.mem.startsWith(u8, record, "! ")) return .{ .kind = .ignored, .path = record[2..] };
    const tag = field_at(record, 0) orelse return error.MalformedStatus;
    const xy = parse_xy(field_at(record, 1) orelse return error.MalformedStatus) orelse return error.MalformedStatus;
    if (tag.len != 1) return error.MalformedStatus;
    return switch (record[0]) {
        '1' => .{ .kind = .changed, .xy = xy, .path = field_at(record, 8) orelse return error.MalformedStatus },
        'u' => .{ .kind = .unmerged, .xy = xy, .path = field_at(record, 9) orelse return error.MalformedStatus },
        '2' => blk: {
            const source = records.next() orelse return error.MalformedStatus;
            break :blk .{ .kind = .renamed, .xy = xy, .path = field_at(record, 9) orelse return error.MalformedStatus, .original_path = source };
        },
        else => error.MalformedStatus,
    };
}

fn field_at(record: []const u8, wanted: usize) ?[]const u8 {
    var start: usize = 0;
    var index: usize = 0;
    while (start <= record.len) : (index += 1) {
        const end = std.mem.indexOfScalarPos(u8, record, start, ' ') orelse record.len;
        if (index == wanted) return record[start..end];
        if (end == record.len) return null;
        start = end + 1;
    }
    return null;
}

fn parse_xy(field: []const u8) ?[2]u8 {
    if (field.len != 2) return null;
    std.debug.assert(field.len == 2);
    return .{ field[0], field[1] };
}

pub fn parse_branches(input: []const u8, destination: []Branch, limit: usize) Error![]const Branch {
    var cursor: usize = 0;
    var count: usize = 0;
    while (cursor < input.len) {
        while (cursor < input.len and (input[cursor] == '\n' or input[cursor] == '\r')) : (cursor += 1) {}
        if (cursor == input.len) break;
        const name = next_nul(input, &cursor) orelse return error.MalformedBranches;
        if (name.len == 0) continue;
        const oid = next_nul(input, &cursor) orelse return error.MalformedBranches;
        const head = next_nul(input, &cursor) orelse return error.MalformedBranches;
        const worktree = next_nul(input, &cursor) orelse return error.MalformedBranches;
        if (count == limit or count == destination.len) return error.BranchRowLimitExceeded;
        if (oid.len != 40 and oid.len != 64 or (head.len != 0 and !std.mem.eql(u8, head, "*") and !std.mem.eql(u8, head, " "))) return error.MalformedBranches;
        destination[count] = .{ .name = name, .oid = oid, .current = std.mem.eql(u8, head, "*"), .worktree_path = worktree };
        count += 1;
    }
    return destination[0..count];
}

fn next_nul(input: []const u8, cursor: *usize) ?[]const u8 {
    if (cursor.* >= input.len) return null;
    const end = std.mem.indexOfScalarPos(u8, input, cursor.*, 0) orelse return null;
    const result = input[cursor.*..end];
    cursor.* = end + 1;
    return result;
}

pub fn parse_history(input: []const u8, destination: []Commit, limit: usize) Error![]const Commit {
    if (limit > destination.len) return error.HistoryRowLimitExceeded;
    var records = NulRecords{ .bytes = input };
    var count: usize = 0;
    while (records.next()) |id| {
        if (id.len == 0) continue;
        if (count == limit) return error.HistoryRowLimitExceeded;
        const parents = records.next() orelse return error.MalformedHistory;
        const unix_seconds = records.next() orelse return error.MalformedHistory;
        const subject = records.next() orelse return error.MalformedHistory;
        if (unix_seconds.len == 0) return error.MalformedHistory;
        destination[count] = .{ .id = id, .parents = parents, .unix_seconds = unix_seconds, .subject = subject };
        count += 1;
    }
    std.debug.assert(count <= limit and count <= destination.len);
    return destination[0..count];
}

const NulRecords = struct {
    bytes: []const u8,
    cursor: usize = 0,

    fn next(self: *NulRecords) ?[]const u8 {
        if (self.cursor == self.bytes.len) return null;
        std.debug.assert(self.cursor < self.bytes.len);
        const end = std.mem.indexOfScalarPos(u8, self.bytes, self.cursor, 0) orelse return null;
        const result = self.bytes[self.cursor..end];
        self.cursor = end + 1;
        std.debug.assert(self.cursor <= self.bytes.len);
        return result;
    }
};

test "request requires absolute literal Git and repository paths" {
    var rows: [1]Status = undefined;
    var commits: [1]Commit = undefined;
    var version: [16]u8 = undefined;
    var status: [16]u8 = undefined;
    var history: [16]u8 = undefined;
    var branch_workspace: [16]u8 = undefined;
    var branches: [1]Branch = undefined;
    const buffers = Buffers{ .version_workspace = &version, .status_workspace = &status, .history_workspace = &history, .status_rows = &rows, .history_rows = &commits, .branch_workspace = &branch_workspace, .branch_rows = &branches };
    const limits = Limits{ .stdout_bytes = 1, .stderr_bytes = 1, .status_rows = 1, .history_rows = 1, .timeout = .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } } };
    const absolute_git = if (builtin.os.tag == .windows) "C:/git.exe" else "/git";
    const absolute_repository = if (builtin.os.tag == .windows) "C:/fixture" else "/fixture";
    try std.testing.expectError(error.GitExecutableNotAbsolute, validate_request(.{ .git_exe = "git", .repository_path = absolute_repository, .history_limit = 1, .limits = limits }, buffers));
    try std.testing.expectError(error.RepositoryPathNotAbsolute, validate_request(.{ .git_exe = absolute_git, .repository_path = "fixture", .history_limit = 1, .limits = limits }, buffers));
    try std.testing.expectError(error.NulByte, validate_request(.{ .git_exe = if (builtin.os.tag == .windows) "C:/git\x00.exe" else "/git\x00", .repository_path = absolute_repository, .history_limit = 1, .limits = limits }, buffers));
}

test "porcelain parser preserves raw rename paths" {
    const source = "1 M. N... 100644 100644 100644 abc def path\x00" ++ "2 R. N... 100644 100644 100644 abc def R100 new\xff\x00old\xfe\x00? raw\x80\x00";
    var rows: [3]Status = undefined;
    const parsed = try parse_status(source, &rows, rows.len);
    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    try std.testing.expectEqual(Status.Kind.renamed, parsed[1].kind);
    try std.testing.expectEqualStrings("new\xff", parsed[1].path);
    try std.testing.expectEqualStrings("old\xfe", parsed[1].original_path.?);
    try std.testing.expectEqualStrings("raw\x80", parsed[2].path);
}

test "porcelain parser rejects truncated rename and row overflow" {
    var rows: [1]Status = undefined;
    try std.testing.expectError(error.MalformedStatus, parse_status("2 R. N... 1 1 1 a b R100 next\x00", &rows, rows.len));
    try std.testing.expectError(error.StatusRowLimitExceeded, parse_status("? a\x00? b\x00", &rows, rows.len));
}

test "branch parser bounds records and preserves current and worktree hints" {
    var rows: [2]Branch = undefined;
    const parsed = try parse_branches("main\x000123456789012345678901234567890123456789\x00*\x00\x00\nfeature\x00abcdefabcdefabcdefabcdefabcdefabcdefabcd\x00 \x00C:/worktree\x00\n", &rows, rows.len);
    try std.testing.expect(parsed[0].current);
    try std.testing.expectEqualStrings("feature", parsed[1].name);
    try std.testing.expectEqualStrings("C:/worktree", parsed[1].worktree_path);
    try std.testing.expectError(error.BranchRowLimitExceeded, parse_branches("a\x000123456789012345678901234567890123456789\x00\x00\x00\n", &rows, 0));
}

test "NUL history parser has bounded complete records" {
    var rows: [1]Commit = undefined;
    const parsed = try parse_history("abc\x00p1 p2\x0017\x00subject\x00", &rows, rows.len);
    try std.testing.expectEqualStrings("abc", parsed[0].id);
    try std.testing.expectError(error.MalformedHistory, parse_history("abc\x00p\x0017\x00", &rows, rows.len));
    try std.testing.expectError(error.HistoryRowLimitExceeded, parse_history("a\x00\x001\x00s\x00b\x00\x002\x00t\x00", &rows, rows.len));
}

test "line porcelain parser preserves source bytes and maps final line ids" {
    const oid = "0123456789012345678901234567890123456789";
    const record = oid ++ " 1 7 1\nauthor A\nsummary first\nfilename odd\\tname\n\tcode\twith-tab\r\n";
    var spans: [1]BlameSpan = undefined;
    const parsed = try parse_blame(record, &spans, spans.len);
    try std.testing.expectEqual(@as(usize, 7), parsed[0].line_id);
    try std.testing.expectEqualStrings("A", parsed[0].author);
    try std.testing.expectEqualStrings("first", parsed[0].summary);
    try std.testing.expectEqualStrings("code\twith-tab\r", parsed[0].source);
    try std.testing.expectError(error.BlameRowLimitExceeded, parse_blame(record ++ record, &spans, spans.len));
}

test "installed Git inspection is opt-in and confined to synthetic fixture" {
    if (comptime builtin.os.tag != .windows) return;
    if (!git_fixture_enabled()) return;
    var phase: []const u8 = "fixture setup";
    errdefer std.debug.print("installed Git inspection failed at {s}\n", .{phase});
    const root = "C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e";
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, root);
    var fixture_memory: [root.len + 1 + 16]u8 = undefined;
    const fixture = try create_fixture(io, cwd, root, &fixture_memory);
    defer cwd.deleteTree(io, fixture) catch {};
    const git_exe = try configured_git_executable();
    defer std.testing.allocator.free(git_exe);
    try fixture_git(io, git_exe, fixture, &.{"init"});
    try fixture_git(io, git_exe, fixture, &.{ "config", "user.email", "fixture@example.invalid" });
    try fixture_git(io, git_exe, fixture, &.{ "config", "user.name", "Fixture" });
    try write_fixture_file(io, fixture, "tracked.txt", "one\n");
    try write_fixture_file(io, fixture, "fsmonitor.cmd", "@echo executed>fsmonitor-ran.txt\r\n");
    try fixture_git(io, git_exe, fixture, &.{ "add", "tracked.txt", "fsmonitor.cmd" });
    try fixture_git(io, git_exe, fixture, &.{ "commit", "-m", "fixture commit" });
    try write_fixture_file(io, fixture, "tracked.txt", "two\n");
    try fixture_git(io, git_exe, fixture, &.{ "config", "core.fsmonitor", "fsmonitor.cmd" });
    phase = "metadata inspect with fsmonitor configured";
    var status_rows: [4]Status = undefined;
    var history_rows: [4]Commit = undefined;
    var version_workspace: [4096]u8 = undefined;
    var status_workspace: [16 * 1024]u8 = undefined;
    var history_workspace: [16 * 1024]u8 = undefined;
    var branch_workspace: [16 * 1024]u8 = undefined;
    var branch_rows: [4]Branch = undefined;
    const snapshot = try inspect_diagnostic("metadata inspect with fsmonitor configured", io, .{
        .git_exe = git_exe,
        .repository_path = fixture,
        .history_limit = 4,
        .limits = .{ .stdout_bytes = 4096, .stderr_bytes = 4096, .status_rows = 4, .history_rows = 4, .timeout = .{ .duration = .{ .raw = .fromMilliseconds(10_000), .clock = .awake } } },
    }, .{ .version_workspace = &version_workspace, .status_workspace = &status_workspace, .history_workspace = &history_workspace, .status_rows = &status_rows, .history_rows = &history_rows, .branch_workspace = &branch_workspace, .branch_rows = &branch_rows });
    try std.testing.expect(std.mem.startsWith(u8, snapshot.version, "git version "));
    try std.testing.expectEqual(@as(usize, 1), snapshot.history.len);
    try std.testing.expectEqualStrings("fixture commit", snapshot.history[0].subject);
    phase = "metadata snapshot assertions";
    try std.testing.expect(!snapshot.worktree_status_available);
    try std.testing.expectEqual(@as(usize, 0), snapshot.status.len);
    phase = "fsmonitor marker absence check";
    var marker_path: [root.len + 1 + 16 + "/fsmonitor-ran.txt".len]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_path, "{s}/fsmonitor-ran.txt", .{fixture});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, marker, .{}));
    phase = "clean/process filter verification";
    try verify_filter_inspection(io, git_exe, fixture);
}

fn verify_filter_inspection(io: std.Io, git_exe: []const u8, fixture: []const u8) !void {
    var phase: []const u8 = "clean-filter positive-control setup";
    errdefer std.debug.print("filter inspection failed at {s}\n", .{phase});
    try fixture_git(io, git_exe, fixture, &.{ "config", "core.fsmonitor", "false" });
    try write_fixture_file(io, fixture, ".gitattributes", "tracked.txt filter=fixture\n");
    try fixture_git(io, git_exe, fixture, &.{ "config", "filter.fixture.clean", "echo executed > filter-ran.txt" });
    // Positive control: ordinary configured Git status really invokes this owned fixture command.
    phase = "ordinary Git status clean-filter positive control";
    try fixture_git(io, git_exe, fixture, &.{ "status", "--porcelain" });
    var marker_memory: [256]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_memory, "{s}/filter-ran.txt", .{fixture});
    const observed = try std.Io.Dir.cwd().openFile(io, marker, .{});
    observed.close(io);
    try std.Io.Dir.cwd().deleteFile(io, marker);
    phase = "metadata inspect with clean filter configured";
    var status_rows: [4]Status = undefined;
    var history_rows: [4]Commit = undefined;
    var branch_rows: [4]Branch = undefined;
    var version_workspace: [4096]u8 = undefined;
    var status_workspace: [16 * 1024]u8 = undefined;
    var history_workspace: [16 * 1024]u8 = undefined;
    var branch_workspace: [16 * 1024]u8 = undefined;
    const request = Request{ .git_exe = git_exe, .repository_path = fixture, .history_limit = 4, .limits = .{ .stdout_bytes = 4096, .stderr_bytes = 4096, .status_rows = 4, .history_rows = 4, .timeout = .{ .duration = .{ .raw = .fromMilliseconds(10_000), .clock = .awake } } } };
    const buffers = Buffers{ .version_workspace = &version_workspace, .status_workspace = &status_workspace, .history_workspace = &history_workspace, .status_rows = &status_rows, .history_rows = &history_rows, .branch_workspace = &branch_workspace, .branch_rows = &branch_rows };
    const snapshot = try inspect_diagnostic("metadata inspect with clean filter configured", io, request, buffers);
    phase = "clean-filter metadata assertions and marker absence";
    try std.testing.expect(!snapshot.worktree_status_available);
    try std.testing.expectEqual(@as(usize, 0), snapshot.status.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.history.len);
    try expect_filter_marker_absent(io, marker);
    phase = "process-filter metadata inspection";
    try fixture_git(io, git_exe, fixture, &.{ "config", "--unset", "filter.fixture.clean" });
    try fixture_git(io, git_exe, fixture, &.{ "config", "filter.fixture.process", "echo executed > filter-ran.txt" });
    const process_snapshot = try inspect_diagnostic("metadata inspect with process filter configured", io, request, buffers);
    try std.testing.expect(!process_snapshot.worktree_status_available);
    try expect_filter_marker_absent(io, marker);
}

fn inspect_diagnostic(phase: []const u8, io: std.Io, request: Request, buffers: Buffers) Error!Snapshot {
    return inspect(io, request, buffers) catch |err| {
        std.debug.print("installed Git inspection failed at {s}: {s}\n", .{ phase, @errorName(err) });
        return err;
    };
}

fn expect_filter_marker_absent(io: std.Io, marker: []const u8) !void {
    if (std.Io.Dir.cwd().openFile(io, marker, .{})) |file| {
        file.close(io);
        return error.UntrustedFilterExecuted;
    } else |err| if (err != error.FileNotFound) return err;
}

test "granted worktree status revalidates config and attributes" {
    if (comptime builtin.os.tag != .windows) return;
    if (!git_fixture_enabled()) return;
    const root = "C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e";
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, root);
    var fixture_memory: [root.len + 1 + 16]u8 = undefined;
    const fixture = try create_fixture(io, cwd, root, &fixture_memory);
    defer cwd.deleteTree(io, fixture) catch {};
    const git_exe = try configured_git_executable();
    defer std.testing.allocator.free(git_exe);
    try fixture_git(io, git_exe, fixture, &.{ "init", "--initial-branch=main" });
    try fixture_git(io, git_exe, fixture, &.{ "config", "user.email", "fixture@example.invalid" });
    try fixture_git(io, git_exe, fixture, &.{ "config", "user.name", "Fixture" });
    try write_fixture_file(io, fixture, "tracked.txt", "one\n");
    try fixture_git(io, git_exe, fixture, &.{ "add", "tracked.txt" });
    try fixture_git(io, git_exe, fixture, &.{ "commit", "-m", "fixture commit" });
    try write_fixture_file(io, fixture, "tracked.txt", "two\n");
    try write_fixture_file(io, fixture, ".gitattributes", "tracked.txt filter=fixture\n");
    try fixture_git(io, git_exe, fixture, &.{ "config", "filter.fixture.clean", "echo executed > filter-ran.txt" });
    var marker_memory: [256]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_memory, "{s}/filter-ran.txt", .{fixture});
    try expect_filter_marker_absent(io, marker);
    try fixture_git(io, git_exe, fixture, &.{ "status", "--porcelain" });
    const observed = try cwd.openFile(io, marker, .{});
    observed.close(io);
    try cwd.deleteFile(io, marker);

    var command: [64 * 1024]u8 = undefined;
    var environment: [64 * 1024]u8 = undefined;
    var file: [128 * 1024]u8 = undefined;
    var executable: [4096]u8 = undefined;
    var repository: [4096]u8 = undefined;
    var git: [4096]u8 = undefined;
    var worktree: [4096]u8 = undefined;
    var common: [4096]u8 = undefined;
    var global_path: [256]u8 = undefined;
    var system_path: [256]u8 = undefined;
    const global = try std.fmt.bufPrint(&global_path, "{s}/.git/empty-global.config", .{fixture});
    const system = try std.fmt.bufPrint(&system_path, "{s}/.git/empty-system.config", .{fixture});
    try write_fixture_file(io, fixture, ".git/empty-global.config", "");
    try write_fixture_file(io, fixture, ".git/empty-system.config", "");
    const buffers = git_record.Buffers{ .config_sources = .{ .global = global, .system = system, .no_system = true }, .command = &command, .environment = &environment, .file = &file, .canonical_executable = &executable, .canonical_repository = &repository, .canonical_git = &git, .canonical_worktree = &worktree, .canonical_common_dir = &common };
    const limits = Limits{ .stdout_bytes = 4096, .stderr_bytes = 4096, .status_rows = 4, .history_rows = 4, .timeout = .{ .duration = .{ .raw = .fromMilliseconds(10_000), .clock = .awake } } };
    var process_workspace: [128 * 1024]u8 = undefined;
    var status_workspace: [16 * 1024]u8 = undefined;
    var status_rows: [4]Status = undefined;
    const initial = try git_record.collect(io, git_exe, fixture, .{ .worktree_status = {} }, buffers);
    var grants: [1]trust.Grant = undefined;
    var store = trust.Store.init(&grants);
    try store.grant(.{ .repository = initial.preflight.repository, .config = initial.preflight.executable_config, .scope = .worktree_status });
    var token = git_record.Token.init(initial.preflight);
    const rows = try execute_worktree_status_revalidated(io, &store, &token, initial, buffers, &process_workspace, &status_workspace, &status_rows, limits);
    var found_tracked = false;
    for (rows) |row| found_tracked = found_tracked or std.mem.eql(u8, row.path, "tracked.txt");
    try std.testing.expect(found_tracked);
    const executed = try cwd.openFile(io, marker, .{});
    executed.close(io);
    try cwd.deleteFile(io, marker);

    var aliased_token = git_record.Token.init(initial.preflight);
    try std.testing.expectError(error.AliasedBuffers, execute_worktree_status_revalidated(io, &store, &aliased_token, initial, buffers, &process_workspace, &process_workspace, &status_rows, limits));
    try std.testing.expect(aliased_token.attempted);
    try std.testing.expectError(error.TokenExpired, execute_worktree_status_revalidated(io, &store, &aliased_token, initial, buffers, &process_workspace, &status_workspace, &status_rows, limits));
    try expect_filter_marker_absent(io, marker);

    try verify_status_refusals(io, git_exe, fixture, marker, buffers, &process_workspace, &status_workspace, &status_rows, limits);
}

fn verify_status_refusals(io: std.Io, git_exe: []const u8, fixture: []const u8, marker: []const u8, buffers: git_record.Buffers, process_workspace: []u8, status_workspace: []u8, status_rows: []Status, limits: Limits) !void {
    const denied = try git_record.collect(io, git_exe, fixture, .{ .worktree_status = {} }, buffers);
    var empty_grants: [1]trust.Grant = undefined;
    var empty_store = trust.Store.init(&empty_grants);
    var denied_token = git_record.Token.init(denied.preflight);
    try std.testing.expectError(error.TrustDenied, execute_worktree_status_revalidated(io, &empty_store, &denied_token, denied, buffers, process_workspace, status_workspace, status_rows, limits));
    try std.testing.expectError(error.TokenExpired, execute_worktree_status_revalidated(io, &empty_store, &denied_token, denied, buffers, process_workspace, status_workspace, status_rows, limits));
    try expect_filter_marker_absent(io, marker);

    const stale = try git_record.collect(io, git_exe, fixture, .{ .worktree_status = {} }, buffers);
    var stale_grants: [1]trust.Grant = undefined;
    var stale_store = trust.Store.init(&stale_grants);
    try stale_store.grant(.{ .repository = stale.preflight.repository, .config = stale.preflight.executable_config, .scope = .worktree_status });
    var stale_token = git_record.Token.init(stale.preflight);
    try fixture_git(io, git_exe, fixture, &.{ "config", "user.name", "Changed" });
    try std.testing.expectError(error.StalePreflight, execute_worktree_status_revalidated(io, &stale_store, &stale_token, stale, buffers, process_workspace, status_workspace, status_rows, limits));
    try expect_filter_marker_absent(io, marker);

    const stale_attributes = try git_record.collect(io, git_exe, fixture, .{ .worktree_status = {} }, buffers);
    var attribute_grants: [1]trust.Grant = undefined;
    var attribute_store = trust.Store.init(&attribute_grants);
    try attribute_store.grant(.{ .repository = stale_attributes.preflight.repository, .config = stale_attributes.preflight.executable_config, .scope = .worktree_status });
    var attribute_token = git_record.Token.init(stale_attributes.preflight);
    try write_fixture_file(io, fixture, ".gitattributes", "tracked.txt -filter\n");
    try std.testing.expectError(error.StalePreflight, execute_worktree_status_revalidated(io, &attribute_store, &attribute_token, stale_attributes, buffers, process_workspace, status_workspace, status_rows, limits));
    try expect_filter_marker_absent(io, marker);
}

test "installed Git inspection accepts unborn repository history" {
    if (comptime builtin.os.tag != .windows) return;
    if (!git_fixture_enabled()) return;
    const root = "C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e";
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, root);
    var fixture_memory: [root.len + 1 + 16]u8 = undefined;
    const fixture = try create_fixture(io, cwd, root, &fixture_memory);
    defer cwd.deleteTree(io, fixture) catch {};
    const git_exe = try configured_git_executable();
    defer std.testing.allocator.free(git_exe);
    try fixture_git(io, git_exe, fixture, &.{"init"});
    var status_rows: [1]Status = undefined;
    var history_rows: [1]Commit = undefined;
    var version_workspace: [4096]u8 = undefined;
    var status_workspace: [4096]u8 = undefined;
    var history_workspace: [4096]u8 = undefined;
    var branch_workspace: [4096]u8 = undefined;
    var branch_rows: [1]Branch = undefined;
    const snapshot = try inspect(io, .{ .git_exe = git_exe, .repository_path = fixture, .history_limit = 1, .limits = .{ .stdout_bytes = 4096, .stderr_bytes = 4096, .status_rows = 1, .history_rows = 1, .timeout = .{ .duration = .{ .raw = .fromMilliseconds(10_000), .clock = .awake } } } }, .{ .version_workspace = &version_workspace, .status_workspace = &status_workspace, .history_workspace = &history_workspace, .status_rows = &status_rows, .history_rows = &history_rows, .branch_workspace = &branch_workspace, .branch_rows = &branch_rows });
    try std.testing.expectEqual(@as(usize, 0), snapshot.history.len);
}

fn configured_git_executable() ![]u8 {
    const environ: std.process.Environ = .{ .block = .global };
    const path = try environ.getAlloc(std.testing.allocator, "WARKOCZ_TEST_GIT_EXE");
    errdefer std.testing.allocator.free(path);
    if (path.len == 0 or !std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidConfiguredGitExecutable;
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    file.close(std.testing.io);
    return path;
}

fn git_fixture_enabled() bool {
    const environ: std.process.Environ = .{ .block = .global };
    const value = environ.getAlloc(std.testing.allocator, "WARKOCZ_TEST_GIT_EXE") catch return false;
    defer std.testing.allocator.free(value);
    return value.len != 0;
}

fn create_fixture(io: std.Io, cwd: std.Io.Dir, root: []const u8, memory: []u8) ![]const u8 {
    std.debug.assert(memory.len == root.len + 1 + 16);
    @memcpy(memory[0..root.len], root);
    memory[root.len] = '/';
    var random: [8]u8 = undefined;
    for (0..16) |_| {
        try io.randomSecure(&random);
        encode_hex_lower(memory[root.len + 1 ..], &random);
        cwd.createDir(io, memory, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |unexpected| return unexpected,
        };
        return memory;
    }
    return error.TemporaryNameExhausted;
}

fn encode_hex_lower(destination: []u8, source: []const u8) void {
    std.debug.assert(destination.len == source.len * 2);
    const digits = "0123456789abcdef";
    for (source, 0..) |byte, index| {
        destination[index * 2] = digits[byte >> 4];
        destination[index * 2 + 1] = digits[byte & 0x0f];
    }
    std.debug.assert(destination.len == source.len * 2);
}

fn fixture_git(io: std.Io, git_exe: []const u8, fixture: []const u8, tail: []const []const u8) !void {
    var argv: [6][]const u8 = undefined;
    argv[0] = git_exe;
    argv[1] = "-C";
    argv[2] = fixture;
    if (tail.len > argv.len - 3) return error.TooManyArguments;
    @memcpy(argv[3..][0..tail.len], tail);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try sanitized_environment(&environment);
    const output = try std.process.run(std.testing.allocator, io, .{ .argv = argv[0 .. 3 + tail.len], .environ_map = &environment, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096), .timeout = .{ .duration = .{ .raw = .fromMilliseconds(10_000), .clock = .awake } } });
    defer std.testing.allocator.free(output.stdout);
    defer std.testing.allocator.free(output.stderr);
    if (!output.term.success()) return error.FixtureGitFailed;
}

fn write_fixture_file(io: std.Io, fixture: []const u8, name: []const u8, content: []const u8) !void {
    var directory = try std.Io.Dir.cwd().openDir(io, fixture, .{ .access_sub_paths = true });
    defer directory.close(io);
    var file = try directory.createFile(io, name, .{ .exclusive = false });
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}
