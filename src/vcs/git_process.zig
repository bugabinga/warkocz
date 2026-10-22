const builtin = @import("builtin");
const std = @import("std");

/// Windows owns a kill-on-close Job Object before the suspended root can execute.
/// Execution has one deadline; cancellation/reaping retains storage until safe.
/// Other platforms retain stdlib semantics, not process-tree/deadline guarantees.
/// Caller allocator must be backed by bounded workspace; either allocation or stream exhaustion fails visibly.
pub fn run(allocator: std.mem.Allocator, io: std.Io, options: std.process.RunOptions) std.process.RunError!std.process.RunResult {
    std.debug.assert(options.argv.len > 0 and options.argv[0].len > 0);
    std.debug.assert(options.reserve_amount > 0);
    std.debug.assert(options.stdout_limit.toInt() != null and options.stderr_limit.toInt() != null);
    std.debug.assert(options.timeout != .none);
    if (comptime builtin.os.tag != .windows) return std.process.run(allocator, io, options);
    return run_windows(allocator, io, options);
}

const windows = std.os.windows;
const WAIT_OBJECT_0: windows.DWORD = 0;
const WAIT_TIMEOUT: windows.DWORD = 258;
const INFINITE: windows.DWORD = 0xffff_ffff;
const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION: u32 = 9;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x0000_2000;
const BasicLimit = extern struct { per_process: i64 = 0, per_job: i64 = 0, flags: u32 = 0, minimum_working_set: usize = 0, maximum_working_set: usize = 0, active_process_limit: u32 = 0, affinity: usize = 0, priority_class: u32 = 0, scheduling_class: u32 = 0 };
const ExtendedLimit = extern struct { basic: BasicLimit = .{}, io: [48]u8 = @splat(0), process_memory_limit: usize = 0, job_memory_limit: usize = 0, peak_process_memory_used: usize = 0, peak_job_memory_used: usize = 0 };

extern "kernel32" fn CreateJobObjectW(?*windows.SECURITY_ATTRIBUTES, ?windows.LPCWSTR) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetInformationJobObject(windows.HANDLE, u32, ?*const anyopaque, windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn AssignProcessToJobObject(windows.HANDLE, windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ResumeThread(windows.HANDLE) callconv(.winapi) windows.DWORD;
extern "kernel32" fn TerminateJobObject(windows.HANDLE, windows.UINT) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WaitForSingleObject(windows.HANDLE, windows.DWORD) callconv(.winapi) windows.DWORD;

fn run_windows(allocator: std.mem.Allocator, io: std.Io, options: std.process.RunOptions) std.process.RunError!std.process.RunResult {
    const deadline = options.timeout.toTimestamp(io).?;
    if (deadline_expired(io, deadline)) return error.Timeout;
    const job = try make_job();
    defer windows.CloseHandle(job);
    var child = try std.process.spawn(io, .{ .exe = options.exe, .argv = options.argv, .cwd = options.cwd, .environ_map = options.environ_map, .expand_arg0 = options.expand_arg0, .progress_node = options.progress_node, .create_no_window = options.create_no_window, .start_suspended = true, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe });
    errdefer child.kill(io);
    std.debug.assert(child.id != null and child.stdin == null);
    std.debug.assert(child.stdout != null and child.stderr != null);
    if (!AssignProcessToJobObject(job, child.id.?).toBool()) return error.AccessDenied;
    if (deadline_expired(io, deadline)) return error.Timeout;
    if (ResumeThread(child.thread_handle) == std.math.maxInt(windows.DWORD)) return error.AccessDenied;
    return collect_windows(allocator, io, &child, job, deadline, options);
}

fn collect_windows(allocator: std.mem.Allocator, io: std.Io, child: *std.process.Child, job: windows.HANDLE, deadline: std.Io.Clock.Timestamp, options: std.process.RunOptions) std.process.RunError!std.process.RunResult {
    std.debug.assert(child.id != null and child.stdin == null);
    std.debug.assert(child.stdout.?.handle != child.stderr.?.handle);
    var streams: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(allocator, io, streams.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    // LIFO: terminate owned writers before MultiReader cancels/awaits reads and frees buffers.
    errdefer kill_job(job);
    try drain(&reader, options, io, deadline);
    try reader.checkAnyError();
    try wait_until_exit(child, io, deadline);
    const term = try child.wait(io);
    std.debug.assert(child.id == null);
    std.debug.assert(child.stdout == null and child.stderr == null);
    const stdout = try reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    const stderr = try reader.toOwnedSlice(1);
    std.debug.assert(stdout.len <= options.stdout_limit.toInt().?);
    std.debug.assert(stderr.len <= options.stderr_limit.toInt().?);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

fn drain(reader: *std.Io.File.MultiReader, options: std.process.RunOptions, io: std.Io, deadline: std.Io.Clock.Timestamp) std.process.RunError!void {
    std.debug.assert(reader.streams.len == 2);
    std.debug.assert(options.stdout_limit.toInt() != null and options.stderr_limit.toInt() != null);
    while (true) {
        if (deadline_expired(io, deadline)) return error.Timeout;
        reader.fill(options.reserve_amount, .{ .deadline = deadline }) catch |err| switch (err) {
            error.EndOfStream => return,
            else => |unexpected| return unexpected,
        };
        // Ready streams must not starve the deadline by avoiding a timed wait.
        if (deadline_expired(io, deadline)) return error.Timeout;
        if (reader.reader(0).buffered().len > options.stdout_limit.toInt().?) return error.StreamTooLong;
        if (reader.reader(1).buffered().len > options.stderr_limit.toInt().?) return error.StreamTooLong;
    }
}

fn wait_until_exit(child: *std.process.Child, io: std.Io, deadline: std.Io.Clock.Timestamp) std.process.RunError!void {
    std.debug.assert(child.id != null);
    std.debug.assert(child.stdout != null and child.stderr != null);
    if (deadline_expired(io, deadline)) return error.Timeout;
    const wait = WaitForSingleObject(child.id.?, deadline_milliseconds(io, deadline));
    if (wait == WAIT_TIMEOUT or deadline_expired(io, deadline)) return error.Timeout;
    if (wait == WAIT_OBJECT_0) return;
    return error.AccessDenied;
}

fn make_job() std.process.RunError!windows.HANDLE {
    const job = CreateJobObjectW(null, null) orelse return error.SystemResources;
    errdefer windows.CloseHandle(job);
    var limits = ExtendedLimit{};
    limits.basic.flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    std.debug.assert(@offsetOf(ExtendedLimit, "io") == @sizeOf(BasicLimit));
    if (!SetInformationJobObject(job, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION, &limits, @sizeOf(ExtendedLimit)).toBool()) return error.SystemResources;
    return job;
}

fn kill_job(job: windows.HANDLE) void {
    std.debug.assert(job != windows.INVALID_HANDLE_VALUE);
    // Closing our last job handle also terminates remaining members if this request fails.
    _ = TerminateJobObject(job, 1);
}

fn deadline_expired(io: std.Io, deadline: std.Io.Clock.Timestamp) bool {
    return !std.Io.Clock.Timestamp.now(io, deadline.clock).compare(.lt, deadline);
}

fn deadline_milliseconds(io: std.Io, deadline: std.Io.Clock.Timestamp) windows.DWORD {
    const ns = std.Io.Clock.Timestamp.now(io, deadline.clock).durationTo(deadline).raw.nanoseconds;
    if (ns <= 0) return 0;
    const milliseconds: windows.DWORD = @intCast(@min(@divFloor(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms), @as(i96, INFINITE - 1)));
    std.debug.assert(milliseconds > 0);
    std.debug.assert(milliseconds < INFINITE);
    return milliseconds;
}
