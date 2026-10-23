const std = @import("std");
const builtin = @import("builtin");
const git_process = @import("vcs/git_process.zig");
const windows = std.os.windows;

const WAIT_ABANDONED: windows.DWORD = 0x80;

extern "kernel32" fn CreateMutexW(?*windows.SECURITY_ATTRIBUTES, windows.BOOL, ?windows.LPCWSTR) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn WaitForSingleObject(windows.HANDLE, windows.DWORD) callconv(.winapi) windows.DWORD;
extern "kernel32" fn CloseHandle(windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) windows.DWORD;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

pub fn main(init: std.process.Init) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutable;
    const fixture = args.next() orelse return error.MissingFixture;
    const workspace = try init.gpa.alloc(u8, 2 * 1024 * 1024);
    defer init.gpa.free(workspace);
    try exact_output(init.io, workspace, fixture);
    try exact_small_output(init.io, workspace, fixture);
    try expect_limit(init.io, workspace, fixture, "overflow-out");
    try expect_limit(init.io, workspace, fixture, "overflow-err");
    try expect_owned_timeout(init.io, workspace, fixture, "living-root");
    try expect_owned_timeout(init.io, workspace, fixture, "descendant");
    try expect_collective_deadline(init.io, workspace, fixture);
}

fn exact_output(io: std.Io, workspace: []u8, fixture: []const u8) !void {
    const stream_len = 128 * 1024;
    var allocator = std.heap.FixedBufferAllocator.init(workspace);
    const output = try launch(allocator.allocator(), io, fixture, "pressure", &.{}, stream_len, .fromSeconds(5));
    defer allocator.allocator().free(output.stdout);
    defer allocator.allocator().free(output.stderr);
    try std.testing.expect(output.term.success());
    try expect_pattern(output.stdout, 'o');
    try expect_pattern(output.stderr, 'e');
}

fn exact_small_output(io: std.Io, workspace: []u8, fixture: []const u8) !void {
    var allocator = std.heap.FixedBufferAllocator.init(workspace);
    const output = try launch(allocator.allocator(), io, fixture, "interleaved", &.{}, 256, .fromSeconds(2));
    defer allocator.allocator().free(output.stdout);
    defer allocator.allocator().free(output.stderr);
    try std.testing.expect(output.term.success());
    try std.testing.expectEqualStrings("out-1\nout-2\n", output.stdout);
    try std.testing.expectEqualStrings("err-1\nerr-2\n", output.stderr);
}

fn expect_pattern(bytes: []const u8, base: u8) !void {
    try std.testing.expectEqual(@as(usize, 128 * 1024), bytes.len);
    for (bytes, 0..) |byte, index| try std.testing.expectEqual(base +% @as(u8, @truncate(index / 4096)), byte);
}

fn expect_limit(io: std.Io, workspace: []u8, fixture: []const u8, mode: []const u8) !void {
    var allocator = std.heap.FixedBufferAllocator.init(workspace);
    try std.testing.expectError(error.StreamTooLong, launch(allocator.allocator(), io, fixture, mode, &.{}, 32, .fromSeconds(5)));
}

fn expect_owned_timeout(io: std.Io, workspace: []u8, fixture: []const u8, mode: []const u8) !void {
    const mutex_name = try make_mutex_name();
    const mutex = CreateMutexW(null, .FALSE, @ptrCast(&mutex_name.wide)) orelse return error.SystemResources;
    defer _ = CloseHandle(mutex);
    var allocator = std.heap.FixedBufferAllocator.init(workspace);
    try std.testing.expectError(error.Timeout, launch(allocator.allocator(), io, fixture, mode, &.{mutex_name.ascii[0..mutex_name.len]}, 256, .fromMilliseconds(1500)));
    try std.testing.expectEqual(WAIT_ABANDONED, WaitForSingleObject(mutex, 0));
}

fn expect_collective_deadline(io: std.Io, workspace: []u8, fixture: []const u8) !void {
    const mutex_name = try make_mutex_name();
    const mutex = CreateMutexW(null, .FALSE, @ptrCast(&mutex_name.wide)) orelse return error.SystemResources;
    defer _ = CloseHandle(mutex);
    var allocator = std.heap.FixedBufferAllocator.init(workspace);
    const start = GetTickCount64();
    try std.testing.expectError(error.Timeout, launch(allocator.allocator(), io, fixture, "deadline", &.{mutex_name.ascii[0..mutex_name.len]}, 256, .fromMilliseconds(1800)));
    const elapsed = GetTickCount64() - start;
    // A fresh 1800 ms wait after the fixture's 1200 ms drain would exceed 3000 ms.
    try std.testing.expect(elapsed >= 1700 and elapsed < 2600);
    try std.testing.expectEqual(WAIT_ABANDONED, WaitForSingleObject(mutex, 0));
}

const MutexName = struct { ascii: [96]u8, wide: [128]u16, len: usize };

fn make_mutex_name() !MutexName {
    var name: MutexName = .{ .ascii = undefined, .wide = @splat(0), .len = 0 };
    const text = try std.fmt.bufPrint(&name.ascii, "Local\\warkocz-test-{d}-{d}", .{ GetCurrentProcessId(), GetTickCount64() });
    name.len = text.len;
    for (text, 0..) |byte, index| name.wide[index] = byte;
    return name;
}

fn launch(allocator: std.mem.Allocator, io: std.Io, fixture: []const u8, mode: []const u8, extra: []const []const u8, limit: usize, duration: std.Io.Duration) !std.process.RunResult {
    const argv = try allocator.alloc([]const u8, extra.len + 2);
    defer allocator.free(argv);
    argv[0] = fixture;
    argv[1] = mode;
    for (extra, 0..) |arg, index| argv[index + 2] = arg;
    return git_process.run(allocator, io, .{ .exe = .{ .explicit = .{ .dir = .cwd(), .path = fixture } }, .argv = argv, .stdout_limit = .limited(limit), .stderr_limit = .limited(limit), .timeout = .{ .duration = .{ .raw = duration, .clock = .awake } } });
}
