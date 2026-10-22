const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const recovery = @import("recovery.zig");
const discovery = @import("recovery_discovery.zig");
const directory = @import("recovery_directory.zig");

const Handle = windows.HANDLE;
const invalid_handle = windows.INVALID_HANDLE_VALUE;
const attribute_reparse_point: u32 = 0x400;
const file_disposition_info: u32 = 4;

const FileAttributeTagInfo = extern struct { attributes: u32, reparse_tag: u32 };
const FileDispositionInfo = extern struct { delete_file: i32 };

extern "kernel32" fn CloseHandle(handle: Handle) callconv(.winapi) i32;
extern "kernel32" fn GetFileInformationByHandleEx(handle: Handle, class: u32, info: *anyopaque, size: u32) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(handle: Handle, buffer: [*]u8, length: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetFileSizeEx(handle: Handle, size: *i64) callconv(.winapi) i32;
extern "kernel32" fn SetFileInformationByHandle(handle: Handle, class: u32, info: *const anyopaque, size: u32) callconv(.winapi) i32;

pub const Storage = struct {
    ciphertext: []u8,
    plaintext: []u8,
    path_scratch: []u16,
    token_scratch: []align(8) u8,
    session_path: []u8,
};

pub const Error = error{ UnsupportedPlatform, InvalidSelection, ScratchTooSmall, OpenFailure, NotRegularFile, ReadFailure, ChangedRecord, DeleteFailure } || directory.Error || recovery.Error;

/// Revalidates selected discovered bytes, decrypts and verifies generation, then marks that opened handle for deletion.
/// Success means OS deletion request and final handle close succeeded, not crash-durable erasure.
/// All filesystem and cryptographic work belongs on a worker thread.
pub fn forget(root: []const u8, candidate: discovery.Candidate, storage: Storage) Error!void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    if (storage.ciphertext.len < recovery.Controller.ciphertext_capacity or storage.plaintext.len < recovery.Controller.plaintext_capacity or storage.path_scratch.len < std.os.windows.NAME_MAX or storage.token_scratch.len < 1024 or storage.session_path.len < root.len + 1 + candidate.session_name.len) return error.ScratchTooSmall;
    if (candidate.path_len == 0 or candidate.path_len > candidate.path.len) return error.InvalidSelection;
    const path = candidate.path[0..candidate.path_len];
    const session_name = candidate.session_name[0..40];
    if (!valid_session(session_name)) return error.InvalidSelection;
    const session_path = std.fmt.bufPrint(storage.session_path, "{s}/{s}", .{ root, session_name }) catch return error.ScratchTooSmall;
    const file_name = selected_filename(path, root, session_name) orelse return error.InvalidSelection;
    var owned = try directory.open_existing(session_path, storage.path_scratch, storage.token_scratch);
    defer directory.close(&owned);

    const handle = try open_selected(owned.handle, file_name);
    var handle_open = true;
    defer {
        if (handle_open) _ = CloseHandle(handle);
    }

    var tag = FileAttributeTagInfo{ .attributes = 0, .reparse_tag = 0 };
    if (GetFileInformationByHandleEx(handle, 9, &tag, @sizeOf(FileAttributeTagInfo)) == 0 or tag.attributes & attribute_reparse_point != 0 or tag.attributes & 0x10 != 0) return error.NotRegularFile;
    var size: i64 = 0;
    if (GetFileSizeEx(handle, &size) == 0) return error.ReadFailure;
    if (size < 0 or size > storage.ciphertext.len) return error.ChangedRecord;
    const expected_size: usize = @intCast(size);
    var read_total: usize = 0;
    while (read_total < expected_size) {
        var read_now: u32 = 0;
        const remaining: u32 = @intCast(@min(expected_size - read_total, std.math.maxInt(u32)));
        if (ReadFile(handle, storage.ciphertext[read_total..].ptr, remaining, &read_now, null) == 0 or read_now == 0) return error.ReadFailure;
        read_total += read_now;
    }
    var extra: [1]u8 = undefined;
    var extra_len: u32 = 0;
    if (ReadFile(handle, &extra, 1, &extra_len, null) == 0 or extra_len != 0) return error.ChangedRecord;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(storage.ciphertext[0..read_total], &digest, .{});
    if (!std.mem.eql(u8, &digest, &candidate.ciphertext_digest)) return error.ChangedRecord;
    const decoded = try recovery.decode(storage.ciphertext[0..read_total], storage.plaintext);
    defer recovery.wipe(storage.plaintext);
    if (decoded.generation != candidate.generation or decoded.mode != candidate.mode or decoded.result.len != candidate.result_len or filename_generation(file_name) != candidate.generation) return error.ChangedRecord;
    var disposition = FileDispositionInfo{ .delete_file = 1 };
    if (SetFileInformationByHandle(handle, file_disposition_info, &disposition, @sizeOf(FileDispositionInfo)) == 0) return error.DeleteFailure;
    if (CloseHandle(handle) == 0) {
        handle_open = false;
        return error.DeleteFailure;
    }
    handle_open = false;
}

/// Opens one validated direct child through a stable verified parent handle.
fn open_selected(parent: Handle, name: []const u8) Error!Handle {
    if (!valid_filename(name)) return error.InvalidSelection;
    var name_w: [windows.NAME_MAX]u16 = undefined;
    const name_len = windows.wtf8ToWtf16Le(&name_w, name) catch return error.InvalidSelection;
    var object_name = windows.UNICODE_STRING.init(name_w[0..name_len]);
    const attributes: windows.OBJECT.ATTRIBUTES = .{ .RootDirectory = parent, .ObjectName = &object_name };
    var status_block: windows.IO_STATUS_BLOCK = undefined;
    var handle: Handle = undefined;
    const status = windows.ntdll.NtCreateFile(&handle, .{ .STANDARD = .{ .RIGHTS = .{ .DELETE = true }, .SYNCHRONIZE = true }, .GENERIC = .{ .READ = true } }, &attributes, &status_block, null, .{ .NORMAL = true }, .{}, .OPEN, .{ .OPEN_REPARSE_POINT = true, .NON_DIRECTORY_FILE = true, .IO = .SYNCHRONOUS_NONALERT }, null, 0);
    if (status != .SUCCESS) return error.OpenFailure;
    std.debug.assert(handle != invalid_handle);
    return handle;
}

fn valid_session(name: []const u8) bool {
    if (name.len != 40 or !std.mem.startsWith(u8, name, "session-")) return false;
    for (name[8..]) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn selected_filename(path: []const u8, root: []const u8, session_name: []const u8) ?[]const u8 {
    if (path.len <= root.len or !std.mem.startsWith(u8, path, root)) return null;
    var suffix = path[root.len..];
    if (suffix[0] != '/' and suffix[0] != '\\') return null;
    suffix = suffix[1..];
    if (suffix.len <= session_name.len or !std.mem.startsWith(u8, suffix, session_name)) return null;
    suffix = suffix[session_name.len..];
    if (suffix[0] != '/' and suffix[0] != '\\') return null;
    const name = suffix[1..];
    if (!valid_filename(name)) return null;
    return name;
}

fn valid_filename(name: []const u8) bool {
    if (name.len == 0 or name.len >= windows.NAME_MAX or std.mem.indexOfAny(u8, name, "/\\:\x00") != null) return false;
    return filename_generation(name) != null;
}

fn filename_generation(name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, name, "recovery-") or !std.mem.endsWith(u8, name, ".bin")) return null;
    const body = name[9 .. name.len - 4];
    const first = std.mem.indexOfScalar(u8, body, '-') orelse return null;
    const rest = body[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, '-') orelse return null;
    if (first == 0 or second == 0 or second + 1 == rest.len) return null;
    return std.fmt.parseInt(u64, rest[0..second], 10) catch null;
}

test "retention opened parent survives path replacement without redirecting deletion" {
    if (comptime builtin.os.tag != .windows) return;
    const flag = (std.process.Environ{ .block = .global }).getAlloc(std.testing.allocator, "WARKOCZ_NATIVE_E2E") catch return;
    defer std.testing.allocator.free(flag);
    if (!std.mem.eql(u8, flag, "1")) return;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e";
    try cwd.createDirPath(io, root);
    var nonce: u64 = undefined;
    try io.randomSecure(std.mem.asBytes(&nonce));
    var path: [256]u8 = undefined;
    const fixture = try std.fmt.bufPrint(&path, "{s}/retention-parent-{x}", .{ root, nonce });
    try cwd.createDir(io, fixture, .default_dir);
    defer cwd.deleteTree(io, fixture) catch {};
    const dir = try cwd.openDir(io, fixture, .{ .access_sub_paths = true });
    defer dir.close(io);
    try dir.createDir(io, "selected", .default_dir);
    try dir.createDir(io, "replacement", .default_dir);
    const name = "recovery-owned-3-1.bin";
    try dir.writeFile(io, .{ .sub_path = "selected/" ++ name, .data = "owned" });
    try dir.writeFile(io, .{ .sub_path = "replacement/" ++ name, .data = "unrelated" });
    const parent = try dir.openDir(io, "selected", .{ .access_sub_paths = true, .follow_symlinks = false });
    defer parent.close(io);
    try dir.rename("selected", dir, "moved", io);
    try dir.rename("replacement", dir, "selected", io);
    const handle = try open_selected(parent.handle, name);
    {
        defer _ = CloseHandle(handle);
        var bytes: [16]u8 = undefined;
        var count: u32 = 0;
        if (ReadFile(handle, &bytes, bytes.len, &count, null) == 0) return error.ReadFailure;
        try std.testing.expectEqualStrings("owned", bytes[0..count]);
        var disposition = FileDispositionInfo{ .delete_file = 1 };
        if (SetFileInformationByHandle(handle, file_disposition_info, &disposition, @sizeOf(FileDispositionInfo)) == 0) return error.DeleteFailure;
    }
    try std.testing.expectError(error.FileNotFound, dir.statFile(io, "moved/" ++ name, .{}));
    const retained = try dir.readFileAlloc(io, "selected/" ++ name, std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(retained);
    try std.testing.expectEqualStrings("unrelated", retained);
}

test "retention selection binds candidate to exact session file path" {
    const session_name = "session-0123456789abcdef0123456789abcdef";
    try std.testing.expect(selected_filename("C:/root/session-0123456789abcdef0123456789abcdef/recovery-a-3-1.bin", "C:/root", session_name) != null);
    try std.testing.expect(selected_filename("C:/root/session-0123456789abcdef0123456789abcdef/other.bin", "C:/root", session_name) == null);
    try std.testing.expect(selected_filename("C:/root/session-0123456789abcdef0123456789abcdef/../recovery-a-3-1.bin", "C:/root", session_name) == null);
    try std.testing.expect(selected_filename("C:/root-foreign/session-0123456789abcdef0123456789abcdef/recovery-a-3-1.bin", "C:/root", session_name) == null);
    try std.testing.expect(selected_filename("C:/root/session-0123456789abcdef0123456789abcdef-foreign/recovery-a-3-1.bin", "C:/root", session_name) == null);
    try std.testing.expect(selected_filename("C:/root/session-0123456789abcdef0123456789abcdef/recovery-a-3-1.bin/child", "C:/root", session_name) == null);
    try std.testing.expect(selected_filename("C:/root/session-0123456789abcdef0123456789abcdef/recovery-a-3-1.bin:stream", "C:/root", session_name) == null);
    try std.testing.expect(selected_filename("C:/root/session-0123456789abcdef0123456789abcdef/recovery-a-3-.bin", "C:/root", session_name) == null);
    try std.testing.expect(selected_filename("C:/root/session-0123456789abcdef0123456789abcdef/recovery-a-3-1.bin\x00foreign", "C:/root", session_name) == null);
}
