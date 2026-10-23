const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const ntdll = windows.ntdll;

/// Result of a completed durable new-file publication.
/// `digest` hashes exactly `content`; `bytes_written` equals `content.len`.
pub const Receipt = struct {
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    bytes_written: usize,
};

/// `PublishedNotDurable` means destination bytes were renamed but their durable
/// flush failed; callers must retain the destination as recovery evidence.
pub const PublishError = error{
    EmptyPath,
    NulByte,
    InvalidDestinationName,
    ScratchTooSmall,
    ScratchAliased,
    PathTooLong,
    TemporaryNameExhausted,
    UnsupportedPlatform,
    UnsupportedFilesystem,
    RemoteFilesystem,
    TemporaryCleanupFailed,
    PublishedNotDurable,
};

const temporary_prefix = ".warkocz-new-";
const random_bytes = 16;
const temporary_name_len = temporary_prefix.len + random_bytes * 2;
const temporary_attempts = 16;
const filesystem_name_capacity = 32;
const file_remote_device = 0x00000010;

const Parent = struct {
    dir: std.Io.Dir,
    owned: bool,

    fn close(parent: Parent, io: std.Io) void {
        std.debug.assert(parent.owned or parent.dir.handle == std.Io.Dir.cwd().handle);
        if (parent.owned) parent.dir.close(io);
    }
};

const FilesystemAttributeInformation = extern struct {
    attributes: u32,
    maximum_component_name_length: u32,
    name_length: u32,
    name: [0]u16,
};

/// Publishes immutable `content` as a new file at `path`.
///
/// Durable success is Windows-local-NTFS only.
/// This implementation rejects every other filesystem and remote volume before
/// creating a file, so it never reports durable success on unqualified storage.
/// The temporary file is exclusively opened, flushed, atomically renamed through
/// its opened parent, then flushed again with FILE_WRITE_THROUGH.
/// On pre-rename failure, cleanup is attached to the temporary file handle rather
/// than a path, preventing an adversary's replacement from being deleted.
///
/// Initial path subset: relative paths or `C:\\`/`C:/` absolute paths with normal
/// Windows components. It rejects traversal, device/extended/UNC namespaces, and
/// every component Win32 would normalize or reinterpret. WTF-8 is passed unchanged
/// to `wtf8ToWtf16Le`, including valid unpaired-surrogate encodings. Opening the
/// immediate parent does not follow that final link, but already-resolved ancestors
/// are not a confinement boundary and can change before publication.
/// `scratch` must not overlap `path` or `content` because it becomes the temporary name.
pub fn publish_new(io: std.Io, path: []const u8, content: []const u8, scratch: []u8) !Receipt {
    return publish_new_impl(io, path, content, scratch, sync_file);
}

const PostRenameSync = *const fn (std.Io, std.Io.File) anyerror!void;

fn publish_new_impl(io: std.Io, path: []const u8, content: []const u8, scratch: []u8, post_rename_sync: PostRenameSync) !Receipt {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const destination_name = try validate(path, content, scratch);
    const parent = try open_parent(io, path);
    defer parent.close(io);
    try require_local_ntfs(parent.dir);

    const temporary_name = scratch[0..temporary_name_len];
    var temporary_file = try create_temporary(io, parent.dir, temporary_name);
    temporary_file.writeStreamingAll(io, content) catch |err| return fail_temporary(io, temporary_file, err);
    temporary_file.sync(io) catch |err| return fail_temporary(io, temporary_file, err);
    rename_preserve(temporary_file, parent.dir, destination_name) catch |err| return fail_temporary(io, temporary_file, err);
    post_rename_sync(io, temporary_file) catch {
        temporary_file.close(io);
        return error.PublishedNotDurable;
    };
    temporary_file.close(io);
    return make_receipt(content);
}

fn sync_file(io: std.Io, file: std.Io.File) !void {
    try file.sync(io);
}

fn validate(path: []const u8, content: []const u8, scratch: []u8) ![]const u8 {
    if (path.len == 0) return error.EmptyPath;
    if (path.len >= std.Io.Dir.max_path_bytes) return error.PathTooLong;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.NulByte;
    const destination_name = try validate_destination_path(path);
    if (scratch.len < temporary_name_len) return error.ScratchTooSmall;
    if (slices_overlap(scratch, path) or slices_overlap(scratch, content)) return error.ScratchAliased;
    std.debug.assert(destination_name.len <= path.len);
    std.debug.assert(scratch.len >= temporary_name_len);
    return destination_name;
}

fn validate_destination_path(path: []const u8) ![]const u8 {
    std.debug.assert(path.len > 0 and std.mem.indexOfScalar(u8, path, 0) == null);
    var offset: usize = 0;
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and is_separator(path[2])) {
        offset = 3;
    } else if (path[0] == '\\' or path[0] == '/') {
        return error.InvalidDestinationName;
    }
    if (offset == path.len or is_separator(path[path.len - 1])) return error.InvalidDestinationName;

    var destination_name: ?[]const u8 = null;
    while (offset < path.len) {
        const component_end = std.mem.indexOfAnyPos(u8, path, offset, "\\/") orelse path.len;
        const component = path[offset..component_end];
        try validate_component(component);
        destination_name = component;
        if (component_end == path.len) break;
        offset = component_end + 1;
    }
    return destination_name orelse error.InvalidDestinationName;
}

fn validate_component(component: []const u8) !void {
    if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.InvalidDestinationName;
    if (component[component.len - 1] == '.' or component[component.len - 1] == ' ') return error.InvalidDestinationName;
    for (component) |byte| if (byte <= 0x1f or std.mem.indexOfScalar(u8, "<>:\"|?*", byte) != null) return error.InvalidDestinationName;
    if (is_reserved_device_name(component)) return error.InvalidDestinationName;
    std.debug.assert(component.len > 0);
}

fn is_separator(byte: u8) bool {
    return byte == '\\' or byte == '/';
}

fn is_reserved_device_name(component: []const u8) bool {
    const stem = component[0 .. std.mem.indexOfScalar(u8, component, '.') orelse component.len];
    if (std.ascii.eqlIgnoreCase(stem, "CON") or std.ascii.eqlIgnoreCase(stem, "PRN") or std.ascii.eqlIgnoreCase(stem, "AUX") or std.ascii.eqlIgnoreCase(stem, "NUL")) return true;
    if (stem.len != 4) return false;
    return (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT")) and stem[3] >= '1' and stem[3] <= '9';
}

fn slices_overlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch return true;
    const right_end = std.math.add(usize, right_start, right.len) catch return true;
    const overlaps = left_start < right_end and right_start < left_end;
    std.debug.assert(left_end > left_start and right_end > right_start);
    return overlaps;
}

fn open_parent(io: std.Io, path: []const u8) !Parent {
    const parent_path = std.fs.path.dirname(path) orelse return .{ .dir = std.Io.Dir.cwd(), .owned = false };
    std.debug.assert(parent_path.len > 0);
    return .{ .dir = try std.Io.Dir.cwd().openDir(io, parent_path, .{ .access_sub_paths = true, .follow_symlinks = false }), .owned = true };
}

fn require_local_ntfs(parent: std.Io.Dir) !void {
    var storage: [@sizeOf(FilesystemAttributeInformation) + filesystem_name_capacity * @sizeOf(u16)]u8 align(@alignOf(FilesystemAttributeInformation)) = undefined;
    const info: *FilesystemAttributeInformation = @ptrCast(&storage);
    var status_block: windows.IO_STATUS_BLOCK = undefined;
    const status = ntdll.NtQueryVolumeInformationFile(parent.handle, &status_block, info, storage.len, .Attribute);
    if (status != .SUCCESS) return error.UnsupportedFilesystem;
    if (info.name_length % @sizeOf(u16) != 0) return error.UnsupportedFilesystem;
    const name_len = @divExact(info.name_length, @sizeOf(u16));
    if (name_len > filesystem_name_capacity) return error.UnsupportedFilesystem;
    const name: [*]const u16 = @ptrCast(&info.name);
    if (!std.mem.eql(u16, name[0..name_len], &.{ 'N', 'T', 'F', 'S' })) return error.UnsupportedFilesystem;
    // FILE_REMOTE_DEVICE is a device characteristic, not a filesystem attribute.
    // In filesystem attributes, 0x10 means FILE_FILE_COMPRESSION.
    var device: windows.FILE.FS_DEVICE_INFORMATION = undefined;
    const device_status = ntdll.NtQueryVolumeInformationFile(parent.handle, &status_block, &device, @sizeOf(@TypeOf(device)), .Device);
    if (device_status != .SUCCESS) return error.UnsupportedFilesystem;
    if ((device.Characteristics & file_remote_device) != 0) return error.RemoteFilesystem;
    std.debug.assert(name_len == 4);
    std.debug.assert((device.Characteristics & file_remote_device) == 0);
}

fn create_temporary(io: std.Io, parent: std.Io.Dir, temporary_name: []u8) !std.Io.File {
    std.debug.assert(temporary_name.len == temporary_name_len);
    @memcpy(temporary_name[0..temporary_prefix.len], temporary_prefix);
    var random: [random_bytes]u8 = undefined;
    for (0..temporary_attempts) |_| {
        try io.randomSecure(&random);
        encode_hex_lower(temporary_name[temporary_prefix.len..], &random);
        return create_write_through_file(parent, temporary_name) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |unexpected| return unexpected,
        };
    }
    return error.TemporaryNameExhausted;
}

fn create_write_through_file(parent: std.Io.Dir, name: []const u8) !std.Io.File {
    var name_w: [windows.NAME_MAX]u16 = undefined;
    const name_len = try windows.wtf8ToWtf16Le(&name_w, name);
    var object_name = windows.UNICODE_STRING.init(name_w[0..name_len]);
    const attributes: windows.OBJECT.ATTRIBUTES = .{ .RootDirectory = parent.handle, .ObjectName = &object_name };
    var status_block: windows.IO_STATUS_BLOCK = undefined;
    var handle: windows.HANDLE = undefined;
    const status = ntdll.NtCreateFile(&handle, .{ .STANDARD = .{ .RIGHTS = .{ .DELETE = true }, .SYNCHRONIZE = true }, .GENERIC = .{ .WRITE = true } }, &attributes, &status_block, null, .{ .NORMAL = true }, .{}, .CREATE, .{ .WRITE_THROUGH = true, .NON_DIRECTORY_FILE = true, .IO = .SYNCHRONOUS_NONALERT }, null, 0);
    return switch (status) {
        .SUCCESS => .{ .handle = handle, .flags = .{ .nonblocking = false } },
        .OBJECT_NAME_COLLISION => error.PathAlreadyExists,
        .ACCESS_DENIED => error.AccessDenied,
        .OBJECT_PATH_NOT_FOUND, .OBJECT_NAME_NOT_FOUND => error.FileNotFound,
        .FILE_IS_A_DIRECTORY => error.IsDir,
        .NOT_A_DIRECTORY => error.NotDir,
        .DISK_FULL => error.NoSpaceLeft,
        else => error.Unexpected,
    };
}

fn fail_temporary(io: std.Io, file: std.Io.File, original_error: anyerror) anyerror!Receipt {
    mark_delete_on_close(file) catch {
        file.close(io);
        return error.TemporaryCleanupFailed;
    };
    file.close(io);
    return original_error;
}

fn mark_delete_on_close(file: std.Io.File) !void {
    var information = windows.FILE.DISPOSITION.INFORMATION{ .DeleteFile = .fromBool(true) };
    var status_block: windows.IO_STATUS_BLOCK = undefined;
    const status = ntdll.NtSetInformationFile(file.handle, &status_block, @ptrCast(&information), @sizeOf(@TypeOf(information)), .Disposition);
    if (status != .SUCCESS) return error.Unexpected;
    std.debug.assert(information.DeleteFile.toBool());
}

fn rename_preserve(file: std.Io.File, parent: std.Io.Dir, destination_name: []const u8) !void {
    var name_w: [windows.NAME_MAX]u16 = undefined;
    const name_len = try windows.wtf8ToWtf16Le(&name_w, destination_name);
    var rename_info: windows.FILE.RENAME_INFORMATION = .init(.{ .RootDirectory = parent.handle, .FileName = name_w[0..name_len] });
    var status_block: windows.IO_STATUS_BLOCK = undefined;
    var status = ntdll.NtSetInformationFile(file.handle, &status_block, @ptrCast(&rename_info), @intCast(rename_info.toBuffer().len), .RenameEx);
    if (status == .INVALID_PARAMETER or status == .INVALID_INFO_CLASS or status == .NOT_SUPPORTED) status = ntdll.NtSetInformationFile(file.handle, &status_block, @ptrCast(&rename_info), @intCast(rename_info.toBuffer().len), .Rename);
    return switch (status) {
        .SUCCESS => {},
        .OBJECT_NAME_COLLISION => error.PathAlreadyExists,
        .ACCESS_DENIED => error.AccessDenied,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
        .NOT_SAME_DEVICE => error.CrossDevice,
        .FILE_IS_A_DIRECTORY => error.IsDir,
        .NOT_A_DIRECTORY => error.NotDir,
        else => error.Unexpected,
    };
}

fn make_receipt(content: []const u8) Receipt {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    std.debug.assert(content.len == @as(usize, content.len));
    return .{ .digest = digest, .bytes_written = content.len };
}

fn encode_hex_lower(destination: []u8, source: []const u8) void {
    const alphabet = "0123456789abcdef";
    std.debug.assert(destination.len == source.len * 2);
    for (source, 0..) |byte, index| {
        destination[index * 2] = alphabet[byte >> 4];
        destination[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    std.debug.assert(destination.len == source.len * 2);
}

test "temporary name hex encoding has exact boundary" {
    var destination: [4]u8 = undefined;
    encode_hex_lower(&destination, &.{ 0x0a, 0xff });
    try std.testing.expectEqualStrings("0aff", &destination);
    try std.testing.expectEqual(@as(usize, temporary_name_len), temporary_prefix.len + random_bytes * 2);
}

test "validation rejects aliases and unsafe Windows paths before filesystem mutation" {
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    @memset(&path, 'a');
    var scratch: [temporary_name_len]u8 = undefined;
    try std.testing.expectError(error.PathTooLong, validate(&path, "", &scratch));
    for ([_][]const u8{ "target:stream", "target/", "dir/../target", "NUL.txt", "COM1", "name.", "name ", "name*", "C:/dir/PRN", "\\\\?\\C:\\target", "\\\\.\\NUL", "\\\\server\\share\\target" }) |unsafe_path| {
        try std.testing.expectError(error.InvalidDestinationName, validate(unsafe_path, "", &scratch));
    }
    try std.testing.expectError(error.ScratchAliased, validate(scratch[0..], "", scratch[0..]));
    try std.testing.expectError(error.ScratchAliased, validate("target", scratch[0..], scratch[0..]));
}

test "validation preserves WTF-8 bytes without normalization" {
    var scratch: [temporary_name_len]u8 = undefined;
    const path = "C:/fixture/\xed\xa0\x80-result.bin";
    const name = try validate(path, "", &scratch);
    try std.testing.expectEqualStrings("\xed\xa0\x80-result.bin", name);
}

test "unsupported platforms never report durable publication" {
    if (comptime builtin.os.tag == .windows) return;
    var scratch: [temporary_name_len]u8 = undefined;
    try std.testing.expectError(error.UnsupportedPlatform, publish_new(std.testing.io, "result", "bytes", &scratch));
}

fn native_e2e_enabled() bool {
    const environ: std.process.Environ = .{ .block = .global };
    const value = environ.getAlloc(std.testing.allocator, "WARKOCZ_NATIVE_E2E") catch return false;
    defer std.testing.allocator.free(value);
    return std.mem.eql(u8, value, "1");
}

test "Windows NTFS publication is opt-in and preserves bytes" {
    if (comptime builtin.os.tag != .windows) return;
    if (!native_e2e_enabled()) return;

    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e";
    try cwd.createDirPath(io, root);
    var fixture_memory: [root.len + 1 + 16]u8 = undefined;
    const fixture = try create_unique_fixture(io, cwd, root, &fixture_memory);
    defer cwd.deleteDir(io, fixture) catch {};
    var published_memory: [root.len + 1 + 16 + 14]u8 = undefined;
    var empty_memory: [root.len + 1 + 16 + 10]u8 = undefined;
    var occupied_memory: [root.len + 1 + 16 + 13]u8 = undefined;
    var directory_memory: [root.len + 1 + 16 + 10]u8 = undefined;
    var failed_flush_memory: [root.len + 1 + 16 + 17]u8 = undefined;
    const published = try std.fmt.bufPrint(&published_memory, "{s}/published.bin", .{fixture});
    const empty = try std.fmt.bufPrint(&empty_memory, "{s}/empty.bin", .{fixture});
    const occupied = try std.fmt.bufPrint(&occupied_memory, "{s}/occupied.bin", .{fixture});
    const directory = try std.fmt.bufPrint(&directory_memory, "{s}/directory", .{fixture});
    const failed_flush = try std.fmt.bufPrint(&failed_flush_memory, "{s}/flush-failed.bin", .{fixture});
    defer cwd.deleteFile(io, failed_flush) catch {};
    defer cwd.deleteDir(io, directory) catch {};
    defer cwd.deleteFile(io, occupied) catch {};
    defer cwd.deleteFile(io, empty) catch {};
    defer cwd.deleteFile(io, published) catch {};

    const source = "\xef\xbb\xbfline\r\nnext\n\x00\xff";
    var first_scratch: [temporary_name_len]u8 = undefined;
    const receipt = try publish_new(io, published, source, &first_scratch);
    var expected_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &expected_digest, .{});
    try std.testing.expectEqual(source.len, receipt.bytes_written);
    try std.testing.expectEqualSlices(u8, &expected_digest, &receipt.digest);
    try expect_file_bytes(io, published, source);
    var second_scratch: [temporary_name_len]u8 = undefined;
    try std.testing.expectError(error.PathAlreadyExists, publish_new(io, published, source, &second_scratch));

    var empty_scratch: [temporary_name_len]u8 = undefined;
    const empty_receipt = try publish_new(io, empty, "", &empty_scratch);
    var empty_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("", &empty_digest, .{});
    try std.testing.expectEqual(@as(usize, 0), empty_receipt.bytes_written);
    try std.testing.expectEqualSlices(u8, &empty_digest, &empty_receipt.digest);
    try expect_file_bytes(io, empty, "");

    var occupied_file = try cwd.createFile(io, occupied, .{ .exclusive = true });
    try occupied_file.writeStreamingAll(io, "existing\r\n");
    try occupied_file.sync(io);
    occupied_file.close(io);
    try std.testing.expectError(error.PathAlreadyExists, publish_new(io, occupied, source, &first_scratch));
    try expect_file_bytes(io, occupied, "existing\r\n");
    try cwd.createDir(io, directory, .default_dir);
    try std.testing.expectError(error.PathAlreadyExists, publish_new(io, directory, source, &first_scratch));

    var parent = try cwd.openDir(io, fixture, .{ .access_sub_paths = true, .follow_symlinks = false });
    defer parent.close(io);
    var cleanup_scratch: [temporary_name_len]u8 = undefined;
    const temporary = try create_temporary(io, parent, &cleanup_scratch);
    try std.testing.expectError(error.InjectedPreRenameFailure, fail_temporary(io, temporary, error.InjectedPreRenameFailure));
    try std.testing.expectError(error.FileNotFound, parent.openFile(io, &cleanup_scratch, .{}));

    const fail = struct {
        fn sync(_: std.Io, _: std.Io.File) !void {
            return error.InjectedPostRenameFlushFailure;
        }
    }.sync;
    try std.testing.expectError(error.PublishedNotDurable, publish_new_impl(io, failed_flush, source, &first_scratch, fail));
    try expect_file_bytes(io, failed_flush, source);
    try cwd.deleteFile(io, failed_flush);
}

fn create_unique_fixture(io: std.Io, cwd: std.Io.Dir, root: []const u8, memory: []u8) ![]const u8 {
    std.debug.assert(memory.len == root.len + 1 + 16);
    @memcpy(memory[0..root.len], root);
    memory[root.len] = '/';
    var random: [8]u8 = undefined;
    for (0..temporary_attempts) |_| {
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

fn expect_file_bytes(io: std.Io, path: []const u8, expected: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [128]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = try reader.interface.allocRemaining(std.testing.allocator, .limited(expected.len));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, expected, bytes);
}

test "publish API compiles" {
    std.testing.refAllDecls(@This());
}
