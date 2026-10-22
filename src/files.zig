const std = @import("std");

pub const Loaded = struct {
    bytes: []const u8,
    digest: [32]u8,
};

pub const LoadError = error{
    NotRegularFile,
    DestinationTooSmall,
    FileChanged,
    ReadFailed,
    ExceedsMaxBytes,
} || std.Io.Dir.StatFileError || std.Io.File.Reader.Error;

/// Loads one regular file into caller-owned storage without allocation.
/// `destination` contents are undefined when this function returns an error.
/// Metadata checks detect observed changes, not a coherent filesystem snapshot.
/// Pre-stat rejects existing special files, but cannot prevent their replacement
/// before open. Zig's Threaded POSIX backend lacks a nonblocking-open option;
/// a FIFO replacement can still block there. `lock_nonblocking` is not that option.
pub fn load(io: std.Io, path: []const u8, destination: []u8) LoadError!Loaded {
    const cwd = std.Io.Dir.cwd();
    const pre_open_stat = cwd.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.IsDir => return error.NotRegularFile,
        else => |e| return e,
    };
    if (pre_open_stat.kind != .file) return error.NotRegularFile;

    var file = cwd.openFile(io, path, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.IsDir => return error.NotRegularFile,
        else => |e| return e,
    };
    defer file.close(io);

    const before = try file.stat(io);
    if (before.kind != .file) return error.NotRegularFile;
    try check_unchanged(pre_open_stat, before);
    const source_len = std.math.cast(usize, before.size) orelse return error.DestinationTooSmall;
    var reader = file.reader(io, &.{});
    const loaded = load_reader(&reader.interface, source_len, destination) catch |err| switch (err) {
        error.ReadFailed => return reader.err orelse error.ReadFailed,
        else => |e| return e,
    };
    const after = try file.stat(io);
    try check_unchanged(before, after);
    const path_after = cwd.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => return error.FileChanged,
        else => |e| return e,
    };
    try check_unchanged(after, path_after);
    std.debug.assert(loaded.bytes.len == source_len);
    std.debug.assert(loaded.bytes.len <= destination.len);
    return loaded;
}

/// Hashes a regular file in caller-provided bounded chunks without retaining its contents.
/// Metadata checks match `load`; the byte cap is explicit and never truncates hashing.
pub fn fingerprint(io: std.Io, path: []const u8, caller_chunk: []u8, max_bytes: usize) LoadError![32]u8 {
    const cwd = std.Io.Dir.cwd();
    const pre_open_stat = cwd.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.IsDir => return error.NotRegularFile,
        else => |e| return e,
    };
    if (pre_open_stat.kind != .file) return error.NotRegularFile;
    var file = cwd.openFile(io, path, .{ .mode = .read_only, .allow_directory = false, .follow_symlinks = false }) catch |err| switch (err) {
        error.IsDir => return error.NotRegularFile,
        else => |e| return e,
    };
    defer file.close(io);
    const before = try file.stat(io);
    if (before.kind != .file) return error.NotRegularFile;
    try check_unchanged(pre_open_stat, before);
    const source_len = std.math.cast(usize, before.size) orelse return error.ExceedsMaxBytes;
    if (source_len > max_bytes) return error.ExceedsMaxBytes;
    if (caller_chunk.len == 0) return error.DestinationTooSmall;
    var reader = file.reader(io, &.{});
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    try fingerprint_reader(&reader.interface, source_len, caller_chunk, &hasher);
    const after = try file.stat(io);
    try check_unchanged(before, after);
    const path_after = cwd.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => return error.FileChanged,
        else => |e| return e,
    };
    try check_unchanged(after, path_after);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn fingerprint_reader(reader: *std.Io.Reader, source_len: usize, chunk: []u8, hasher: *std.crypto.hash.sha2.Sha256) LoadError!void {
    if (chunk.len == 0) return error.DestinationTooSmall;
    var remaining = source_len;
    while (remaining > 0) {
        const amount = @min(remaining, chunk.len);
        reader.readSliceAll(chunk[0..amount]) catch |err| switch (err) {
            error.EndOfStream => return error.FileChanged,
            error.ReadFailed => return error.ReadFailed,
        };
        hasher.update(chunk[0..amount]);
        remaining -= amount;
    }
    var extra: [1]u8 = undefined;
    const extra_len = reader.readSliceShort(&extra) catch return error.ReadFailed;
    if (extra_len != 0) return error.FileChanged;
}

fn check_unchanged(before: std.Io.File.Stat, after: std.Io.File.Stat) LoadError!void {
    std.debug.assert(before.kind == .file);
    if (after.kind != .file or before.inode != after.inode or before.size != after.size or
        before.mtime.nanoseconds != after.mtime.nanoseconds or
        before.ctime.nanoseconds != after.ctime.nanoseconds) return error.FileChanged;
    // Ignore atime: this read can itself update it. Inode has no device/volume
    // identity in this API, and timestamps may be coarse, stale, or restored.
    std.debug.assert(after.kind == .file);
}

fn load_reader(reader: *std.Io.Reader, source_len: usize, destination: []u8) LoadError!Loaded {
    std.debug.assert(reader.seek <= reader.end);
    std.debug.assert(reader.end <= reader.buffer.len);
    if (source_len > destination.len) return error.DestinationTooSmall;

    const bytes = destination[0..source_len];
    reader.readSliceAll(bytes) catch |err| switch (err) {
        error.EndOfStream => return error.FileChanged,
        error.ReadFailed => return error.ReadFailed,
    };

    var extra: [1]u8 = undefined;
    const extra_len = reader.readSliceShort(&extra) catch return error.ReadFailed;
    if (extra_len != 0) return error.FileChanged;

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    std.debug.assert(bytes.len == source_len);
    std.debug.assert(extra_len == 0);
    return .{ .bytes = bytes, .digest = digest };
}

fn expect_loaded(source: []const u8, destination: []u8) !Loaded {
    var reader: std.Io.Reader = .fixed(source);
    return load_reader(&reader, source.len, destination);
}

test "native loader API compiles" {
    std.testing.refAllDecls(@This());
}

test "loads empty source and exact destination boundary" {
    var empty_destination: [0]u8 = .{};
    const empty = try expect_loaded("", &empty_destination);
    try std.testing.expectEqual(@as(usize, 0), empty.bytes.len);

    var exact_destination: [3]u8 = undefined;
    const exact = try expect_loaded("abc", &exact_destination);
    try std.testing.expectEqualStrings("abc", exact.bytes);
    var expected_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("abc", &expected_digest, .{});
    try std.testing.expectEqualSlices(u8, &expected_digest, &exact.digest);
}

test "preserves BOM mixed newlines and binary bytes" {
    const source = "\xef\xbb\xbfline\r\nnext\n\x00\xff";
    var destination: [source.len]u8 = undefined;
    const loaded = try expect_loaded(source, &destination);
    try std.testing.expectEqualStrings(source, loaded.bytes);
}

test "rejects source exceeding destination without truncation" {
    var reader: std.Io.Reader = .fixed("abcd");
    var destination = [_]u8{ 0xa5, 0xa5, 0xa5 };
    try std.testing.expectError(error.DestinationTooSmall, load_reader(&reader, 4, &destination));
    try std.testing.expectEqualSlices(u8, &([_]u8{ 0xa5, 0xa5, 0xa5 }), &destination);
}

test "metadata detects identity size same-length writes and special-file replacement" {
    const before: std.Io.File.Stat = .{
        .inode = 1,
        .nlink = 1,
        .size = 3,
        .permissions = .default_file,
        .kind = .file,
        .atime = .zero,
        .mtime = .{ .nanoseconds = 10 },
        .ctime = .{ .nanoseconds = 20 },
        .block_size = 1,
    };
    try check_unchanged(before, before);
    inline for (.{ "inode", "size", "mtime", "ctime", "kind" }) |field| {
        var after = before;
        if (comptime std.mem.eql(u8, field, "kind")) {
            after.kind = .named_pipe;
        } else if (comptime std.mem.eql(u8, field, "mtime") or std.mem.eql(u8, field, "ctime")) {
            @field(after, field).nanoseconds += 1;
        } else {
            @field(after, field) += 1;
        }
        try std.testing.expectError(error.FileChanged, check_unchanged(before, after));
    }
    var accessed = before;
    accessed.atime = .{ .nanoseconds = 30 };
    try check_unchanged(before, accessed);
    accessed.atime = null;
    try check_unchanged(before, accessed);
}

test "read failure during content or EOF probe remains a failure" {
    const failing = struct {
        fn stream(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
            return error.ReadFailed;
        }
    };
    var destination: [3]u8 = undefined;
    var reader: std.Io.Reader = .{
        .vtable = &.{ .stream = failing.stream },
        .buffer = &.{},
        .seek = 0,
        .end = 0,
    };
    try std.testing.expectError(error.ReadFailed, load_reader(&reader, 3, &destination));
    var buffered_source = [_]u8{ 'a', 'b', 'c' };
    reader.buffer = &buffered_source;
    reader.end = buffered_source.len;
    try std.testing.expectError(error.ReadFailed, load_reader(&reader, 3, &destination));
    try std.testing.expectEqualStrings("abc", &destination);
}

test "rejects source growth and shrinkage" {
    var growing_reader: std.Io.Reader = .fixed("abcd");
    var growing_destination: [3]u8 = undefined;
    try std.testing.expectError(error.FileChanged, load_reader(&growing_reader, 3, &growing_destination));

    var shrinking_reader: std.Io.Reader = .fixed("abc");
    var shrinking_destination: [4]u8 = undefined;
    try std.testing.expectError(error.FileChanged, load_reader(&shrinking_reader, 4, &shrinking_destination));
}

test "fingerprints stream across exact and partial chunk boundaries" {
    const source = "abcdefghij";
    var reader: std.Io.Reader = .fixed(source);
    var chunk: [4]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    try fingerprint_reader(&reader, source.len, &chunk, &hasher);
    var actual: [32]u8 = undefined;
    hasher.final(&actual);
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &actual);

    var exact_reader: std.Io.Reader = .fixed("abcdefgh");
    var exact_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    try fingerprint_reader(&exact_reader, 8, &chunk, &exact_hasher);
    var exact_actual: [32]u8 = undefined;
    exact_hasher.final(&exact_actual);
    var exact_expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("abcdefgh", &exact_expected, .{});
    try std.testing.expectEqualSlices(u8, &exact_expected, &exact_actual);

    var changed: std.Io.Reader = .fixed("abcdefghi");
    var changed_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    try std.testing.expectError(error.FileChanged, fingerprint_reader(&changed, source.len, &chunk, &changed_hasher));
}
