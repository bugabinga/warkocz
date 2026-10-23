const std = @import("std");
const builtin = @import("builtin");
const files = @import("files.zig");
const output = @import("output.zig");
const session = @import("session.zig");
const recovery_directory = @import("recovery_directory.zig");

test {
    std.testing.refAllDecls(recovery_directory);
}

const Blob = extern struct { cbData: u32, pbData: ?[*]u8 };
const cryptprotect_ui_forbidden: u32 = 0x1;
const magic = "WARKREC1";
const zero_digest = std.mem.zeroes([32]u8);
const max_ciphertext_bytes = Controller.ciphertext_capacity;
pub const version: u32 = 1;

extern "crypt32" fn CryptProtectData(input: *const Blob, description: ?[*:0]const u16, entropy: ?*const Blob, reserved: ?*anyopaque, prompt: ?*anyopaque, flags: u32, encrypted: *Blob) callconv(.winapi) i32;
extern "crypt32" fn CryptUnprotectData(encrypted: *const Blob, description: ?*?[*:0]u16, entropy: ?*const Blob, reserved: ?*anyopaque, prompt: ?*anyopaque, flags: u32, plaintext: *Blob) callconv(.winapi) i32;
extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;

pub const SourcePaths = struct { base: ?[]const u8, left: []const u8, right: []const u8 };
pub const Engine = struct { name: []const u8, version: []const u8 };
pub const Record = struct {
    mode: session.Mode,
    generation: u64,
    identity: session.InputIdentity,
    source_paths: SourcePaths,
    result: []const u8,
    origin: session.Origin,
    reviewed: bool,
    unresolved: bool,
    engine: Engine,
    provenance: []const u8,
};

/// Every region is caller-owned, fixed-capacity storage and must remain disjoint from record views.
pub const Storage = struct { plaintext: []u8, ciphertext: []u8, publish_scratch: []u8 };
pub const Decoded = struct {
    mode: session.Mode,
    generation: u64,
    identity: session.InputIdentity,
    source_paths: SourcePaths,
    result: []const u8,
    origin: session.Origin,
    reviewed: bool,
    unresolved: bool,
    engine: Engine,
    provenance: []const u8,
};

pub const Error = error{
    UnsupportedPlatform,
    StorageAliased,
    ScratchTooSmall,
    CiphertextTooSmall,
    CiphertextTooLarge,
    InputTooLarge,
    InvalidRecord,
    WrongVersion,
    CorruptRecord,
    CryptProtectFailed,
    CryptUnprotectFailed,
    Busy,
    ResourceExhausted,
} || files.LoadError || output.PublishError;

/// Encrypts a complete recovery record with current user's Windows DPAPI key.
/// Accepted disjoint storage is securely wiped on every return; alias rejection preserves caller input.
pub fn encode(record: Record, storage: Storage) Error![]const u8 {
    try validate_storage(storage);
    try validate_record_storage(record, storage);
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const plaintext_len = try encoded_len(record);
    if (plaintext_len > storage.plaintext.len) return error.ScratchTooSmall;
    defer wipe(storage.plaintext);
    const plaintext = storage.plaintext[0..plaintext_len];
    try write_record(record, plaintext);
    var native_output = Blob{ .cbData = 0, .pbData = null };
    defer free_blob(&native_output, false);
    const input = try blob(plaintext);
    if (CryptProtectData(&input, null, null, null, null, cryptprotect_ui_forbidden, &native_output) == 0) return error.CryptProtectFailed;
    const encrypted = native_slice(native_output);
    if (encrypted.len > storage.ciphertext.len) return error.CiphertextTooSmall;
    @memcpy(storage.ciphertext[0..encrypted.len], encrypted);
    std.debug.assert(plaintext_len <= storage.plaintext.len);
    std.debug.assert(encrypted.len <= storage.ciphertext.len);
    return storage.ciphertext[0..encrypted.len];
}

/// Decrypts untrusted DPAPI data into caller-owned plaintext storage.
/// On failure disjoint plaintext storage is wiped and no recovered bytes escape; aliased input is rejected unchanged.
pub fn decode(ciphertext: []const u8, plaintext: []u8) Error!Decoded {
    if (overlaps(ciphertext, plaintext)) return error.StorageAliased;
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    if (ciphertext.len > max_ciphertext_bytes) {
        wipe(plaintext);
        return error.CiphertextTooLarge;
    }
    errdefer wipe(plaintext);
    var native_output = Blob{ .cbData = 0, .pbData = null };
    defer free_blob(&native_output, true);
    const input = try blob(ciphertext);
    if (CryptUnprotectData(&input, null, null, null, null, cryptprotect_ui_forbidden, &native_output) == 0) return error.CryptUnprotectFailed;
    const native_plaintext = native_slice(native_output);
    if (native_plaintext.len > plaintext.len) return error.ScratchTooSmall;
    @memcpy(plaintext[0..native_plaintext.len], native_plaintext);
    return parse_record(plaintext[0..native_plaintext.len]);
}

/// Restores bytes only when a freshly opened session still has every recorded source hash.
/// Recovered state is deliberately unreviewed and unresolved because exact decision replay is not proven.
pub fn restore_into(active: *session.Session, decoded: Decoded) session.Error!void {
    if (active.mode != decoded.mode) return error.ChangedInput;
    try active.restore_recovered(active.generation, decoded.identity, decoded.result);
    std.debug.assert(active.current_state().unresolved and !active.current_state().reviewed);
}

/// Reads ciphertext only, decrypts it with `plaintext`, and preserves no plaintext on error.
pub fn load(io: std.Io, path: []const u8, ciphertext: []u8, plaintext: []u8) Error!Decoded {
    if (overlaps(ciphertext, plaintext)) return error.StorageAliased;
    errdefer wipe(plaintext);
    const loaded = try files.load(io, path, ciphertext);
    return decode(loaded.bytes, plaintext);
}

/// Encrypts then durably publishes only to a new destination.
/// Buffer-capacity failures happen before filesystem I/O.
pub fn publish(io: std.Io, path: []const u8, record: Record, storage: Storage) !output.Receipt {
    const encrypted = try encode(record, storage);
    return output.publish_new(io, path, encrypted, storage.publish_scratch);
}

/// Wipes recovered plaintext after caller finishes restoring its state.
pub fn wipe(bytes: []u8) void {
    for (bytes) |*byte| {
        const volatile_byte: *volatile u8 = byte;
        volatile_byte.* = 0;
    }
    std.debug.assert(bytes.len == 0 or bytes[0] == 0);
}

fn validate_storage(storage: Storage) Error!void {
    if (storage.plaintext.len == 0 or storage.ciphertext.len == 0) return error.ScratchTooSmall;
    if (storage.ciphertext.len > max_ciphertext_bytes) return error.CiphertextTooLarge;
    if (overlaps(storage.plaintext, storage.ciphertext) or overlaps(storage.plaintext, storage.publish_scratch) or overlaps(storage.ciphertext, storage.publish_scratch)) return error.StorageAliased;
    std.debug.assert(!overlaps(storage.plaintext, storage.ciphertext));
    std.debug.assert(!overlaps(storage.plaintext, storage.publish_scratch));
}

/// Record views must not alias a serialization destination because `write_record`
/// streams fields into it and must preserve every caller byte on rejection.
fn validate_record_storage(record: Record, storage: Storage) Error!void {
    const fields = record_fields(record);
    const storage_regions = [_][]const u8{ storage.plaintext, storage.ciphertext, storage.publish_scratch };
    for (storage_regions) |region| for (fields) |field| if (overlaps(field, region)) return error.StorageAliased;
    std.debug.assert(!overlaps(record.result, storage.plaintext));
    std.debug.assert(!overlaps(record.result, storage.ciphertext));
}

fn record_fields(record: Record) [7][]const u8 {
    return .{ record.source_paths.base orelse "", record.source_paths.left, record.source_paths.right, record.engine.name, record.engine.version, record.provenance, record.result };
}

fn encoded_len(record: Record) Error!usize {
    try validate_record(record);
    var length: usize = magic.len + 4 + 4 + 8 + 32 * 4 + 3 + 6 * 4 + 8 + 32;
    const fields = [_][]const u8{ record.source_paths.base orelse "", record.source_paths.left, record.source_paths.right, record.engine.name, record.engine.version, record.provenance, record.result };
    for (fields) |field| length = std.math.add(usize, length, field.len) catch return error.InputTooLarge;
    std.debug.assert(length >= magic.len + 32);
    return length;
}

fn validate_record(record: Record) Error!void {
    const has_base = record.source_paths.base != null;
    if (has_base != (record.identity.base != null)) return error.InvalidRecord;
    if ((record.mode == .three_way) != has_base) return error.InvalidRecord;
    if ((record.mode == .two_way and record.origin == .manual_base) or (record.mode == .three_way and record.origin == .two_way_right)) return error.InvalidRecord;
    for (record_fields(record)) |field| if (std.math.cast(u32, field.len) == null) return error.InputTooLarge;
    if (record.source_paths.left.len == 0 or record.source_paths.right.len == 0 or record.engine.name.len == 0 or record.engine.version.len == 0) return error.InvalidRecord;
    for ([_][]const u8{ record.source_paths.base orelse "", record.source_paths.left, record.source_paths.right }) |path| {
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidRecord;
        if (path.len >= Controller.path_capacity) return error.InvalidRecord;
    }
    for ([_][]const u8{ record.engine.name, record.engine.version, record.provenance }) |metadata| {
        if (std.mem.indexOfScalar(u8, metadata, 0) != null) return error.InvalidRecord;
    }
    std.debug.assert((record.mode == .three_way) == has_base);
    std.debug.assert(record.source_paths.left.len > 0 and record.source_paths.right.len > 0);
}

fn write_record(record: Record, destination: []u8) Error!void {
    var writer = Writer.init(destination);
    try writer.bytes(magic);
    try writer.write_u32(version);
    try writer.write_u32(if (record.source_paths.base != null) 1 else 0);
    try writer.write_u64(record.generation);
    const base_digest = record.identity.base orelse zero_digest;
    try writer.bytes(&base_digest);
    try writer.bytes(&record.identity.left);
    try writer.bytes(&record.identity.right);
    var result_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(record.result, &result_digest, .{});
    try writer.bytes(&result_digest);
    try writer.byte(@backingInt(record.mode));
    try writer.byte(@backingInt(record.origin));
    try writer.byte(@as(u8, @intFromBool(record.reviewed)) | (@as(u8, @intFromBool(record.unresolved)) << 1));
    const fields = [_][]const u8{ record.source_paths.base orelse "", record.source_paths.left, record.source_paths.right, record.engine.name, record.engine.version, record.provenance };
    for (fields) |field| try writer.write_u32(@intCast(field.len));
    try writer.write_u64(record.result.len);
    for (fields) |field| try writer.bytes(field);
    try writer.bytes(record.result);
    var checksum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(destination[0..writer.used], &checksum, .{});
    try writer.bytes(&checksum);
    if (writer.used != destination.len) return error.InvalidRecord;
    std.debug.assert(writer.used == destination.len);
    std.debug.assert(destination.len >= checksum.len);
}

fn parse_record(plaintext: []u8) Error!Decoded {
    var reader = Reader.init(plaintext);
    if (!std.mem.eql(u8, try reader.bytes(magic.len), magic)) return error.CorruptRecord;
    if (try reader.read_u32() != version) return error.WrongVersion;
    const flags = try reader.read_u32();
    if (flags > 1) return error.CorruptRecord;
    const generation = try reader.read_u64();
    const base_hash = try reader.array(32);
    const left_hash = try reader.array(32);
    const right_hash = try reader.array(32);
    const expected_result_hash = try reader.array(32);
    const mode_value = try reader.byte();
    const origin_value = try reader.byte();
    const state_flags = try reader.byte();
    if (mode_value > @backingInt(session.Mode.three_way) or origin_value > @backingInt(session.Origin.edited) or state_flags > 3) return error.CorruptRecord;
    var lengths: [6]usize = undefined;
    for (&lengths) |*length| length.* = try reader.usize_u32();
    const result_len = try reader.usize_u64();
    var fields: [6][]const u8 = undefined;
    for (&fields, lengths) |*field, length| field.* = try reader.bytes(length);
    const result = try reader.bytes(result_len);
    const checksum_start = reader.used;
    const checksum = try reader.bytes(32);
    if (reader.remaining() != 0) return error.CorruptRecord;
    var actual_checksum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(plaintext[0..checksum_start], &actual_checksum, .{});
    if (!std.mem.eql(u8, checksum, &actual_checksum)) return error.CorruptRecord;
    var actual_result_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(result, &actual_result_hash, .{});
    if (!std.mem.eql(u8, &expected_result_hash, &actual_result_hash)) return error.CorruptRecord;
    if ((flags == 1) != (fields[0].len != 0) or fields[1].len == 0 or fields[2].len == 0 or fields[3].len == 0 or fields[4].len == 0) return error.CorruptRecord;
    const identity: session.InputIdentity = .{ .base = if (flags == 1) base_hash else null, .left = left_hash, .right = right_hash };
    const decoded: Decoded = .{ .mode = @fromBackingInt(@intCast(mode_value)), .generation = generation, .identity = identity, .source_paths = .{ .base = if (flags == 1) fields[0] else null, .left = fields[1], .right = fields[2] }, .result = result, .origin = @fromBackingInt(@intCast(origin_value)), .reviewed = (state_flags & 1) != 0, .unresolved = (state_flags & 2) != 0, .engine = .{ .name = fields[3], .version = fields[4] }, .provenance = fields[5] };
    validate_record(.{ .mode = decoded.mode, .generation = decoded.generation, .identity = decoded.identity, .source_paths = decoded.source_paths, .result = decoded.result, .origin = decoded.origin, .reviewed = decoded.reviewed, .unresolved = decoded.unresolved, .engine = decoded.engine, .provenance = decoded.provenance }) catch return error.CorruptRecord;
    return decoded;
}

fn blob(bytes: []const u8) Error!Blob {
    const len = std.math.cast(u32, bytes.len) orelse return error.InputTooLarge;
    return .{ .cbData = len, .pbData = if (bytes.len == 0) null else @constCast(bytes.ptr) };
}

fn native_slice(value: Blob) []u8 {
    if (value.cbData == 0) return &.{};
    const pointer = value.pbData orelse return &.{};
    return pointer[0..value.cbData];
}

fn free_blob(value: *Blob, sensitive: bool) void {
    if (value.pbData) |pointer| {
        if (sensitive) wipe(pointer[0..value.cbData]);
        const unfreed = LocalFree(@ptrCast(pointer));
        std.debug.assert(unfreed == null);
    }
    value.* = .{ .cbData = 0, .pbData = null };
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

const Writer = struct {
    destination: []u8,
    used: usize = 0,
    fn init(destination: []u8) Writer {
        return .{ .destination = destination };
    }
    fn bytes(self: *Writer, source: []const u8) Error!void {
        if (source.len > self.destination.len -| self.used) return error.ScratchTooSmall;
        @memcpy(self.destination[self.used..][0..source.len], source);
        self.used += source.len;
    }
    fn byte(self: *Writer, value: u8) Error!void {
        try self.bytes(&.{value});
    }
    fn write_u32(self: *Writer, value: u32) Error!void {
        var encoded: [4]u8 = undefined;
        std.mem.writeInt(u32, &encoded, value, .little);
        try self.bytes(&encoded);
    }
    fn write_u64(self: *Writer, value: u64) Error!void {
        var encoded: [8]u8 = undefined;
        std.mem.writeInt(u64, &encoded, value, .little);
        try self.bytes(&encoded);
    }
};

const Reader = struct {
    source: []const u8,
    used: usize = 0,
    fn init(source: []const u8) Reader {
        return .{ .source = source };
    }
    fn bytes(self: *Reader, length: usize) Error![]const u8 {
        if (length > self.source.len -| self.used) return error.CorruptRecord;
        const result = self.source[self.used..][0..length];
        self.used += length;
        return result;
    }
    fn byte(self: *Reader) Error!u8 {
        return (try self.bytes(1))[0];
    }
    fn read_u32(self: *Reader) Error!u32 {
        var encoded: [4]u8 = undefined;
        @memcpy(&encoded, try self.bytes(4));
        return std.mem.readInt(u32, &encoded, .little);
    }
    fn read_u64(self: *Reader) Error!u64 {
        var encoded: [8]u8 = undefined;
        @memcpy(&encoded, try self.bytes(8));
        return std.mem.readInt(u64, &encoded, .little);
    }
    fn usize_u32(self: *Reader) Error!usize {
        return @intCast(try self.read_u32());
    }
    fn usize_u64(self: *Reader) Error!usize {
        return std.math.cast(usize, try self.read_u64()) orelse error.CorruptRecord;
    }
    fn array(self: *Reader, comptime length: usize) Error![length]u8 {
        var result: [length]u8 = undefined;
        @memcpy(&result, try self.bytes(length));
        return result;
    }
    fn remaining(self: *const Reader) usize {
        return self.source.len - self.used;
    }
};

test "recovery record validation rejects inconsistent identities before DPAPI" {
    const empty_hash = std.mem.zeroes([32]u8);
    const record: Record = .{ .mode = .two_way, .generation = 1, .identity = .{ .base = null, .left = empty_hash, .right = empty_hash }, .source_paths = .{ .base = "base", .left = "left", .right = "right" }, .result = "x", .origin = .two_way_right, .reviewed = false, .unresolved = false, .engine = .{ .name = "text", .version = "1" }, .provenance = "manual" };
    try std.testing.expectError(error.InvalidRecord, encoded_len(record));
}

test "recovery unsupported platform never invokes native protection" {
    if (comptime builtin.os.tag == .windows) return;
    var plaintext: [512]u8 = undefined;
    var ciphertext: [512]u8 = undefined;
    var publish_scratch: [48]u8 = undefined;
    const hash = std.mem.zeroes([32]u8);
    const record: Record = .{ .mode = .two_way, .generation = 1, .identity = .{ .base = null, .left = hash, .right = hash }, .source_paths = .{ .base = null, .left = "left", .right = "right" }, .result = "\xef\xbb\xbfresult\r\n\x00\xff", .origin = .two_way_right, .reviewed = false, .unresolved = false, .engine = .{ .name = "byte_review", .version = "1" }, .provenance = "test" };
    try std.testing.expectError(error.UnsupportedPlatform, encode(record, .{ .plaintext = &plaintext, .ciphertext = &ciphertext, .publish_scratch = &publish_scratch }));
}

test "recovery parser rejects truncation and checksum mismatch" {
    var plaintext: [256]u8 = undefined;
    @memset(&plaintext, 0);
    try std.testing.expectError(error.CorruptRecord, parse_record(plaintext[0..0]));
    @memcpy(plaintext[0..magic.len], magic);
    var version_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &version_bytes, version + 1, .little);
    @memcpy(plaintext[magic.len..][0..version_bytes.len], &version_bytes);
    try std.testing.expectError(error.WrongVersion, parse_record(plaintext[0 .. magic.len + 4]));
    std.mem.writeInt(u32, &version_bytes, version, .little);
    @memcpy(plaintext[magic.len..][0..version_bytes.len], &version_bytes);
    try std.testing.expectError(error.CorruptRecord, parse_record(plaintext[0 .. magic.len + 4]));
}

test "recovery decrypt alias rejection preserves ciphertext caller input" {
    var shared: [64]u8 = @splat(0xa5);
    const before = shared;
    try std.testing.expectError(error.StorageAliased, decode(shared[0..], shared[0..]));
    try std.testing.expectEqualSlices(u8, &before, &shared);
}

test "recovery serialization preserves metadata and rejects invalid mode combinations" {
    const hash = std.mem.zeroes([32]u8);
    const valid: Record = .{ .mode = .three_way, .generation = 7, .identity = .{ .base = hash, .left = hash, .right = hash }, .source_paths = .{ .base = "base", .left = "left", .right = "right" }, .result = "\x00result\xff", .origin = .edited, .reviewed = true, .unresolved = false, .engine = .{ .name = "engine", .version = "v1" }, .provenance = "provenance" };
    var plaintext: [512]u8 = undefined;
    const length = try encoded_len(valid);
    try write_record(valid, plaintext[0..length]);
    const decoded = try parse_record(plaintext[0..length]);
    try std.testing.expectEqual(valid.mode, decoded.mode);
    try std.testing.expectEqual(valid.identity, decoded.identity);
    try std.testing.expectEqualStrings(valid.source_paths.base.?, decoded.source_paths.base.?);
    try std.testing.expectEqualStrings(valid.result, decoded.result);
    try std.testing.expectEqualStrings(valid.engine.name, decoded.engine.name);
    try std.testing.expectEqualStrings(valid.provenance, decoded.provenance);
    plaintext[0] ^= 1;
    try std.testing.expectError(error.CorruptRecord, parse_record(plaintext[0..length]));
    const invalid: Record = .{ .mode = .two_way, .generation = 1, .identity = .{ .base = null, .left = hash, .right = hash }, .source_paths = .{ .base = null, .left = "left", .right = "right" }, .result = "result", .origin = .manual_base, .reviewed = false, .unresolved = false, .engine = .{ .name = "engine", .version = "v1" }, .provenance = "test" };
    try std.testing.expectError(error.InvalidRecord, encoded_len(invalid));
}

test "recovery rejects serialization aliases without modifying caller bytes" {
    const hash = std.mem.zeroes([32]u8);
    var backing: [512]u8 = @splat(0xa5);
    var ciphertext: [512]u8 = undefined;
    var publish_scratch: [48]u8 = undefined;
    const before = backing;
    const record: Record = .{ .mode = .two_way, .generation = 1, .identity = .{ .base = null, .left = hash, .right = hash }, .source_paths = .{ .base = null, .left = "left", .right = "right" }, .result = backing[0..6], .origin = .edited, .reviewed = false, .unresolved = true, .engine = .{ .name = "engine", .version = "v1" }, .provenance = "test" };
    try std.testing.expectError(error.StorageAliased, validate_record_storage(record, .{ .plaintext = &backing, .ciphertext = &ciphertext, .publish_scratch = &publish_scratch }));
    try std.testing.expectEqualSlices(u8, &before, &backing);
}

test "recovery restore revalidates source hashes and remains unresolved" {
    var base = [_]u8{'b'};
    var left = [_]u8{'l'};
    var right = [_]u8{'r'};
    var result: [8]u8 = undefined;
    var scratch: [8]u8 = undefined;
    var history: [32]u8 = undefined;
    var records: [4]session.Record = undefined;
    var active = try session.Session.init(.{ .base = &base, .left = &left, .right = &right }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records });
    const decoded = Decoded{ .mode = .three_way, .generation = 1, .identity = active.input_identity, .source_paths = .{ .base = "base", .left = "left", .right = "right" }, .result = "draft", .origin = .edited, .reviewed = true, .unresolved = false, .engine = .{ .name = "engine", .version = "v1" }, .provenance = "test" };
    left[0] = 'L';
    try std.testing.expectError(error.ChangedInput, restore_into(&active, decoded));
    left[0] = 'l';
    try restore_into(&active, decoded);
    try std.testing.expectEqualStrings("draft", active.result());
    try std.testing.expect(active.current_state().unresolved and !active.current_state().reviewed);
}

test "recovery pool exhaustion is rejected before DPAPI or filesystem I/O" {
    const hash = std.mem.zeroes([32]u8);
    const record: Record = .{ .mode = .two_way, .generation = 1, .identity = .{ .base = null, .left = hash, .right = hash }, .source_paths = .{ .base = null, .left = "left", .right = "right" }, .result = "bytes", .origin = .two_way_right, .reviewed = false, .unresolved = false, .engine = .{ .name = "text", .version = "1" }, .provenance = "test" };
    var plaintext: [1]u8 = undefined;
    var ciphertext: [512]u8 = undefined;
    var publish_scratch: [48]u8 = undefined;
    if (comptime builtin.os.tag == .windows) try std.testing.expectError(error.ScratchTooSmall, encode(record, .{ .plaintext = &plaintext, .ciphertext = &ciphertext, .publish_scratch = &publish_scratch }));
}

/// One bounded worker encrypts immutable draft snapshots and publishes only new files.
/// It never logs or creates plaintext files; all DPAPI and filesystem work runs off UI.
pub const Controller = struct {
    pub const path_capacity = std.Io.Dir.max_path_bytes;
    pub const result_capacity = 192 * 1024;
    pub const plaintext_capacity = result_capacity + path_capacity * 4 + 4096;
    pub const ciphertext_capacity = plaintext_capacity + 16 * 1024;
    pub const State = enum { idle, pending, succeeded, failed };
    pub const Observed = union(enum) { idle, pending, succeeded: output.Receipt, failed: anyerror };

    pub const Storage = struct {
        destination: []u8,
        paths: [3][]u8,
        engine: []u8,
        engine_version: []u8,
        provenance: []u8,
        result: []u8,
        plaintext: []u8,
        ciphertext: []u8,
        publish_scratch: []u8,

        pub fn valid(self: @This()) bool {
            const regions = [_][]u8{ self.destination, self.paths[0], self.paths[1], self.paths[2], self.engine, self.engine_version, self.provenance, self.result, self.plaintext, self.ciphertext, self.publish_scratch };
            const capacities = [_]usize{ path_capacity, path_capacity, path_capacity, path_capacity, 256, 64, 1024, result_capacity, plaintext_capacity, ciphertext_capacity, 48 };
            for (regions, capacities) |region, capacity| if (region.len != capacity) return false;
            for (regions, 0..) |region, index| {
                for (regions[index + 1 ..]) |other| if (overlaps(region, other)) return false;
            }
            return true;
        }
    };

    io: std.Io,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    stopping: bool = false,
    ready: bool = false,
    running: bool = false,
    state: State = .idle,
    failure: anyerror = error.Unexpected,
    receipt: output.Receipt = undefined,

    storage: Controller.Storage,
    destination_len: usize = 0,
    path_lens: [3]usize = .{ 0, 0, 0 },
    engine_len: usize = 0,
    engine_version_len: usize = 0,
    provenance_len: usize = 0,
    result_len: usize = 0,
    mode: session.Mode = .two_way,
    generation: u64 = 0,
    identity: session.InputIdentity = std.mem.zeroes(session.InputIdentity),
    origin: session.Origin = .two_way_right,
    reviewed: bool = false,
    unresolved: bool = true,

    pub fn init(self: *Controller, io: std.Io, storage: Controller.Storage) !void {
        if (!storage.valid()) return error.ScratchTooSmall;
        self.* = .{ .io = io, .storage = storage };
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
        std.debug.assert(self.thread != null);
    }

    pub fn deinit(self: *Controller) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.wake.signal(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        wipe(self.storage.plaintext);
        wipe(self.storage.result);
    }

    pub fn request(self: *Controller, destination: []const u8, value: Record) !void {
        try validate_record(value);
        if (destination.len == 0 or destination.len >= self.storage.destination.len or std.mem.indexOfScalar(u8, destination, 0) != null or value.result.len > self.storage.result.len or value.engine.name.len > self.storage.engine.len or value.engine.version.len > self.storage.engine_version.len or value.provenance.len > self.storage.provenance.len) return error.InputTooLarge;
        if (record_aliases_controller(self, destination, value)) return error.StorageAliased;
        const required_plaintext = try encoded_len(value);
        if (required_plaintext > self.storage.plaintext.len) return error.ScratchTooSmall;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping or self.ready or self.running) return error.Busy;
        try copy_checked(self.storage.destination, &self.destination_len, destination);
        try copy_checked(self.storage.paths[0], &self.path_lens[0], value.source_paths.base orelse "");
        try copy_checked(self.storage.paths[1], &self.path_lens[1], value.source_paths.left);
        try copy_checked(self.storage.paths[2], &self.path_lens[2], value.source_paths.right);
        try copy_checked(self.storage.engine, &self.engine_len, value.engine.name);
        try copy_checked(self.storage.engine_version, &self.engine_version_len, value.engine.version);
        try copy_checked(self.storage.provenance, &self.provenance_len, value.provenance);
        @memcpy(self.storage.result[0..value.result.len], value.result);
        self.result_len = value.result.len;
        self.mode = value.mode;
        self.generation = value.generation;
        self.identity = value.identity;
        self.origin = value.origin;
        self.reviewed = value.reviewed;
        self.unresolved = value.unresolved;
        self.state = .pending;
        self.ready = true;
        self.wake.signal(self.io);
    }

    pub fn observe(self: *Controller) Observed {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return switch (self.state) {
            .idle => .idle,
            .pending => .pending,
            .succeeded => .{ .succeeded = self.receipt },
            .failed => .{ .failed = self.failure },
        };
    }

    fn worker(self: *Controller) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.stopping and !self.ready) self.wake.waitUncancelable(self.io, &self.mutex);
            if (self.stopping and !self.ready) {
                self.mutex.unlock(self.io);
                return;
            }
            self.ready = false;
            self.running = true;
            self.mutex.unlock(self.io);
            const outcome = self.publish_snapshot();
            self.mutex.lockUncancelable(self.io);
            self.running = false;
            if (outcome) |receipt| {
                self.receipt = receipt;
                self.state = .succeeded;
            } else |err| {
                self.failure = err;
                self.state = .failed;
            }
            self.mutex.unlock(self.io);
        }
    }

    fn publish_snapshot(self: *Controller) !output.Receipt {
        const value = Record{ .mode = self.mode, .generation = self.generation, .identity = self.identity, .source_paths = .{ .base = if (self.path_lens[0] == 0) null else self.storage.paths[0][0..self.path_lens[0]], .left = self.storage.paths[1][0..self.path_lens[1]], .right = self.storage.paths[2][0..self.path_lens[2]] }, .result = self.storage.result[0..self.result_len], .origin = self.origin, .reviewed = self.reviewed, .unresolved = self.unresolved, .engine = .{ .name = self.storage.engine[0..self.engine_len], .version = self.storage.engine_version[0..self.engine_version_len] }, .provenance = self.storage.provenance[0..self.provenance_len] };
        return publish(self.io, self.storage.destination[0..self.destination_len], value, .{ .plaintext = self.storage.plaintext, .ciphertext = self.storage.ciphertext, .publish_scratch = self.storage.publish_scratch });
    }
};

/// Automatic encrypted journal primitive. Caller proves `directory` is protected for this user,
/// created it explicitly, and invokes `poll` from a worker, never a latency-sensitive UI callback.
/// No filesystem discovery or ACL assertion is performed here.
const LegacyJournal = struct {
    pub const interval_ns: u64 = 500 * std.time.ns_per_ms;
    pub const guarantee_ns: u64 = std.time.ns_per_s;
    pub const State = enum { idle, pending, healthy, stale, failure };
    pub const Status = struct { state: State, unsaved_ns: u64, deadline_ns: ?u64, generation: u64, failure: ?anyerror };

    io: std.Io,
    directory: []const u8,
    storage: Controller.Storage,
    nonce: [16]u8,
    pending_record: Record = undefined,
    generation: u64 = 0,
    dirty_since_ns: u64 = 0,
    last_durable_ns: ?u64 = null,
    deadline_ns: ?u64 = null,
    state: State = .idle,
    failure: ?anyerror = null,
    current_path: [Controller.path_capacity]u8 = undefined,
    current_path_len: usize = 0,
    previous_path: [Controller.path_capacity]u8 = undefined,
    previous_path_len: usize = 0,
    owned_path: [Controller.path_capacity]u8 = undefined,
    owned_path_len: usize = 0,
    path_lens: [3]usize = .{ 0, 0, 0 },
    engine_len: usize = 0,
    engine_version_len: usize = 0,
    provenance_len: usize = 0,
    result_len: usize = 0,

    /// `directory` is an explicit caller-owned protected session directory path.
    /// Caller must establish protection before init; this API makes no ACL claim.
    pub fn init(io: std.Io, directory: []const u8, storage: Controller.Storage) !LegacyJournal {
        if (!storage.valid()) return error.ScratchTooSmall;
        if (directory.len == 0 or directory.len >= Controller.path_capacity or std.mem.indexOfScalar(u8, directory, 0) != null) return error.InvalidDirectory;
        var journal: LegacyJournal = .{ .io = io, .directory = directory, .storage = storage, .nonce = undefined };
        try io.randomSecure(&journal.nonce);
        return journal;
    }

    /// Copies all generation inputs into fixed storage; busy/failure never replaces durable evidence.
    pub fn request(self: *LegacyJournal, now_ns: u64, value: Record) !void {
        try validate_record(value);
        if (value.result.len > self.storage.result.len or value.engine.name.len > self.storage.engine.len or value.engine.version.len > self.storage.engine_version.len or value.provenance.len > self.storage.provenance.len) return error.InputTooLarge;
        if (record_aliases_controller_storage(self.storage, value)) return error.StorageAliased;
        const plaintext_len = try encoded_len(value);
        if (plaintext_len > self.storage.plaintext.len) return error.ScratchTooSmall;
        const first_dirty = self.last_durable_ns == null or self.state == .idle or self.state == .healthy;
        try copy_checked(self.storage.paths[0], &self.path_lens[0], value.source_paths.base orelse "");
        try copy_checked(self.storage.paths[1], &self.path_lens[1], value.source_paths.left);
        try copy_checked(self.storage.paths[2], &self.path_lens[2], value.source_paths.right);
        try copy_checked(self.storage.engine, &self.engine_len, value.engine.name);
        try copy_checked(self.storage.engine_version, &self.engine_version_len, value.engine.version);
        try copy_checked(self.storage.provenance, &self.provenance_len, value.provenance);
        @memcpy(self.storage.result[0..value.result.len], value.result);
        self.result_len = value.result.len;
        self.pending_record = value;
        self.pending_record.source_paths = .{ .base = if (self.path_lens[0] == 0) null else self.storage.paths[0][0..self.path_lens[0]], .left = self.storage.paths[1][0..self.path_lens[1]], .right = self.storage.paths[2][0..self.path_lens[2]] };
        self.pending_record.engine = .{ .name = self.storage.engine[0..self.engine_len], .version = self.storage.engine_version[0..self.engine_version_len] };
        self.pending_record.provenance = self.storage.provenance[0..self.provenance_len];
        self.pending_record.result = self.storage.result[0..self.result_len];
        self.generation = value.generation;
        if (first_dirty) self.dirty_since_ns = now_ns;
        self.deadline_ns = deadline_for(now_ns, self.dirty_since_ns, self.last_durable_ns);
        self.state = .pending;
        self.failure = null;
    }

    /// Runs one immutable pending generation when due; call repeatedly from bounded worker loop.
    pub fn poll(self: *LegacyJournal, now_ns: u64) !bool {
        const due = self.deadline_ns orelse return false;
        if (now_ns < due) return false;
        self.state = .pending;
        self.remember_previous();
        const path = self.generation_path(self.generation) catch |err| {
            self.failure = err;
            self.state = if (self.stale_at(now_ns)) .stale else .failure;
            self.deadline_ns = add_saturating(now_ns, interval_ns);
            return err;
        };
        const receipt = publish(self.io, path, self.pending_record, .{ .plaintext = self.storage.plaintext, .ciphertext = self.storage.ciphertext, .publish_scratch = self.storage.publish_scratch }) catch |err| {
            self.failure = err;
            self.state = if (self.stale_at(now_ns)) .stale else .failure;
            self.deadline_ns = add_saturating(now_ns, interval_ns);
            if (err == error.PublishedNotDurable) self.remember_path(path);
            return err;
        };
        _ = receipt;
        self.remember_previous();
        self.remember_path(path);
        self.last_durable_ns = now_ns;
        self.dirty_since_ns = now_ns;
        self.deadline_ns = null;
        self.failure = null;
        self.state = .healthy;
        self.delete_previous_owned();
        return true;
    }

    /// Cancels only pending journal work; in-memory draft and existing recovery files remain untouched.
    pub fn cancel(self: *LegacyJournal) void {
        self.deadline_ns = null;
        self.failure = null;
        self.state = if (self.last_durable_ns != null) .healthy else .idle;
    }

    pub fn status(self: *const LegacyJournal, now_ns: u64) Status {
        const unsaved = if (self.state == .healthy or self.state == .idle) 0 else elapsed(now_ns, self.dirty_since_ns);
        const state: State = if (self.state != .healthy and self.state != .idle and self.stale_at(now_ns)) .stale else self.state;
        return .{ .state = state, .unsaved_ns = unsaved, .deadline_ns = self.deadline_ns, .generation = self.generation, .failure = self.failure };
    }

    fn stale_at(self: *const LegacyJournal, now_ns: u64) bool {
        const change_age = elapsed(now_ns, self.dirty_since_ns);
        const durable_age = if (self.last_durable_ns) |durable| elapsed(now_ns, durable) else change_age;
        return change_age >= guarantee_ns or durable_age >= guarantee_ns;
    }

    fn generation_path(self: *LegacyJournal, generation: u64) ![]const u8 {
        const separator: []const u8 = if (self.directory[self.directory.len - 1] == '/' or self.directory[self.directory.len - 1] == '\\') "" else "/";
        const name = "warkocz-recovery-";
        const end = try std.fmt.bufPrint(self.current_path[0..], "{s}{s}{s}-{x}-{d}.bin", .{ self.directory, separator, name, self.nonce, generation });
        self.current_path_len = end.len;
        return self.current_path[0..end.len];
    }

    fn remember_previous(self: *LegacyJournal) void {
        self.previous_path_len = self.owned_path_len;
        if (self.previous_path_len != 0) @memcpy(self.previous_path[0..self.previous_path_len], self.owned_path[0..self.owned_path_len]);
    }

    fn remember_path(self: *LegacyJournal, path: []const u8) void {
        self.current_path_len = path.len;
        self.owned_path_len = path.len;
        if (!overlaps(path, self.owned_path[0..path.len])) @memcpy(self.owned_path[0..path.len], path);
    }

    fn delete_previous_owned(self: *LegacyJournal) void {
        if (self.previous_path_len == 0 or std.mem.eql(u8, self.previous_path[0..self.previous_path_len], self.current_path[0..self.current_path_len])) return;
        std.Io.Dir.cwd().deleteFile(self.io, self.previous_path[0..self.previous_path_len]) catch return;
        self.previous_path_len = 0;
    }
};

fn record_aliases_controller_storage(storage: Controller.Storage, value: Record) bool {
    const owned = [_][]const u8{ storage.destination, storage.paths[0], storage.paths[1], storage.paths[2], storage.engine, storage.engine_version, storage.provenance, storage.result, storage.plaintext, storage.ciphertext, storage.publish_scratch };
    for (owned) |region| for (record_fields(value)) |field| if (overlaps(region, field)) return true;
    return false;
}

fn add_saturating(left: u64, right: u64) u64 {
    return std.math.add(u64, left, right) catch std.math.maxInt(u64);
}

fn elapsed(now_ns: u64, since_ns: u64) u64 {
    return now_ns -| since_ns;
}

fn deadline_for(now_ns: u64, dirty_since_ns: u64, last_durable_ns: ?u64) u64 {
    const debounce_deadline = add_saturating(dirty_since_ns, LegacyJournal.interval_ns);
    const durable_deadline = add_saturating(last_durable_ns orelse dirty_since_ns, LegacyJournal.guarantee_ns);
    return @min(add_saturating(now_ns, LegacyJournal.interval_ns), @min(debounce_deadline, durable_deadline));
}

test "journal deadlines coalesce to latest generation and expose stale unsaved age" {
    var journal: LegacyJournal = undefined;
    journal.state = .idle;
    journal.last_durable_ns = null;
    journal.deadline_ns = null;
    journal.dirty_since_ns = 0;
    journal.generation = 0;
    journal.failure = null;
    // Scheduler arithmetic is shared by request and status; no filesystem or profile path is touched.
    const first_deadline = deadline_for(10, 10, null);
    const coalesced_deadline = deadline_for(20, 10, null);
    try std.testing.expectEqual(@as(u64, 500 * std.time.ns_per_ms + 10), first_deadline);
    try std.testing.expectEqual(first_deadline, coalesced_deadline);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), deadline_for(950_000_000, 950_000_000, 0));
    try std.testing.expect(add_saturating(2, LegacyJournal.guarantee_ns) >= LegacyJournal.guarantee_ns);
    journal.dirty_since_ns = 4;
    journal.deadline_ns = coalesced_deadline;
    journal.state = .pending;
    const stale = journal.status(LegacyJournal.guarantee_ns + 5);
    try std.testing.expectEqual(LegacyJournal.State.stale, stale.state);
    try std.testing.expectEqual(LegacyJournal.guarantee_ns + 1, stale.unsaved_ns);
    journal.cancel();
    try std.testing.expectEqual(LegacyJournal.State.idle, journal.state);
    try std.testing.expect(journal.deadline_ns == null);
}

test "journal cancellation and failure preserve pending generation and prior evidence" {
    const hash = std.mem.zeroes([32]u8);
    const record: Record = .{ .mode = .two_way, .generation = 3, .identity = .{ .base = null, .left = hash, .right = hash }, .source_paths = .{ .base = null, .left = "left", .right = "right" }, .result = "draft", .origin = .edited, .reviewed = false, .unresolved = true, .engine = .{ .name = "engine", .version = "1" }, .provenance = "test" };
    try std.testing.expectEqual(@as(usize, 5), record.result.len);
    try std.testing.expectEqual(@as(u64, 500 * std.time.ns_per_ms), LegacyJournal.interval_ns);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), LegacyJournal.guarantee_ns);
}

test "recovery controller storage rejects same-capacity overlap" {
    const total = Controller.path_capacity * 4 + 256 + 64 + 1024 + Controller.result_capacity + Controller.plaintext_capacity + Controller.ciphertext_capacity + 48;
    const backing = try std.testing.allocator.alloc(u8, total);
    defer std.testing.allocator.free(backing);
    var offset: usize = 0;
    const destination = backing[offset..][0..Controller.path_capacity];
    offset += Controller.path_capacity;
    const path2 = backing[offset..][0..Controller.path_capacity];
    offset += Controller.path_capacity;
    const path3 = backing[offset..][0..Controller.path_capacity];
    offset += Controller.path_capacity;
    const engine = backing[offset..][0..256];
    offset += 256;
    const engine_version = backing[offset..][0..64];
    offset += 64;
    const provenance = backing[offset..][0..1024];
    offset += 1024;
    const result = backing[offset..][0..Controller.result_capacity];
    offset += Controller.result_capacity;
    const plaintext = backing[offset..][0..Controller.plaintext_capacity];
    offset += Controller.plaintext_capacity;
    const ciphertext = backing[offset..][0..Controller.ciphertext_capacity];
    offset += Controller.ciphertext_capacity;
    const publish_scratch = backing[offset..][0..48];
    const storage: Controller.Storage = .{ .destination = destination, .paths = .{ destination, path2, path3 }, .engine = engine, .engine_version = engine_version, .provenance = provenance, .result = result, .plaintext = plaintext, .ciphertext = ciphertext, .publish_scratch = publish_scratch };
    try std.testing.expectEqual(Controller.path_capacity, storage.paths[0].len);
    try std.testing.expect(!storage.valid());
}

fn record_aliases_controller(self: *const Controller, destination: []const u8, value: Record) bool {
    const owned = [_][]const u8{ self.storage.destination, self.storage.paths[0], self.storage.paths[1], self.storage.paths[2], self.storage.engine, self.storage.engine_version, self.storage.provenance, self.storage.result, self.storage.plaintext, self.storage.ciphertext, self.storage.publish_scratch };
    const borrowed = [_][]const u8{ destination, value.source_paths.base orelse "", value.source_paths.left, value.source_paths.right, value.engine.name, value.engine.version, value.provenance, value.result };
    for (owned) |storage| for (borrowed) |input| if (overlaps(storage, input)) return true;
    return false;
}

fn copy_checked(destination: []u8, length: *usize, source: []const u8) !void {
    if (source.len == 0 and destination.len != 0) {
        length.* = 0;
        return;
    }
    if (source.len > destination.len) return error.InputTooLarge;
    @memcpy(destination[0..source.len], source);
    length.* = source.len;
}

/// Automatic journal with one persistent worker.
/// `directory` is a verified capability, not a caller assertion.
pub const Journal = struct {
    pub const interval_ns: u64 = 500 * std.time.ns_per_ms;
    pub const guarantee_ns: u64 = std.time.ns_per_s;
    pub const Clock = *const fn () u64;
    pub const State = enum { idle, pending, publishing, healthy, degraded, cancelled };
    pub const Status = struct { state: State, dirty_age_ns: u64, generation: u64, failure: ?anyerror };
    pub const Storage = struct {
        directory: []u8,
        snapshots: [2]Controller.Storage,

        pub fn valid(self: @This()) bool {
            if (self.directory.len != Controller.path_capacity or !self.snapshots[0].valid() or !self.snapshots[1].valid()) return false;
            for (self.snapshots) |snapshot| {
                const regions = [_][]const u8{ snapshot.destination, snapshot.paths[0], snapshot.paths[1], snapshot.paths[2], snapshot.engine, snapshot.engine_version, snapshot.provenance, snapshot.result, snapshot.plaintext, snapshot.ciphertext, snapshot.publish_scratch };
                for (regions) |region| if (overlaps(self.directory, region)) return false;
            }
            return true;
        }
    };

    io: std.Io,
    clock: Clock,
    storage: Journal.Storage,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    stopping: bool = false,
    ready_slot: ?usize = null,
    running_slot: ?usize = null,
    dirty_since_ns: u64 = 0,
    generation: u64 = 0,
    sequence: u64 = 0,
    state: State = .idle,
    failure: ?anyerror = null,
    owned_paths: [2][Controller.path_capacity]u8 = undefined,
    owned_lens: [2]usize = .{ 0, 0 },
    owned_durable: [2]bool = .{ false, false },
    // Per-slot metadata is fixed storage, never views into caller draft bytes.
    records: [2]Record = undefined,
    lens: [2]SlotLengths = .{ .{}, .{} },
    const SlotLengths = struct { paths: [3]usize = .{ 0, 0, 0 }, engine: usize = 0, engine_version: usize = 0, provenance: usize = 0, result: usize = 0, destination: usize = 0 };

    pub fn init(io: std.Io, owned_directory: *const recovery_directory.Session, storage: Journal.Storage, clock: Clock) !Journal {
        if (!storage.valid() or owned_directory.root.len == 0 or owned_directory.name.len == 0) return error.ScratchTooSmall;
        var value: Journal = .{ .io = io, .clock = clock, .storage = storage };
        const separator: []const u8 = if (owned_directory.root[owned_directory.root.len - 1] == '/' or owned_directory.root[owned_directory.root.len - 1] == '\\') "" else "/";
        const path = try std.fmt.bufPrint(value.storage.directory, "{s}{s}{s}", .{ owned_directory.root, separator, owned_directory.name });
        if (path.len >= value.storage.directory.len) return error.ScratchTooSmall;
        value.storage.directory[path.len] = 0;
        // Caller must place this value at its final address, then call `start`.
        return value;
    }

    /// Starts worker after caller stores Journal at its stable address.
    pub fn start(self: *Journal) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.thread != null or self.stopping) return error.Busy;
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
    }

    pub fn deinit(self: *Journal) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.wake.signal(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        for (self.storage.snapshots) |snapshot| {
            wipe(snapshot.plaintext);
            wipe(snapshot.result);
        }
    }

    /// UI copies immutable input only; encryption and filesystem I/O remain worker-only.
    pub fn request(self: *Journal, value: Record) !void {
        try validate_record(value);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping) return error.Busy;
        const slot = if (self.running_slot) |running| 1 - running else 0;
        try self.copy_snapshot(slot, value);
        self.ready_slot = slot;
        self.generation = value.generation;
        if (self.state == .idle or self.state == .healthy or self.state == .cancelled) self.dirty_since_ns = self.clock();
        self.state = .pending;
        self.failure = null;
        self.wake.signal(self.io);
    }

    pub fn status(self: *Journal) Status {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const age = if (self.state == .idle or self.state == .healthy) 0 else elapsed(self.clock(), self.dirty_since_ns);
        const shown = if (self.state != .idle and self.state != .healthy and age > guarantee_ns) .degraded else self.state;
        return .{ .state = shown, .dirty_age_ns = age, .generation = self.generation, .failure = self.failure };
    }

    pub fn cancel(self: *Journal) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.ready_slot = null;
        if (self.running_slot == null) self.state = .cancelled;
        // A running publication reaches its atomic boundary before reporting cancellation.
    }

    fn worker(self: *Journal) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.stopping and self.ready_slot == null) self.wake.waitUncancelable(self.io, &self.mutex);
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            // Debounce before selecting a slot, so typing coalesces into one immutable copy.
            self.mutex.unlock(self.io);
            std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromNanoseconds(interval_ns) }, self.io) catch {};
            self.mutex.lockUncancelable(self.io);
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            const slot = self.ready_slot orelse {
                self.mutex.unlock(self.io);
                continue;
            };
            self.ready_slot = null;
            self.running_slot = slot;
            self.state = .publishing;
            self.mutex.unlock(self.io);
            const outcome = self.publish_slot(slot);
            self.mutex.lockUncancelable(self.io);
            self.running_slot = null;
            if (outcome) |_| {
                self.state = if (self.ready_slot == null) .healthy else .pending;
                self.failure = null;
            } else |err| {
                self.failure = err;
                self.state = .degraded;
            }
            self.mutex.unlock(self.io);
        }
    }

    fn copy_snapshot(self: *Journal, slot: usize, value: Record) !void {
        std.debug.assert(slot < self.storage.snapshots.len);
        const snapshot = &self.storage.snapshots[slot];
        if (value.result.len > snapshot.result.len or value.engine.name.len > snapshot.engine.len or value.engine.version.len > snapshot.engine_version.len or value.provenance.len > snapshot.provenance.len or record_aliases_controller_storage(snapshot.*, value)) return error.ResourceExhausted;
        if (try encoded_len(value) > snapshot.plaintext.len) return error.ResourceExhausted;
        try copy_checked(snapshot.paths[0], self.path_len(slot, 0), value.source_paths.base orelse "");
        try copy_checked(snapshot.paths[1], self.path_len(slot, 1), value.source_paths.left);
        try copy_checked(snapshot.paths[2], self.path_len(slot, 2), value.source_paths.right);
        try copy_checked(snapshot.engine, self.engine_len(slot), value.engine.name);
        try copy_checked(snapshot.engine_version, self.engine_version_len(slot), value.engine.version);
        try copy_checked(snapshot.provenance, self.provenance_len(slot), value.provenance);
        @memcpy(snapshot.result[0..value.result.len], value.result);
        self.result_len(slot).* = value.result.len;
        self.sequence +%= 1;
        const path = try std.fmt.bufPrint(snapshot.destination, "{s}/recovery-{x}-{d}-{d}.bin", .{ self.directory(), self.sequence, value.generation, self.sequence });
        self.destination_len(slot).* = path.len;
        self.records[slot] = value;
    }

    fn path_len(self: *Journal, slot: usize, index: usize) *usize {
        return &self.lens[slot].paths[index];
    }
    fn engine_len(self: *Journal, slot: usize) *usize {
        return &self.lens[slot].engine;
    }
    fn engine_version_len(self: *Journal, slot: usize) *usize {
        return &self.lens[slot].engine_version;
    }
    fn provenance_len(self: *Journal, slot: usize) *usize {
        return &self.lens[slot].provenance;
    }
    fn result_len(self: *Journal, slot: usize) *usize {
        return &self.lens[slot].result;
    }
    fn destination_len(self: *Journal, slot: usize) *usize {
        return &self.lens[slot].destination;
    }
    fn directory(self: *const Journal) []const u8 {
        return self.storage.directory[0..std.mem.indexOfScalar(u8, self.storage.directory, 0).?];
    }

    fn publish_slot(self: *Journal, slot: usize) !output.Receipt {
        if (self.owned_lens[0] != 0 and self.owned_lens[1] != 0) return error.ResourceExhausted;
        const snapshot = &self.storage.snapshots[slot];
        const value = self.records[slot];
        const lengths = self.lens[slot];
        const record = Record{ .mode = value.mode, .generation = value.generation, .identity = value.identity, .source_paths = .{ .base = if (lengths.paths[0] == 0) null else snapshot.paths[0][0..lengths.paths[0]], .left = snapshot.paths[1][0..lengths.paths[1]], .right = snapshot.paths[2][0..lengths.paths[2]] }, .result = snapshot.result[0..lengths.result], .origin = value.origin, .reviewed = value.reviewed, .unresolved = value.unresolved, .engine = .{ .name = snapshot.engine[0..lengths.engine], .version = snapshot.engine_version[0..lengths.engine_version] }, .provenance = snapshot.provenance[0..lengths.provenance] };
        const path = snapshot.destination[0..lengths.destination];
        const receipt = publish(self.io, path, record, .{ .plaintext = snapshot.plaintext, .ciphertext = snapshot.ciphertext, .publish_scratch = snapshot.publish_scratch }) catch |err| {
            if (err == error.PublishedNotDurable) self.track(path, false) catch {};
            return err;
        };
        try self.track(path, true);
        try self.remove_prior_durable(path);
        return receipt;
    }

    fn track(self: *Journal, path: []const u8, durable: bool) !void {
        for (self.owned_lens, 0..) |length, index| if (length != 0 and std.mem.eql(u8, self.owned_paths[index][0..length], path)) {
            self.owned_durable[index] = self.owned_durable[index] or durable;
            return;
        };
        for (&self.owned_lens, 0..) |*length, index| if (length.* == 0) {
            @memcpy(self.owned_paths[index][0..path.len], path);
            length.* = path.len;
            self.owned_durable[index] = durable;
            return;
        };
        return error.ResourceExhausted;
    }

    /// A retention failure is surfaced while current durable evidence remains indexed.
    fn remove_prior_durable(self: *Journal, current: []const u8) !void {
        for (&self.owned_lens, 0..) |*length, index| {
            if (length.* == 0 or !self.owned_durable[index] or std.mem.eql(u8, self.owned_paths[index][0..length.*], current)) continue;
            std.Io.Dir.cwd().deleteFile(self.io, self.owned_paths[index][0..length.*]) catch |err| return err;
            length.* = 0;
            self.owned_durable[index] = false;
            return;
        }
    }
};

fn native_e2e_enabled() bool {
    const environ: std.process.Environ = .{ .block = .global };
    const value = environ.getAlloc(std.testing.allocator, "WARKOCZ_NATIVE_E2E") catch return false;
    defer std.testing.allocator.free(value);
    return std.mem.eql(u8, value, "1");
}

test "Windows DPAPI recovery round trip preserves binary result and rejects corrupt ciphertext" {
    if (comptime builtin.os.tag != .windows) return;
    if (!native_e2e_enabled()) return;
    const io = std.testing.io;
    const root = "C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e";
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, root);
    var fixture_memory: [root.len + 1 + 16]u8 = undefined;
    const fixture = try create_unique_fixture(io, cwd, root, &fixture_memory);
    defer cwd.deleteDir(io, fixture) catch {};
    var path_buffer: [root.len + 1 + 16 + 13]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/recovery.bin", .{fixture});
    var owned = false;
    defer if (owned) cwd.deleteFile(io, path) catch {};
    const hash = std.mem.zeroes([32]u8);
    const result = "\xef\xbb\xbfline\r\nnext\n\x00\xff";
    const record: Record = .{ .mode = .two_way, .generation = 9, .identity = .{ .base = null, .left = hash, .right = hash }, .source_paths = .{ .base = null, .left = "C:/left.bin", .right = "C:/right.bin" }, .result = result, .origin = .edited, .reviewed = true, .unresolved = true, .engine = .{ .name = "byte_review", .version = "1" }, .provenance = "manual-resolution" };
    var plaintext: [1024]u8 = undefined;
    var ciphertext: [2048]u8 = undefined;
    var publish_scratch: [48]u8 = undefined;
    const receipt = try publish(io, path, record, .{ .plaintext = &plaintext, .ciphertext = &ciphertext, .publish_scratch = &publish_scratch });
    owned = true;
    try std.testing.expect(receipt.bytes_written > result.len);
    try std.testing.expect(std.mem.indexOf(u8, ciphertext[0..receipt.bytes_written], result) == null);
    var loaded_ciphertext: [2048]u8 = undefined;
    var loaded_plaintext: [1024]u8 = undefined;
    const decoded = try load(io, path, &loaded_ciphertext, &loaded_plaintext);
    defer wipe(&loaded_plaintext);
    try std.testing.expectEqualStrings(result, decoded.result);
    try std.testing.expect(decoded.reviewed and decoded.unresolved);
    loaded_ciphertext[0] +%= 1;
    try std.testing.expectError(error.CryptUnprotectFailed, decode(loaded_ciphertext[0..receipt.bytes_written], &loaded_plaintext));
}

fn create_unique_fixture(io: std.Io, cwd: std.Io.Dir, root: []const u8, destination: []u8) ![]const u8 {
    if (destination.len != root.len + 1 + 16) return error.InputTooLarge;
    @memcpy(destination[0..root.len], root);
    destination[root.len] = '/';
    var random: [8]u8 = undefined;
    for (0..16) |_| {
        try io.randomSecure(&random);
        for (random, 0..) |byte, index| {
            const alphabet = "0123456789abcdef";
            destination[root.len + 1 + index * 2] = alphabet[byte >> 4];
            destination[root.len + 1 + index * 2 + 1] = alphabet[byte & 0x0f];
        }
        cwd.createDir(io, destination, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |unexpected| return unexpected,
        };
        return destination;
    }
    return error.Busy;
}

test "recovery API compiles" {
    std.testing.refAllDecls(@This());
}
