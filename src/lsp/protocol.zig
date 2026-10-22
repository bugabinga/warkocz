const std = @import("std");

pub const Error = error{ HeaderMalformed, HeaderDuplicate, HeaderConflict, LengthMissing, LengthInvalid, LengthOverflow, FrameTooLarge, WorkBudget, JsonInvalid, BufferTooSmall, InvalidUtf8, InvalidPath, StaleResponse, PendingFull, InvalidPosition, UnsupportedRequest, WriteFailed, InvalidState, InvalidDocument };
pub const HeaderLimit = 1024;
pub const MaxHeaderFields = 16;

/// Incremental framing over caller-owned storage; consume each emitted body before feeding more bytes.
pub const Framer = struct {
    storage: []u8,
    used: usize = 0,
    expected: ?usize = null,

    pub fn init(storage: []u8) Framer {
        return .{ .storage = storage };
    }

    pub fn feed(self: *Framer, input: []const u8, work_budget: usize) Error!usize {
        if (input.len == 0) return 0;
        const amount = @min(input.len, @min(work_budget, self.storage.len - self.used));
        if (amount == 0 and input.len != 0) return error.WorkBudget;
        @memcpy(self.storage[self.used .. self.used + amount], input[0..amount]);
        self.used += amount;
        if (findHeaderEnd(self.storage[0..self.used])) |end| {
            if (end > HeaderLimit) return error.HeaderMalformed;
            self.expected = try parseLength(self.storage[0..end]);
            if (self.expected.? > self.storage.len - end) return error.FrameTooLarge;
        } else if (self.used > HeaderLimit) return error.HeaderMalformed;
        return amount;
    }

    pub fn body(self: *const Framer) ?[]const u8 {
        const end = findHeaderEnd(self.storage[0..self.used]) orelse return null;
        const length = self.expected orelse return null;
        if (self.used - end < length) return null;
        return self.storage[end .. end + length];
    }

    pub fn consume(self: *Framer) Error!void {
        const end = findHeaderEnd(self.storage[0..self.used]) orelse return error.HeaderMalformed;
        const length = self.expected orelse return error.LengthMissing;
        if (self.used - end < length) return error.HeaderMalformed;
        const trailing = self.used - end - length;
        if (trailing > 0) @memmove(self.storage[0..trailing], self.storage[end + length .. self.used]);
        self.used = trailing;
        self.expected = null;
        if (trailing > 0) {
            if (findHeaderEnd(self.storage[0..trailing])) |next_end| {
                self.expected = try parseLength(self.storage[0..next_end]);
                if (self.expected.? > self.storage.len - next_end) return error.FrameTooLarge;
            } else if (trailing > HeaderLimit) return error.HeaderMalformed;
        }
    }
};

fn findHeaderEnd(bytes: []const u8) ?usize {
    if (std.mem.indexOf(u8, bytes, "\r\n\r\n")) |index| return index + 4;
    return null;
}

fn parseLength(header: []const u8) Error!usize {
    var seen_length = false;
    var length: usize = 0;
    var fields: usize = 0;
    var cursor: usize = 0;
    while (cursor < header.len) {
        const end = std.mem.indexOfPos(u8, header, cursor, "\r\n") orelse return error.HeaderMalformed;
        if (end == cursor) break;
        fields += 1;
        if (fields > MaxHeaderFields) return error.HeaderMalformed;
        const line = header[cursor..end];
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.HeaderMalformed;
        if (colon == 0 or line[0] == ' ' or line[0] == '\t') return error.HeaderMalformed;
        const name = line[0..colon];
        for (name) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-')) return error.HeaderMalformed;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            if (seen_length) return error.HeaderDuplicate;
            seen_length = true;
            if (value.len == 0) return error.LengthInvalid;
            for (value) |byte| {
                if (!std.ascii.isDigit(byte)) return error.LengthInvalid;
                length = std.math.mul(usize, length, 10) catch return error.LengthOverflow;
                length = std.math.add(usize, length, byte - '0') catch return error.LengthOverflow;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) return error.HeaderConflict;
        cursor = end + 2;
    }
    if (!seen_length) return error.LengthMissing;
    return length;
}

pub const Position = struct { line: u32, character: u32 };

/// Converts LSP UTF-16 code units to exact UTF-8 byte offsets, refusing CRLF interior positions.
pub fn positionToByte(text: []const u8, position: Position) Error!usize {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    var line: u32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len and line < position.line) : (i += 1) {
        if (text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n') {
            i += 1;
            line += 1;
            start = i + 1;
        } else if (text[i] == '\n' or text[i] == '\r') {
            line += 1;
            start = i + 1;
        }
    }
    if (line != position.line) return error.InvalidPosition;
    var cursor = start;
    var units: u32 = 0;
    while (cursor < text.len and text[cursor] != '\r' and text[cursor] != '\n') {
        if (units == position.character) return cursor;
        const width = std.unicode.utf8ByteSequenceLength(text[cursor]) catch return error.InvalidUtf8;
        const scalar = std.unicode.utf8Decode(text[cursor .. cursor + width]) catch return error.InvalidUtf8;
        const add: u32 = if (scalar > 0xffff) 2 else 1;
        if (position.character > units and position.character < units + add) return error.InvalidPosition;
        units += add;
        cursor += width;
    }
    if (units == position.character) return cursor;
    return error.InvalidPosition;
}

pub fn byteToPosition(text: []const u8, offset: usize) Error!Position {
    if (offset > text.len or !std.unicode.utf8ValidateSlice(text)) return error.InvalidPosition;
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < offset) {
        if (text[i] == '\r' or text[i] == '\n') {
            if (text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n') {
                if (offset == i + 1) return error.InvalidPosition;
                i += 2;
            } else i += 1;
            if (i > offset) return error.InvalidPosition;
            line += 1;
            line_start = i;
        } else {
            const width = std.unicode.utf8ByteSequenceLength(text[i]) catch return error.InvalidUtf8;
            if (i + width > offset) return error.InvalidPosition;
            i += width;
        }
    }
    var units: u32 = 0;
    i = line_start;
    while (i < offset) {
        const width = std.unicode.utf8ByteSequenceLength(text[i]) catch return error.InvalidUtf8;
        const scalar = std.unicode.utf8Decode(text[i .. i + width]) catch return error.InvalidUtf8;
        units += if (scalar > 0xffff) 2 else 1;
        i += width;
    }
    return .{ .line = line, .character = units };
}

/// Encodes URI path bytes without shell interpretation; destination must fit exact result.
pub fn pathToUri(path: []const u8, destination: []u8) Error![]u8 {
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidPath;
    const prefix: []const u8 = if (std.mem.startsWith(u8, path, "/")) "file://" else "file:///";
    if (destination.len < prefix.len) return error.BufferTooSmall;
    @memcpy(destination[0..prefix.len], prefix);
    var out = prefix.len;
    for (path) |byte| {
        const safe = std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "/-._~:", byte) != null;
        if (safe) {
            if (out == destination.len) return error.BufferTooSmall;
            destination[out] = byte;
            out += 1;
        } else {
            if (destination.len - out < 3) return error.BufferTooSmall;
            destination[out] = '%';
            destination[out + 1] = "0123456789ABCDEF"[byte >> 4];
            destination[out + 2] = "0123456789ABCDEF"[byte & 15];
            out += 3;
        }
    }
    return destination[0..out];
}

pub const RequestKey = struct { id: u32, generation: u32 };
pub const Pending = struct {
    slots: []?RequestKey,
    next_id: u32 = 1,
    generation: u32 = 1,
    pub fn allocate(self: *Pending) Error!RequestKey {
        for (self.slots, 0..) |slot, index| if (slot == null) {
            const key = RequestKey{ .id = self.next_id, .generation = self.generation };
            self.next_id +%= 1;
            if (self.next_id == 0) self.next_id = 1;
            for (self.slots) |other| if (other) |present| {
                if (present.id == key.id) return error.PendingFull;
            };
            self.slots[index] = key;
            return key;
        };
        return error.PendingFull;
    }
    pub fn invalidate(self: *Pending) void {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        for (self.slots) |*slot| slot.* = null;
    }
    pub fn accept(self: *Pending, key: RequestKey) Error!void {
        if (key.generation != self.generation) return error.StaleResponse;
        for (self.slots) |*slot| if (slot.*) |present| {
            if (present.id == key.id and present.generation == key.generation) {
                slot.* = null;
                return;
            }
        };
        return error.StaleResponse;
    }
};

/// Bounded JSON-RPC request serialization using Zig's standard Stringify writer.
pub fn writeRequest(destination: []u8, id: u32, method: []const u8, params: anytype) Error![]u8 {
    var writer = std.Io.Writer.fixed(destination);
    var stringify: std.json.Stringify = .{ .writer = &writer };
    try stringify.beginObject();
    try stringify.objectField("jsonrpc");
    try stringify.write("2.0");
    try stringify.objectField("id");
    try stringify.write(id);
    try stringify.objectField("method");
    try stringify.write(method);
    try stringify.objectField("params");
    try stringify.write(params);
    try stringify.endObject();
    return destination[0..writer.end];
}

pub const Capability = enum { hover, definition, references, document_symbol, diagnostics };

pub const Session = struct {
    pending: *Pending,
    initialized: bool = false,
    shutdown_requested: bool = false,

    pub fn initialize(self: *Session, output: []u8, id: u32, root_uri: []const u8) Error![]u8 {
        if (self.initialized or self.shutdown_requested or !std.unicode.utf8ValidateSlice(root_uri)) return error.InvalidState;
        return writeRequest(output, id, "initialize", .{ .processId = @as(?u32, null), .rootUri = root_uri, .capabilities = .{} });
    }
    /// Encodes without advancing state; caller commits only after durable transport success.
    pub fn notifyInitialized(self: *Session, output: []u8) Error![]u8 {
        if (self.initialized or self.shutdown_requested) return error.InvalidState;
        return writeNotification(output, "initialized", .{});
    }
    pub fn markInitialized(self: *Session) Error!void {
        if (self.initialized or self.shutdown_requested) return error.InvalidState;
        self.initialized = true;
    }
    pub fn shutdown(self: *Session, output: []u8, id: u32) Error![]u8 {
        if (!self.initialized or self.shutdown_requested) return error.InvalidState;
        self.shutdown_requested = true;
        self.pending.invalidate();
        return writeRequest(output, id, "shutdown", .{});
    }
    pub fn exit(self: *Session, output: []u8) Error![]u8 {
        if (!self.shutdown_requested) return error.InvalidState;
        return writeNotification(output, "exit", .{});
    }
    pub fn request(self: *Session, output: []u8, id: u32, capability: Capability, uri: []const u8, position: Position) Error![]u8 {
        if (!self.initialized or self.shutdown_requested or !std.unicode.utf8ValidateSlice(uri)) return error.InvalidState;
        const method = switch (capability) {
            .hover => "textDocument/hover",
            .definition => "textDocument/definition",
            .references => "textDocument/references",
            .document_symbol => "textDocument/documentSymbol",
            .diagnostics => "textDocument/diagnostic",
        };
        if (capability == .references) return writeRequest(output, id, method, .{ .textDocument = .{ .uri = uri }, .position = position, .context = .{ .includeDeclaration = true } });
        if (capability == .document_symbol or capability == .diagnostics) return writeRequest(output, id, method, .{ .textDocument = .{ .uri = uri } });
        return writeRequest(output, id, method, .{ .textDocument = .{ .uri = uri }, .position = position });
    }
};

fn writeNotification(destination: []u8, method: []const u8, params: anytype) Error![]u8 {
    var writer = std.Io.Writer.fixed(destination);
    var stringify: std.json.Stringify = .{ .writer = &writer };
    try stringify.beginObject();
    try stringify.objectField("jsonrpc");
    try stringify.write("2.0");
    try stringify.objectField("method");
    try stringify.write(method);
    try stringify.objectField("params");
    try stringify.write(params);
    try stringify.endObject();
    return destination[0..writer.end];
}

pub const Document = struct { uri: []const u8, language_id: []const u8, version: i32, exact_text: []const u8 };

/// Refuses binary/invalid UTF-8 before forming any LSP snapshot; bytes remain caller-owned and exact.
pub fn didOpen(output: []u8, document: Document) Error![]u8 {
    if (!std.unicode.utf8ValidateSlice(document.uri) or !std.unicode.utf8ValidateSlice(document.language_id)) return error.InvalidDocument;
    if (!std.unicode.utf8ValidateSlice(document.exact_text)) return error.InvalidUtf8;
    return writeNotification(output, "textDocument/didOpen", .{ .textDocument = .{ .uri = document.uri, .languageId = document.language_id, .version = document.version, .text = document.exact_text } });
}

/// Full text sync transmits exact current result snapshot, never a derived/normalized buffer.
pub fn didChange(output: []u8, uri: []const u8, version: i32, exact_text: []const u8) Error![]u8 {
    if (!std.unicode.utf8ValidateSlice(uri)) return error.InvalidDocument;
    if (!std.unicode.utf8ValidateSlice(exact_text)) return error.InvalidUtf8;
    return writeNotification(output, "textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = .{.{ .text = exact_text }} });
}

pub fn didClose(output: []u8, uri: []const u8) Error![]u8 {
    if (!std.unicode.utf8ValidateSlice(uri)) return error.InvalidDocument;
    return writeNotification(output, "textDocument/didClose", .{ .textDocument = .{ .uri = uri } });
}

/// Fixed-slot cancellation tokens; token generation prevents recycled-slot confusion.
pub const CancellationPool = struct {
    slots: []?u32,
    next: u32 = 1,
    pub fn acquire(self: *CancellationPool) Error!struct { slot: usize, token: u32 } {
        for (self.slots, 0..) |entry, index| if (entry == null) {
            const token = self.next;
            self.next +%= 1;
            if (self.next == 0) self.next = 1;
            self.slots[index] = token;
            return .{ .slot = index, .token = token };
        };
        return error.PendingFull;
    }
    pub fn release(self: *CancellationPool, handle: anytype) Error!void {
        if (handle.slot >= self.slots.len or self.slots[handle.slot] != handle.token) return error.StaleResponse;
        self.slots[handle.slot] = null;
    }
    pub fn isLive(self: *const CancellationPool, handle: anytype) bool {
        return handle.slot < self.slots.len and self.slots[handle.slot] == handle.token;
    }
};

/// Result model declares capability independently from whether a result is present.
pub const ResultModel = struct {
    advertised: [5]bool = @splat(false),
    result_json: []const u8 = "null",
    pub fn supports(self: ResultModel, capability: Capability) bool {
        return self.advertised[@backingInt(capability)];
    }
};

/// Rejects incoming server requests: no workspace/app command execution is implemented.
pub fn serverRequestResponse(output: []u8, id: u32) Error![]u8 {
    var writer = std.Io.Writer.fixed(output);
    var stringify: std.json.Stringify = .{ .writer = &writer };
    try stringify.beginObject();
    try stringify.objectField("jsonrpc");
    try stringify.write("2.0");
    try stringify.objectField("id");
    try stringify.write(id);
    try stringify.objectField("error");
    try stringify.beginObject();
    try stringify.objectField("code");
    try stringify.write(@as(i32, -32601));
    try stringify.objectField("message");
    try stringify.write("Method not found");
    try stringify.endObject();
    try stringify.endObject();
    return output[0..writer.end];
}

test "framing split points, multiple frames, malformed and duplicate lengths" {
    const frame = "Content-Length: 2\r\n\r\n{}";
    for (0..frame.len + 1) |split| {
        var backing: [64]u8 = undefined;
        var parser = Framer.init(&backing);
        _ = try parser.feed(frame[0..split], 64);
        _ = try parser.feed(frame[split..], 64);
        try std.testing.expectEqualStrings("{}", parser.body().?);
    }
    var backing: [64]u8 = undefined;
    var parser = Framer.init(&backing);
    try std.testing.expectError(error.HeaderDuplicate, parser.feed("Content-Length: 1\r\ncontent-length: 1\r\n\r\nx", 64));
    try std.testing.expectError(error.LengthInvalid, parseLength("Content-Length: -1\r\n\r\n"));
    try std.testing.expectError(error.HeaderConflict, parseLength("Content-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n"));
    var tiny: [32]u8 = undefined;
    var exhausted = Framer.init(&tiny);
    try std.testing.expectError(error.WorkBudget, exhausted.feed("12345", 0));
    try std.testing.expectError(error.FrameTooLarge, exhausted.feed("Content-Length: 99\r\n\r\n", 64));
    var sequential: [128]u8 = undefined;
    var split_headers = Framer.init(&sequential);
    _ = try split_headers.feed("Content-Length: 2\r\n\r\n{}Content-L", 128);
    try std.testing.expectEqualStrings("{}", split_headers.body().?);
    try split_headers.consume();
    _ = try split_headers.feed("ength: 2\r\n\r\n{}", 128);
    try std.testing.expectEqualStrings("{}", split_headers.body().?);

    var pair_storage: [64]u8 = undefined;
    var pair = Framer.init(&pair_storage);
    _ = try pair.feed("Content-Length: 1\r\n\r\naContent-Length: 1\r\n\r\nb", 64);
    try std.testing.expectEqualStrings("a", pair.body().?);
    try pair.consume();
    try std.testing.expectEqualStrings("b", pair.body().?);
}

test "UTF16 positions preserve surrogate and CRLF boundaries" {
    const text = "a😀\r\nx";
    try std.testing.expectEqual(@as(usize, 1), try positionToByte(text, .{ .line = 0, .character = 1 }));
    try std.testing.expectError(error.InvalidPosition, positionToByte(text, .{ .line = 0, .character = 2 }));
    try std.testing.expectEqual(@as(usize, 7), try positionToByte(text, .{ .line = 1, .character = 0 }));
    try std.testing.expectEqual(Position{ .line = 1, .character = 1 }, try byteToPosition(text, 8));
}

test "bounded JSON escaping and URI encoding" {
    var json: [128]u8 = undefined;
    const value = try writeRequest(&json, 7, "textDocument/hover", .{ .uri = "file:///a\"b" });
    try std.testing.expect(std.mem.indexOf(u8, value, "\\\"b") != null);
    var uri: [64]u8 = undefined;
    try std.testing.expectEqualStrings("file:///a%20b%23", try pathToUri("a b#", &uri));
}

test "URI absolute paths preserve roots and bounded percent encoding on every host" {
    const cases = [_]struct { path: []const u8, uri: []const u8 }{
        .{ .path = "/", .uri = "file:///" },
        .{ .path = "/work/result file #?.zig", .uri = "file:///work/result%20file%20%23%3F.zig" },
        .{ .path = "C:/work/result file #?.zig", .uri = "file:///C:/work/result%20file%20%23%3F.zig" },
        .{ .path = "/work/ż%\\.zig", .uri = "file:///work/%C5%BC%25%5C.zig" },
    };
    var output: [128]u8 = undefined;
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.uri, try pathToUri(case.path, &output));
        output[case.uri.len] = 0xa5;
        try std.testing.expectEqualStrings(case.uri, try pathToUri(case.path, output[0..case.uri.len]));
        try std.testing.expectEqual(@as(u8, 0xa5), output[case.uri.len]);
        try std.testing.expectError(error.BufferTooSmall, pathToUri(case.path, output[0 .. case.uri.len - 1]));
    }
}

test "session lifecycle, result snapshots, and bounded cancellation" {
    var slots: [2]?RequestKey = .{ null, null };
    var pending = Pending{ .slots = &slots };
    var session = Session{ .pending = &pending };
    var output: [512]u8 = undefined;
    const init_message = try session.initialize(&output, 1, "file:///work");
    try std.testing.expect(std.mem.indexOf(u8, init_message, "initialize") != null);
    _ = try session.notifyInitialized(&output);
    try session.markInitialized();
    const opened = try didOpen(&output, .{ .uri = "file:///a", .language_id = "zig", .version = 1, .exact_text = "a\r\nb" });
    try std.testing.expect(std.mem.indexOf(u8, opened, "a\\r\\nb") != null);
    try std.testing.expectError(error.InvalidUtf8, didChange(&output, "file:///a", 2, "\xff"));
    const request = try session.request(&output, 2, .hover, "file:///a", .{ .line = 0, .character = 0 });
    try std.testing.expect(std.mem.indexOf(u8, request, "textDocument/hover") != null);
    const references = try session.request(&output, 3, .references, "file:///a", .{ .line = 0, .character = 0 });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, references, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("params").?.object.get("context").?.object.get("includeDeclaration").?.bool);
    _ = try session.shutdown(&output, 3);
    _ = try session.exit(&output);

    var tokens: [1]?u32 = .{null};
    var pool = CancellationPool{ .slots = &tokens };
    const first = try pool.acquire();
    try std.testing.expect(pool.isLive(first));
    try pool.release(first);
    const second = try pool.acquire();
    try std.testing.expect(!pool.isLive(first));
    try std.testing.expect(pool.isLive(second));
}

test "pending requests reject stale generations and recycled IDs" {
    var slots: [2]?RequestKey = .{ null, null };
    var pending = Pending{ .slots = &slots, .next_id = std.math.maxInt(u32) };
    const key = try pending.allocate();
    pending.invalidate();
    try std.testing.expectError(error.StaleResponse, pending.accept(key));
    const next = try pending.allocate();
    try std.testing.expect(next.generation != key.generation);
}
