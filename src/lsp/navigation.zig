const std = @import("std");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");

pub const capacity = 16;
pub const Item = struct {
    label: [96]u8 = undefined,
    label_len: usize,
    uri: [512]u8 = undefined,
    uri_len: usize,
    start: protocol.Position,
    end: protocol.Position,
};

/// Owned decoded labels/URIs survive publication-buffer reuse; parsing borrows fixed scratch.
pub const Model = struct {
    items: [capacity]Item = undefined,
    count: usize = 0,
    version: i32 = -1,
    scratch: [64 * 1024]u8 = undefined,

    pub fn load(self: *Model, json: []const u8, current_uri: []const u8, version: i32) !void {
        self.count = 0;
        self.version = -1;
        errdefer self.count = 0;
        if (version < 0) return error.InvalidVersion;
        if (json.len > 16 * 1024) return error.NavigationCapacity;
        try transport.validate_json_structure(json);
        var allocator = std.heap.FixedBufferAllocator.init(&self.scratch);
        const parsed = std.json.parseFromSlice(std.json.Value, allocator.allocator(), json, .{ .duplicate_field_behavior = .@"error" }) catch |err| {
            return if (err == error.OutOfMemory) error.NavigationCapacity else err;
        };
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidNavigation;
        var stack: [32]std.json.Value = undefined;
        stack[0] = parsed.value.object.get("result") orelse return error.InvalidNavigation;
        var pending: usize = 1;
        var work: usize = 0;
        while (pending > 0) {
            pending -= 1;
            const value = stack[pending];
            work += 1;
            if (work > 128) return error.NavigationCapacity;
            switch (value) {
                .null => {},
                .array => |array| try push(&stack, &pending, array.items),
                .object => |object| {
                    if (self.count == self.items.len) return error.NavigationCapacity;
                    try decode_item(object, current_uri, &self.items[self.count]);
                    self.count += 1;
                    if (object.get("children")) |children| {
                        if (children != .array) return error.InvalidNavigation;
                        try push(&stack, &pending, children.array.items);
                    }
                },
                else => return error.InvalidNavigation,
            }
        }
        self.version = version;
        std.debug.assert(self.count <= capacity and self.version == version);
    }

    pub fn selection(self: *const Model, index: usize, uri: []const u8, version: i32, source: []const u8) !struct { start: usize, end: usize } {
        if (self.version != version) return error.StaleResponse;
        if (index >= self.count) return error.InvalidNavigation;
        const item = &self.items[index];
        if (!std.mem.eql(u8, item.uri[0..item.uri_len], uri)) return error.ExternalTargetUnsupported;
        const start = try protocol.positionToByte(source, item.start);
        const end = try protocol.positionToByte(source, item.end);
        if (start > end) return error.InvalidPosition;
        std.debug.assert(end <= source.len and start <= end);
        return .{ .start = start, .end = end };
    }
};

fn push(stack: []std.json.Value, pending: *usize, values: []const std.json.Value) !void {
    if (values.len > stack.len - pending.*) return error.NavigationCapacity;
    for (0..values.len) |index| stack[pending.* + index] = values[values.len - index - 1];
    pending.* += values.len;
    std.debug.assert(pending.* <= stack.len);
}

fn decode_item(object: std.json.ObjectMap, current_uri: []const u8, destination: *Item) !void {
    var location = object;
    if (object.get("location")) |value| {
        if (value != .object) return error.InvalidNavigation;
        location = value.object;
    }
    var uri = current_uri;
    if (location.get("targetUri") orelse location.get("uri")) |value| {
        if (value != .string) return error.InvalidNavigation;
        uri = value.string;
    } else if (!object.contains("name")) return error.InvalidNavigation;
    var label: []const u8 = "Location";
    if (object.get("name")) |name| {
        if (name != .string) return error.InvalidNavigation;
        label = name.string;
    }
    if (uri.len == 0 or uri.len > destination.uri.len or label.len > destination.label.len) return error.NavigationCapacity;
    const range = location.get("targetSelectionRange") orelse location.get("selectionRange") orelse location.get("range") orelse return error.InvalidNavigation;
    if (range != .object) return error.InvalidNavigation;
    const start = try position(range.object.get("start") orelse return error.InvalidNavigation);
    const end = try position(range.object.get("end") orelse return error.InvalidNavigation);
    if (start.line > end.line or (start.line == end.line and start.character > end.character)) return error.InvalidPosition;
    destination.* = .{ .label_len = label.len, .uri_len = uri.len, .start = start, .end = end };
    @memcpy(destination.label[0..label.len], label);
    @memcpy(destination.uri[0..uri.len], uri);
}

fn position(value: std.json.Value) !protocol.Position {
    if (value != .object) return error.InvalidPosition;
    const line = value.object.get("line") orelse return error.InvalidPosition;
    const character = value.object.get("character") orelse return error.InvalidPosition;
    if (line != .integer or character != .integer) return error.InvalidPosition;
    if (line.integer < 0 or line.integer > std.math.maxInt(u32) or character.integer < 0 or character.integer > std.math.maxInt(u32)) return error.InvalidPosition;
    return .{ .line = @intCast(line.integer), .character = @intCast(character.integer) };
}

test "navigation owns decoded identities, binds versions, and rejects external or invalid ranges" {
    var model = Model{};
    const json = "{\"result\":[{\"uri\":\"file:///r.zig\",\"range\":{\"start\":{\"line\":0,\"character\":1},\"end\":{\"line\":0,\"character\":3}}}]}";
    try model.load(json, "file:///r.zig", 2);
    const selected = try model.selection(0, "file:///r.zig", 2, "a😀\r\nz");
    try std.testing.expectEqual(@as(usize, 1), selected.start);
    try std.testing.expectEqual(@as(usize, 5), selected.end);
    try std.testing.expectError(error.StaleResponse, model.selection(0, "file:///r.zig", 3, "a😀\r\nz"));
    try std.testing.expectError(error.ExternalTargetUnsupported, model.selection(0, "file:///other.zig", 2, "a😀\r\nz"));
    try std.testing.expectError(error.InvalidPosition, model.selection(0, "file:///r.zig", 2, "x"));
    try model.load("{\"result\":null}", "file:///r.zig", 3);
    try std.testing.expectEqual(@as(usize, 0), model.count);
    try std.testing.expectError(error.InvalidNavigation, model.load("{\"result\":[{}]}", "file:///r.zig", 4));
    try std.testing.expectEqual(@as(usize, 0), model.count);
}

test "navigation decodes owned symbol identities and accepts LocationLink targets" {
    var model = Model{};
    try model.load("{\"result\":[{\"name\":\"fi\\u0078ture\",\"location\":{\"uri\":\"file:\\/\\/\\/r.zig\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}}}}]}", "file:///r.zig", 1);
    @memset(&model.scratch, 0);
    try std.testing.expectEqualStrings("fixture", model.items[0].label[0..model.items[0].label_len]);
    try std.testing.expectEqual(@as(usize, 1), (try model.selection(0, "file:///r.zig", 1, "x")).end);
    try model.load("{\"result\":[{\"targetUri\":\"file:///r.zig\",\"targetSelectionRange\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}}}]}", "file:///r.zig", 2);
    try std.testing.expectEqual(@as(usize, 1), (try model.selection(0, "file:///r.zig", 2, "x")).end);
}

test "navigation resource rejection clears all partial results" {
    var model = Model{};
    var json: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&json);
    try writer.writeAll("{\"result\":[");
    for (0..capacity + 1) |index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"uri\":\"u\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}}}");
    }
    try writer.writeAll("]}");
    try std.testing.expectError(error.NavigationCapacity, model.load(json[0..writer.end], "u", 1));
    try std.testing.expectEqual(@as(usize, 0), model.count);
    try std.testing.expectEqual(@as(i32, -1), model.version);
}
