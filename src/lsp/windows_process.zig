const builtin = @import("builtin");
const std = @import("std");

const windows_command_units = 32_767;

/// Caller-owned reusable Windows launch storage, sized by Win32's command-line limit.
pub const SpawnScratch = struct {
    command_utf8: [windows_command_units]u8 = undefined,
    command: [windows_command_units]u16 = undefined,
    application: [windows_command_units]u16 = undefined,
    workspace: [windows_command_units]u16 = undefined,
    attributes: [windows_command_units]u8 align(@alignOf(usize)) = undefined,
};

pub const Child = if (builtin.os.tag == .windows) WindowsChild else PosixChild;
pub const WriteError = error{ Timeout, Failed };
pub const ReadError = error{ Timeout, Failed };

/// Reads at most `bytes.len`; Windows drains cancelled overlapped completion before returning.
pub fn read_some(io: std.Io, pipe: std.Io.File, bytes: []u8, deadline: ?std.Io.Clock.Timestamp) ReadError!usize {
    if (bytes.len == 0) return error.Failed;
    if (builtin.os.tag == .windows) return WindowsChild.read_some(io, pipe, bytes, deadline);
    const data = [_][]u8{bytes};
    const result = if (deadline) |value|
        std.Io.operateTimeout(io, .{ .file_read_streaming = .{ .file = pipe, .data = &data } }, .{ .deadline = value }) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            else => return error.Failed,
        }
    else
        std.Io.operate(io, .{ .file_read_streaming = .{ .file = pipe, .data = &data } }) catch return error.Failed;
    const count = result.file_read_streaming catch return error.Failed;
    if (count > bytes.len) return error.Failed;
    return count;
}

/// Windows uses cancellable overlapped named-pipe writes; other platforms retain std.Io semantics.
pub fn write_all(io: std.Io, pipe: std.Io.File, bytes: []const u8, deadline: std.Io.Clock.Timestamp) WriteError!void {
    if (builtin.os.tag == .windows) return WindowsChild.write_all(io, pipe, bytes, deadline);
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (!std.Io.Clock.Timestamp.now(io, deadline.clock).compare(.lt, deadline)) return error.Timeout;
        const data = [_][]const u8{bytes[offset..]};
        const result = std.Io.operateTimeout(io, .{ .file_write_streaming = .{ .file = pipe, .data = &data } }, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            else => return error.Failed,
        };
        const count = result.file_write_streaming catch return error.Failed;
        if (count == 0 or count > bytes.len - offset) return error.Failed;
        offset += count;
    }
}

/// Cancels every outstanding parent write on this handle; its owner still drains completion.
pub fn cancel_write(pipe: std.Io.File) void {
    if (builtin.os.tag == .windows) WindowsChild.cancel_write(pipe);
}

/// Cancels the current parent read so a new lifecycle deadline can take effect.
pub fn cancel_read(pipe: std.Io.File) void {
    if (builtin.os.tag == .windows) WindowsChild.cancel_read(pipe);
}

pub fn spawn(io: std.Io, executable: []const u8, argv: []const []const u8, workspace: []const u8, scratch: *SpawnScratch) !Child {
    if (builtin.os.tag == .windows) return WindowsChild.spawn(executable, argv, workspace, scratch);
    return .{ .child = try std.process.spawn(io, .{
        .exe = .{ .explicit = .{ .dir = .cwd(), .path = executable } },
        .argv = argv,
        .cwd = .{ .path = workspace },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .create_no_window = true,
    }) };
}

const PosixChild = struct {
    child: std.process.Child,

    pub fn stdin(self: *PosixChild) std.Io.File {
        return self.child.stdin.?;
    }
    pub fn stdout(self: *PosixChild) std.Io.File {
        return self.child.stdout.?;
    }
    pub fn detach_pipes(self: *PosixChild) void {
        self.child.stdin = null;
        self.child.stdout = null;
    }
    pub fn terminate(self: *PosixChild, io: std.Io) void {
        self.child.kill(io);
    }
};

const WindowsChild = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const HANDLE_LIST_ATTRIBUTE: usize = 0x0002_0002;
    const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION: u32 = 9;
    const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x0000_2000;
    const BasicLimit = extern struct { per_process: i64 = 0, per_job: i64 = 0, flags: u32 = 0, minimum_working_set: usize = 0, maximum_working_set: usize = 0, active_process_limit: u32 = 0, affinity: usize = 0, priority_class: u32 = 0, scheduling_class: u32 = 0 };
    const ExtendedLimit = extern struct { basic: BasicLimit = .{}, io: [48]u8 = @splat(0), process_memory_limit: usize = 0, job_memory_limit: usize = 0, peak_process_memory_used: usize = 0, peak_job_memory_used: usize = 0 };
    const StartupInfoEx = extern struct { startup: windows.STARTUPINFOW, attributes: ?*anyopaque };

    child: std.process.Child,
    job: windows.HANDLE,

    const ERROR_IO_PENDING: windows.DWORD = 997;
    const ERROR_PIPE_CONNECTED: windows.DWORD = 535;
    const WAIT_OBJECT_0: windows.DWORD = 0;
    const WAIT_TIMEOUT: windows.DWORD = 258;
    const INFINITE: windows.DWORD = 0xffff_ffff;
    const PIPE_ACCESS_INBOUND: windows.DWORD = 0x0000_0001;
    const PIPE_ACCESS_OUTBOUND: windows.DWORD = 0x0000_0002;
    const FILE_FLAG_OVERLAPPED: windows.DWORD = 0x4000_0000;
    const PIPE_TYPE_BYTE: windows.DWORD = 0;
    const PIPE_WAIT: windows.DWORD = 0;
    const PIPE_REJECT_REMOTE_CLIENTS: windows.DWORD = 0x0000_0008;
    const GENERIC_READ: windows.DWORD = 0x8000_0000;
    const OPEN_EXISTING: windows.DWORD = 3;
    const Overlapped = extern struct { internal: usize = 0, internal_high: usize = 0, offset: extern union { value: windows.DWORD, pair: extern struct { offset: windows.DWORD, offset_high: windows.DWORD } } = .{ .value = 0 }, event: ?windows.HANDLE = null };

    extern "kernel32" fn CreatePipe(*windows.HANDLE, *windows.HANDLE, ?*windows.SECURITY_ATTRIBUTES, windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetHandleInformation(windows.HANDLE, windows.DWORD, windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CreateJobObjectW(?*windows.SECURITY_ATTRIBUTES, ?windows.LPCWSTR) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn SetInformationJobObject(windows.HANDLE, u32, ?*const anyopaque, windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn AssignProcessToJobObject(windows.HANDLE, windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn TerminateJobObject(windows.HANDLE, windows.UINT) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn TerminateProcess(windows.HANDLE, windows.UINT) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn ResumeThread(windows.HANDLE) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn InitializeProcThreadAttributeList(?*anyopaque, windows.DWORD, windows.DWORD, *usize) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn UpdateProcThreadAttribute(?*anyopaque, windows.DWORD, usize, ?*const anyopaque, usize, ?*anyopaque, ?*usize) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn DeleteProcThreadAttributeList(*anyopaque) callconv(.winapi) void;
    extern "kernel32" fn CreateFileW(windows.LPCWSTR, windows.DWORD, windows.DWORD, ?*windows.SECURITY_ATTRIBUTES, windows.DWORD, windows.DWORD, ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn CreateNamedPipeW(windows.LPCWSTR, windows.DWORD, windows.DWORD, windows.DWORD, windows.DWORD, windows.DWORD, windows.DWORD, ?*windows.SECURITY_ATTRIBUTES) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn ConnectNamedPipe(windows.HANDLE, ?*Overlapped) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CreateEventW(?*windows.SECURITY_ATTRIBUTES, windows.BOOL, windows.BOOL, ?windows.LPCWSTR) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn ResetEvent(windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WaitForSingleObject(windows.HANDLE, windows.DWORD) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn ReadFile(windows.HANDLE, ?*anyopaque, windows.DWORD, ?*windows.DWORD, ?*Overlapped) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WriteFile(windows.HANDLE, ?*const anyopaque, windows.DWORD, ?*windows.DWORD, ?*Overlapped) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetOverlappedResult(windows.HANDLE, *Overlapped, *windows.DWORD, windows.BOOL) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CancelIoEx(windows.HANDLE, ?*Overlapped) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
    extern "bcrypt" fn BCryptGenRandom(?windows.HANDLE, [*]u8, windows.ULONG, windows.ULONG) callconv(.winapi) windows.NTSTATUS;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) windows.DWORD;

    fn spawn(executable: []const u8, argv: []const []const u8, workspace: []const u8, scratch: *SpawnScratch) !WindowsChild {
        std.debug.assert(argv.len > 0);
        var pipes = try make_pipes();
        errdefer close_pipes(&pipes);
        const command = try command_line(argv, scratch);
        const app = try wide_z(executable, &scratch.application);
        const cwd = try wide_z(workspace, &scratch.workspace);
        const job = try make_job();
        errdefer windows.CloseHandle(job);
        var process: windows.PROCESS.INFORMATION = undefined;
        try create_suspended(app, command, cwd, pipes, scratch, &process);
        var handed_off = false;
        errdefer if (!handed_off) terminate_process(process);
        close_handle(&pipes.stdin_read);
        close_handle(&pipes.stdout_write);
        close_handle(&pipes.stderr);
        if (!AssignProcessToJobObject(job, process.hProcess).toBool()) return error.AssignJobFailed;
        if (ResumeThread(process.hThread) == std.math.maxInt(windows.DWORD)) return error.ResumeFailed;
        handed_off = true;
        return .{ .child = .{ .id = process.hProcess, .thread_handle = process.hThread, .stdin = file(pipes.stdin_write), .stdout = file(pipes.stdout_read), .stderr = null, .request_resource_usage_statistics = false }, .job = job };
    }

    pub fn stdin(self: *WindowsChild) std.Io.File {
        return self.child.stdin.?;
    }
    pub fn stdout(self: *WindowsChild) std.Io.File {
        return self.child.stdout.?;
    }
    pub fn detach_pipes(self: *WindowsChild) void {
        self.child.stdin = null;
        self.child.stdout = null;
    }
    pub fn terminate(self: *WindowsChild, io: std.Io) void {
        if (self.job != windows.INVALID_HANDLE_VALUE) {
            _ = TerminateJobObject(self.job, 1);
            windows.CloseHandle(self.job);
            self.job = windows.INVALID_HANDLE_VALUE;
        }
        self.child.kill(io);
    }

    const Pipes = struct { stdin_read: windows.HANDLE, stdin_write: windows.HANDLE, stdout_read: windows.HANDLE, stdout_write: windows.HANDLE, stderr: windows.HANDLE };

    fn make_pipes() !Pipes {
        var attributes = windows.SECURITY_ATTRIBUTES{ .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = .TRUE };
        var pipes = Pipes{ .stdin_read = windows.INVALID_HANDLE_VALUE, .stdin_write = windows.INVALID_HANDLE_VALUE, .stdout_read = windows.INVALID_HANDLE_VALUE, .stdout_write = windows.INVALID_HANDLE_VALUE, .stderr = windows.INVALID_HANDLE_VALUE };
        try make_stdin_pipe(&pipes.stdin_read, &pipes.stdin_write, &attributes);
        errdefer close_pipes(&pipes);
        try make_stdout_pipe(&pipes.stdout_read, &pipes.stdout_write, &attributes);
        const nul = std.unicode.wtf8ToWtf16LeStringLiteral("NUL");
        pipes.stderr = CreateFileW(nul, 0x4000_0000, 3, &attributes, 3, 0x80, null);
        if (pipes.stderr == windows.INVALID_HANDLE_VALUE) return error.PipeFailed;
        if (!SetHandleInformation(pipes.stdout_read, 1, 0).toBool()) return error.PipeFailed;
        return pipes;
    }

    /// Connect parent endpoint before launch: only this inherited client can read it.
    fn make_stdin_pipe(read: *windows.HANDLE, write: *windows.HANDLE, inherited: *windows.SECURITY_ATTRIBUTES) !void {
        var random: u64 = undefined;
        if (BCryptGenRandom(null, std.mem.asBytes(&random).ptr, @sizeOf(u64), 0x0000_0002) != .SUCCESS) return error.PipeFailed;
        var utf8: [96]u8 = undefined;
        const name = std.fmt.bufPrint(&utf8, "\\\\.\\pipe\\warkocz-lsp-{x}-{x}", .{ GetCurrentProcessId(), random }) catch return error.PipeFailed;
        var wide: [96]u16 = undefined;
        const path = try wide_z(name, &wide);
        write.* = CreateNamedPipeW(path.ptr, PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED, PIPE_TYPE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 4096, 4096, 0, null);
        if (write.* == windows.INVALID_HANDLE_VALUE) return error.PipeFailed;
        errdefer close_handle(write);
        read.* = CreateFileW(path.ptr, GENERIC_READ, 0, inherited, OPEN_EXISTING, 0, null);
        if (read.* == windows.INVALID_HANDLE_VALUE) return error.PipeFailed;
        if (!ConnectNamedPipe(write.*, null).toBool() and GetLastError() != ERROR_PIPE_CONNECTED) return error.PipeFailed;
    }

    /// Child receives only synchronous write endpoint; parent owns cancellable overlapped read endpoint.
    fn make_stdout_pipe(read: *windows.HANDLE, write: *windows.HANDLE, inherited: *windows.SECURITY_ATTRIBUTES) !void {
        var random: u64 = undefined;
        if (BCryptGenRandom(null, std.mem.asBytes(&random).ptr, @sizeOf(u64), 0x0000_0002) != .SUCCESS) return error.PipeFailed;
        var utf8: [96]u8 = undefined;
        const name = std.fmt.bufPrint(&utf8, "\\\\.\\pipe\\warkocz-lsp-out-{x}-{x}", .{ GetCurrentProcessId(), random }) catch return error.PipeFailed;
        var wide: [96]u16 = undefined;
        const path = try wide_z(name, &wide);
        read.* = CreateNamedPipeW(path.ptr, PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED, PIPE_TYPE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 4096, 4096, 0, null);
        if (read.* == windows.INVALID_HANDLE_VALUE) return error.PipeFailed;
        errdefer close_handle(read);
        write.* = CreateFileW(path.ptr, 0x4000_0000, 0, inherited, OPEN_EXISTING, 0, null);
        if (write.* == windows.INVALID_HANDLE_VALUE) return error.PipeFailed;
        if (!ConnectNamedPipe(read.*, null).toBool() and GetLastError() != ERROR_PIPE_CONNECTED) return error.PipeFailed;
    }

    pub fn cancel_write(pipe: std.Io.File) void {
        _ = CancelIoEx(pipe.handle, null);
    }

    pub fn cancel_read(pipe: std.Io.File) void {
        _ = CancelIoEx(pipe.handle, null);
    }

    pub fn read_some(io: std.Io, pipe: std.Io.File, bytes: []u8, deadline: ?std.Io.Clock.Timestamp) ReadError!usize {
        if (bytes.len == 0 or bytes.len > std.math.maxInt(windows.DWORD)) return error.Failed;
        const event = CreateEventW(null, .TRUE, .FALSE, null) orelse return error.Failed;
        defer windows.CloseHandle(event);
        return read_once(io, pipe.handle, bytes, deadline, event);
    }

    /// Cancellation completion is drained before caller-owned `bytes` can leave scope.
    fn read_once(io: std.Io, handle: windows.HANDLE, bytes: []u8, deadline: ?std.Io.Clock.Timestamp, event: windows.HANDLE) ReadError!usize {
        if (deadline) |value| if (!std.Io.Clock.Timestamp.now(io, value.clock).compare(.lt, value)) return error.Timeout;
        if (!ResetEvent(event).toBool()) return error.Failed;
        var overlapped = Overlapped{ .event = event };
        var count: windows.DWORD = 0;
        if (ReadFile(handle, bytes.ptr, @intCast(bytes.len), &count, &overlapped).toBool()) return completed_read(handle, &overlapped, bytes.len);
        if (GetLastError() != ERROR_IO_PENDING) return error.Failed;
        const wait = WaitForSingleObject(event, if (deadline) |value| deadline_milliseconds(io, value) else INFINITE);
        if (wait == WAIT_OBJECT_0) return completed_read(handle, &overlapped, bytes.len);
        _ = CancelIoEx(handle, &overlapped);
        _ = GetOverlappedResult(handle, &overlapped, &count, .TRUE);
        if (wait == WAIT_TIMEOUT) return error.Timeout;
        return error.Failed;
    }

    fn completed_read(handle: windows.HANDLE, overlapped: *Overlapped, limit: usize) ReadError!usize {
        var count: windows.DWORD = 0;
        if (!GetOverlappedResult(handle, overlapped, &count, .FALSE).toBool()) return error.Failed;
        if (count > limit) return error.Failed;
        return count;
    }

    pub fn write_all(io: std.Io, pipe: std.Io.File, bytes: []const u8, deadline: std.Io.Clock.Timestamp) WriteError!void {
        if (bytes.len == 0 or bytes.len > std.math.maxInt(windows.DWORD)) return error.Failed;
        const event = CreateEventW(null, .TRUE, .FALSE, null) orelse return error.Failed;
        defer windows.CloseHandle(event);
        var offset: usize = 0;
        while (offset < bytes.len) offset += try write_once(io, pipe.handle, bytes[offset..], deadline, event);
        if (!std.Io.Clock.Timestamp.now(io, deadline.clock).compare(.lt, deadline)) return error.Timeout;
    }

    /// Completion is always drained before returning, so Windows cannot retain caller bytes.
    fn write_once(io: std.Io, handle: windows.HANDLE, bytes: []const u8, deadline: std.Io.Clock.Timestamp, event: windows.HANDLE) WriteError!usize {
        if (bytes.len == 0 or !std.Io.Clock.Timestamp.now(io, deadline.clock).compare(.lt, deadline)) return error.Timeout;
        if (!ResetEvent(event).toBool()) return error.Failed;
        var overlapped = Overlapped{ .event = event };
        var written: windows.DWORD = 0;
        if (WriteFile(handle, bytes.ptr, @intCast(bytes.len), &written, &overlapped).toBool()) return completed_write(handle, &overlapped, bytes.len);
        if (GetLastError() != ERROR_IO_PENDING) return error.Failed;
        const wait = WaitForSingleObject(event, deadline_milliseconds(io, deadline));
        if (wait == WAIT_OBJECT_0) {
            const count = completed_write(handle, &overlapped, bytes.len) catch return error.Failed;
            if (!std.Io.Clock.Timestamp.now(io, deadline.clock).compare(.lt, deadline)) return error.Timeout;
            return count;
        }
        _ = CancelIoEx(handle, &overlapped);
        _ = GetOverlappedResult(handle, &overlapped, &written, .TRUE);
        if (wait == WAIT_TIMEOUT) return error.Timeout;
        return error.Failed;
    }

    fn completed_write(handle: windows.HANDLE, overlapped: *Overlapped, limit: usize) WriteError!usize {
        var written: windows.DWORD = 0;
        if (!GetOverlappedResult(handle, overlapped, &written, .FALSE).toBool()) return error.Failed;
        if (written == 0 or written > limit) return error.Failed;
        return written;
    }

    fn deadline_milliseconds(io: std.Io, deadline: std.Io.Clock.Timestamp) windows.DWORD {
        const remaining = std.Io.Clock.Timestamp.now(io, deadline.clock).durationTo(deadline).raw.nanoseconds;
        if (remaining <= 0) return 0;
        const milliseconds = @divFloor(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        return @intCast(@min(milliseconds, @as(i96, INFINITE - 1)));
    }
    fn close_pipes(pipes: *Pipes) void {
        close_handle(&pipes.stdin_read);
        close_handle(&pipes.stdin_write);
        close_handle(&pipes.stdout_read);
        close_handle(&pipes.stdout_write);
        close_handle(&pipes.stderr);
    }
    fn close_handle(handle: *windows.HANDLE) void {
        if (handle.* == windows.INVALID_HANDLE_VALUE) return;
        windows.CloseHandle(handle.*);
        handle.* = windows.INVALID_HANDLE_VALUE;
    }
    fn make_job() !windows.HANDLE {
        const job = CreateJobObjectW(null, null) orelse return error.JobFailed;
        var limits = ExtendedLimit{};
        limits.basic.flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (!SetInformationJobObject(job, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION, &limits, @sizeOf(ExtendedLimit)).toBool()) {
            windows.CloseHandle(job);
            return error.JobFailed;
        }
        return job;
    }
    fn create_suspended(app: [:0]u16, command: [:0]u16, cwd: [:0]u16, pipes: Pipes, scratch: *SpawnScratch, process: *windows.PROCESS.INFORMATION) !void {
        var bytes: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &bytes);
        if (bytes == 0 or bytes > scratch.attributes.len) return error.AttributeListFailed;
        const list: *anyopaque = @ptrCast(&scratch.attributes);
        if (!InitializeProcThreadAttributeList(list, 1, 0, &bytes).toBool()) return error.AttributeListFailed;
        defer DeleteProcThreadAttributeList(list);
        const handles = [_]windows.HANDLE{ pipes.stdin_read, pipes.stdout_write, pipes.stderr };
        if (!UpdateProcThreadAttribute(list, 0, HANDLE_LIST_ATTRIBUTE, &handles, @sizeOf(@TypeOf(handles)), null, null).toBool()) return error.AttributeListFailed;
        var startup = StartupInfoEx{ .startup = std.mem.zeroes(windows.STARTUPINFOW), .attributes = list };
        startup.startup.cb = @sizeOf(StartupInfoEx);
        startup.startup.dwFlags = windows.STARTF_USESTDHANDLES;
        startup.startup.hStdInput = pipes.stdin_read;
        startup.startup.hStdOutput = pipes.stdout_write;
        startup.startup.hStdError = pipes.stderr;
        const flags: windows.CreateProcessFlags = .{ .create_suspended = true, .create_no_window = true, .extended_startupinfo_present = true, .create_unicode_environment = true };
        if (!windows.kernel32.CreateProcessW(app.ptr, command.ptr, null, null, .TRUE, flags, null, cwd.ptr, @ptrCast(&startup.startup), process).toBool()) return error.CreateProcessFailed;
    }
    fn terminate_process(process: windows.PROCESS.INFORMATION) void {
        _ = TerminateProcess(process.hProcess, 1);
        windows.CloseHandle(process.hThread);
        windows.CloseHandle(process.hProcess);
    }
    fn file(handle: windows.HANDLE) std.Io.File {
        return .{ .handle = handle, .flags = .{ .nonblocking = false } };
    }
    fn wide_z(input: []const u8, output: []u16) ![:0]u16 {
        if (std.mem.indexOfScalar(u8, input, 0) != null) return error.InvalidArgument;
        if (input.len >= output.len) return error.ArgumentTooLong;
        const length = try std.unicode.wtf8ToWtf16Le(output[0 .. output.len - 1], input);
        output[length] = 0;
        return output[0..length :0];
    }
    fn command_line(argv: []const []const u8, scratch: *SpawnScratch) ![:0]u16 {
        var length: usize = 0;
        for (argv, 0..) |arg, index| {
            if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidArgument;
            if (index != 0) try append_byte(&scratch.command_utf8, &length, ' ');
            if (index == 0) try append_argv0(&scratch.command_utf8, &length, arg) else try append_arg(&scratch.command_utf8, &length, arg);
        }
        return wide_z(scratch.command_utf8[0..length], &scratch.command);
    }
    fn append_argv0(output: []u8, length: *usize, arg: []const u8) !void {
        const quote = std.mem.indexOfAny(u8, arg, " \t") != null;
        if (std.mem.indexOfScalar(u8, arg, '"') != null) return error.InvalidArgument;
        if (quote) try append_byte(output, length, '"');
        try append_slice(output, length, arg);
        if (quote) try append_byte(output, length, '"');
    }
    fn append_arg(output: []u8, length: *usize, arg: []const u8) !void {
        const quote = arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t\"") != null;
        if (!quote) return append_slice(output, length, arg);
        try append_byte(output, length, '"');
        var slashes: usize = 0;
        for (arg) |byte| switch (byte) {
            '\\' => slashes += 1,
            '"' => {
                try append_n(output, length, '\\', slashes * 2 + 1);
                try append_byte(output, length, '"');
                slashes = 0;
            },
            else => {
                try append_n(output, length, '\\', slashes);
                try append_byte(output, length, byte);
                slashes = 0;
            },
        };
        try append_n(output, length, '\\', slashes * 2);
        try append_byte(output, length, '"');
    }
    fn append_slice(output: []u8, length: *usize, bytes: []const u8) !void {
        if (bytes.len > output.len - length.*) return error.ArgumentTooLong;
        @memcpy(output[length.*..][0..bytes.len], bytes);
        length.* += bytes.len;
    }
    fn append_n(output: []u8, length: *usize, byte: u8, count: usize) !void {
        if (count > output.len - length.*) return error.ArgumentTooLong;
        @memset(output[length.*..][0..count], byte);
        length.* += count;
    }
    fn append_byte(output: []u8, length: *usize, byte: u8) !void {
        if (length.* == output.len) return error.ArgumentTooLong;
        output[length.*] = byte;
        length.* += 1;
    }
} else struct {};

test "Windows command quoting preserves argv0 and normal argument boundaries" {
    if (builtin.os.tag != .windows) return;
    var output: [128]u8 = undefined;
    var length: usize = 0;
    try WindowsChild.append_argv0(&output, &length, "C:\\with space\\server.exe");
    try std.testing.expectEqualStrings("\"C:\\with space\\server.exe\"", output[0..length]);
    length = 0;
    try WindowsChild.append_arg(&output, &length, "space value");
    try std.testing.expectEqualStrings("\"space value\"", output[0..length]);
    length = 0;
    try WindowsChild.append_arg(&output, &length, "quote\"value");
    try std.testing.expectEqualStrings("\"quote\\\"value\"", output[0..length]);
    length = 0;
    try WindowsChild.append_arg(&output, &length, "trailing \\");
    try std.testing.expectEqualStrings("\"trailing \\\\\"", output[0..length]);
    var scratch = SpawnScratch{};
    try std.testing.expectError(error.InvalidArgument, WindowsChild.command_line(&.{ "server", "nul\x00argument" }, &scratch));
    length = 0;
    try std.testing.expectError(error.InvalidArgument, WindowsChild.append_argv0(&output, &length, "bad\"argv0"));
}
