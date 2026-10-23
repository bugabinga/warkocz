const std = @import("std");
const windows = std.os.windows;

const SYNCHRONIZE: windows.DWORD = 0x0010_0000;
const WAIT_OBJECT_0: windows.DWORD = 0;
extern "kernel32" fn OpenMutexW(windows.DWORD, windows.BOOL, windows.LPCWSTR) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn WaitForSingleObject(windows.HANDLE, windows.DWORD) callconv(.winapi) windows.DWORD;
extern "kernel32" fn CloseHandle(windows.HANDLE) callconv(.winapi) windows.BOOL;

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    const executable = args.next() orelse return error.MissingExecutable;
    const mode = args.next() orelse return error.MissingMode;
    if (std.mem.eql(u8, mode, "interleaved")) return interleaved(init.io);
    if (std.mem.eql(u8, mode, "pressure")) return pressure(init.io);
    if (std.mem.eql(u8, mode, "overflow-out")) return overflow(init.io, true);
    if (std.mem.eql(u8, mode, "overflow-err")) return overflow(init.io, false);
    if (std.mem.eql(u8, mode, "living-root")) return held_root(init, &args);
    if (std.mem.eql(u8, mode, "descendant")) return descendant(init, executable, &args);
    if (std.mem.eql(u8, mode, "deadline")) return deadline(init, &args);
    if (std.mem.eql(u8, mode, "own-mutex")) return own_mutex(init, &args);
    if (std.mem.eql(u8, mode, "hold")) return hold(init.io);
    return error.InvalidMode;
}

fn interleaved(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io, "out-1\nout-2\n");
    try std.Io.File.stderr().writeStreamingAll(io, "err-1\nerr-2\n");
}

fn pressure(io: std.Io) !void {
    var stdout_chunk: [4096]u8 = undefined;
    var stderr_chunk: [4096]u8 = undefined;
    for (0..32) |index| {
        @memset(&stdout_chunk, 'o' +% @as(u8, @truncate(index)));
        @memset(&stderr_chunk, 'e' +% @as(u8, @truncate(index)));
        try std.Io.File.stdout().writeStreamingAll(io, &stdout_chunk);
        try std.Io.File.stderr().writeStreamingAll(io, &stderr_chunk);
    }
}

fn overflow(io: std.Io, stdout: bool) !void {
    var bytes: [256]u8 = @splat('x');
    try (if (stdout) std.Io.File.stdout() else std.Io.File.stderr()).writeStreamingAll(io, &bytes);
}

fn held_root(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    try acquire_mutex(init.gpa, args.next() orelse return error.MissingMutex);
    close_streams(init.io);
    try hold(init.io);
}

fn descendant(init: std.process.Init, executable: []const u8, args: *std.process.Args.Iterator) !void {
    const mutex_name = args.next() orelse return error.MissingMutex;
    const argv = [_][]const u8{ executable, "own-mutex", mutex_name };
    _ = try std.process.spawn(init.io, .{ .exe = .{ .explicit = .{ .dir = .cwd(), .path = executable } }, .argv = &argv, .stdin = .ignore, .stdout = .inherit, .stderr = .inherit, .create_no_window = true });
    // Root exits; descendant still owns inherited streams until supervisor kills its job.
}

fn deadline(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    try acquire_mutex(init.gpa, args.next() orelse return error.MissingMutex);
    try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(1200), .clock = .awake }, init.io);
    close_streams(init.io);
    try hold(init.io);
}

fn own_mutex(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    try acquire_mutex(init.gpa, args.next() orelse return error.MissingMutex);
    try hold(init.io);
}

fn acquire_mutex(allocator: std.mem.Allocator, name: []const u8) !void {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
    defer allocator.free(wide);
    const mutex = OpenMutexW(SYNCHRONIZE, .FALSE, wide.ptr) orelse return error.MutexOpenFailed;
    defer _ = CloseHandle(mutex);
    if (WaitForSingleObject(mutex, 0) != WAIT_OBJECT_0) return error.MutexWaitFailed;
    // Parent retains another handle; closing this handle does not release thread ownership.
}

fn close_streams(io: std.Io) void {
    std.Io.File.stdout().close(io);
    std.Io.File.stderr().close(io);
}

fn hold(io: std.Io) !void {
    try std.Io.Clock.Duration.sleep(.{ .raw = .fromSeconds(30), .clock = .awake }, io);
}
