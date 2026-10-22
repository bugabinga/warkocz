const std = @import("std");
const builtin = @import("builtin");
const recovery = @import("recovery.zig");
const directory = @import("recovery_directory.zig");
const files = @import("files.zig");

pub const max_sessions: usize = 64;
pub const max_files_per_session: usize = 128;
pub const path_capacity: usize = std.Io.Dir.max_path_bytes;
pub const max_ciphertext: usize = recovery.Controller.ciphertext_capacity;
pub const max_plaintext: usize = recovery.Controller.plaintext_capacity;

pub const Reason = enum { invalid_name, unreadable, corrupt, unknown_file, insecure_directory };
pub const Candidate = struct {
    path: [path_capacity]u8 = undefined,
    path_len: usize = 0,
    session_name: [40]u8 = undefined,
    generation: u64 = 0,
    result_len: usize = 0,
    mode: @FieldType(recovery.Record, "mode") = .two_way,
    ciphertext_digest: [32]u8 = undefined,
};
pub const Outcome = struct { count: usize = 0, skipped: usize = 0, truncated: bool = false, resource_limited: bool = false };
pub const Storage = struct { ciphertext: []u8, plaintext: []u8, path_scratch: []u16, token_scratch: []align(8) u8 };
pub const Error = error{ UnsupportedPlatform, InvalidRoot, ScratchTooSmall } || std.Io.Dir.OpenError || std.Io.Dir.Iterator.Error || files.LoadError || directory.Error;

/// Bounded, read-only discovery. Invoke from a worker; no candidate bytes are restored or written.
pub fn scan(io: std.Io, app_root: []const u8, candidates: []Candidate, storage: Storage) Error!Outcome {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    if (candidates.len == 0 or candidates.len > max_sessions or storage.ciphertext.len < max_ciphertext or storage.plaintext.len < max_plaintext or storage.path_scratch.len < std.os.windows.NAME_MAX or storage.token_scratch.len < 1024) return error.ScratchTooSmall;
    var app = try directory.open_existing(app_root, storage.path_scratch, storage.token_scratch);
    defer directory.close(&app);
    var root_dir = try std.Io.Dir.cwd().openDir(io, app_root, .{ .access_sub_paths = true, .iterate = true, .follow_symlinks = false });
    defer root_dir.close(io);
    var iterator = root_dir.iterate();
    var outcome: Outcome = .{};
    var inspected_entries: usize = 0;
    while (try iterator.next(io)) |entry| {
        inspected_entries += 1;
        if (inspected_entries > max_sessions) {
            outcome.resource_limited = true;
            break;
        }
        if (entry.kind != .directory or !session_name(entry.name)) continue;
        const before = outcome.count;
        try scan_session(io, app_root, entry.name, candidates, &outcome, storage);
        if (outcome.count == before and candidates.len == outcome.count) outcome.truncated = true;
    }
    return outcome;
}

fn scan_session(io: std.Io, app_root: []const u8, name: []const u8, candidates: []Candidate, outcome: *Outcome, storage: Storage) Error!void {
    var path: [path_capacity]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&path, "{s}/{s}", .{ app_root, name });
    var owned = try directory.open_existing(dir_path, storage.path_scratch, storage.token_scratch);
    defer directory.close(&owned);
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .access_sub_paths = true, .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    var iter = dir.iterate();
    var inspected: usize = 0;
    var best: ?Candidate = null;
    while (try iter.next(io)) |entry| {
        inspected += 1;
        if (inspected > max_files_per_session) {
            outcome.resource_limited = true;
            break;
        }
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "recovery-")) {
            outcome.skipped += 1;
            continue;
        }
        const generation = filename_generation(entry.name) orelse {
            outcome.skipped += 1;
            continue;
        };
        var file_path: [path_capacity]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&file_path, "{s}/{s}", .{ dir_path, entry.name });
        const loaded = files.load(io, full_path, storage.ciphertext) catch {
            outcome.skipped += 1;
            continue;
        };
        const decoded = recovery.decode(loaded.bytes, storage.plaintext) catch {
            outcome.skipped += 1;
            continue;
        };
        const metadata = take_metadata_and_wipe(decoded, storage.plaintext);
        if (metadata.generation != generation) {
            outcome.skipped += 1;
            continue;
        }
        if (best == null or metadata.generation > best.?.generation) {
            var candidate: Candidate = .{ .generation = metadata.generation, .result_len = metadata.result_len, .mode = metadata.mode, .ciphertext_digest = loaded.digest };
            @memcpy(candidate.path[0..full_path.len], full_path);
            candidate.path_len = full_path.len;
            @memcpy(candidate.session_name[0..name.len], name);
            best = candidate;
        }
    }
    if (best) |candidate| {
        if (outcome.count == candidates.len) outcome.truncated = true else {
            candidates[outcome.count] = candidate;
            outcome.count += 1;
        }
    }
}

const Metadata = struct { generation: u64, result_len: usize, mode: @FieldType(recovery.Record, "mode") };

fn take_metadata_and_wipe(decoded: recovery.Decoded, plaintext: []u8) Metadata {
    defer recovery.wipe(plaintext);
    return .{ .generation = decoded.generation, .result_len = decoded.result.len, .mode = decoded.mode };
}

fn session_name(name: []const u8) bool {
    if (name.len != 40 or !std.mem.startsWith(u8, name, "session-")) return false;
    for (name[8..]) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn filename_generation(name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, name, "recovery-") or !std.mem.endsWith(u8, name, ".bin")) return null;
    const body = name[9 .. name.len - 4];
    const first = std.mem.indexOfScalar(u8, body, '-') orelse return null;
    const second_rel = std.mem.indexOfScalar(u8, body[first + 1 ..], '-') orelse return null;
    const generation = body[first + 1 ..][0..second_rel];
    if (generation.len == 0) return null;
    return std.fmt.parseInt(u64, generation, 10) catch null;
}

test "recovery discovery rejects malformed session names and filenames" {
    try std.testing.expect(session_name("session-0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!session_name("session-0123456789abcdef0123456789abcdeg"));
    try std.testing.expectEqual(@as(?u64, 42), filename_generation("recovery-a-42-1.bin"));
    try std.testing.expectEqual(@as(?u64, null), filename_generation("recovery-a-x-1.bin"));
}

test "recovery discovery clears complete plaintext scratch after metadata extraction" {
    var plaintext: [64]u8 = @splat(0xa5);
    const decoded: recovery.Decoded = .{ .mode = .two_way, .generation = 42, .identity = undefined, .source_paths = undefined, .result = plaintext[8..12], .origin = .two_way_right, .reviewed = false, .unresolved = false, .engine = undefined, .provenance = undefined };
    const metadata = take_metadata_and_wipe(decoded, &plaintext);
    try std.testing.expectEqual(@as(u64, 42), metadata.generation);
    try std.testing.expectEqual(@as(usize, 4), metadata.result_len);
    for (plaintext) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "recovery discovery unsupported platform does not scan" {
    if (comptime builtin.os.tag == .windows) return;
    try std.testing.expectError(error.UnsupportedPlatform, scan(std.testing.io, "C:/not-used", &.{}, .{ .ciphertext = &.{}, .plaintext = &.{}, .path_scratch = &.{}, .token_scratch = &.{} }));
}
