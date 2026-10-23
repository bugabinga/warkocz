const std = @import("std");
const protocol = @import("protocol");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    const executable = args.next() orelse return error.MissingExecutable;
    const requested_mode = args.next() orelse "ui";
    if (std.mem.eql(u8, requested_mode, "malformed")) return write_raw(init.io, "Content-Length: nope\r\n\r\n{}");
    if (std.mem.eql(u8, requested_mode, "oversize")) return write_raw(init.io, "Content-Length: 99999\r\n\r\n");
    if (std.mem.eql(u8, requested_mode, "stall") or std.mem.eql(u8, requested_mode, "stalled-init")) {
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromSeconds(30), .clock = .awake }, init.io);
        return;
    }
    if (std.mem.eql(u8, requested_mode, "partial-init")) {
        try write_raw(init.io, "Content-Length: 128\r\n\r\n{\"jsonrpc\":\"2.0\"");
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromSeconds(30), .clock = .awake }, init.io);
        return;
    }
    if (std.mem.eql(u8, requested_mode, "descendant-child")) {
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromSeconds(30), .clock = .awake }, init.io);
        return;
    }
    const descendant = std.mem.eql(u8, requested_mode, "descendant");
    if (descendant) {
        const child_argv = [_][]const u8{ executable, "descendant-child" };
        _ = try std.process.spawn(init.io, .{ .exe = .{ .explicit = .{ .dir = .cwd(), .path = executable } }, .argv = &child_argv, .stdin = .inherit, .stdout = .inherit, .stderr = .ignore, .create_no_window = true });
    }
    const single_shot = std.mem.eql(u8, requested_mode, "single-shot");
    const one_shot_error = std.mem.eql(u8, requested_mode, "one-shot-error");
    const backpressure = std.mem.eql(u8, requested_mode, "backpressure") or std.mem.eql(u8, requested_mode, "deadline-backpressure");
    const initialized_idle = std.mem.eql(u8, requested_mode, "initialized-idle");
    const graceful_close = std.mem.eql(u8, requested_mode, "graceful-close");
    const ignored_hover = std.mem.eql(u8, requested_mode, "ignored-hover");
    const ignored_shutdown = std.mem.eql(u8, requested_mode, "ignored-shutdown");
    if (!descendant and !single_shot and !one_shot_error and !backpressure and !initialized_idle and !graceful_close and !ignored_hover and !ignored_shutdown and !std.mem.eql(u8, requested_mode, "ui")) return error.InvalidMode;
    var read_buffer: [1024]u8 = undefined;
    var storage: [4096]u8 = undefined;
    var framer = protocol.Framer.init(&storage);
    var reader = std.Io.File.stdin().readerStreaming(init.io, &read_buffer);
    var saw_open = false;
    var fixture = Fixture{ .ignore_hover = ignored_hover, .ignore_shutdown = ignored_shutdown };
    while (true) {
        const byte = reader.interface.takeByte() catch return;
        _ = try framer.feed(&.{byte}, 1);
        while (framer.body()) |body| {
            try respond(init.io, init.gpa, body, single_shot, one_shot_error, backpressure, initialized_idle, &saw_open, &fixture);
            try framer.consume();
        }
    }
}

fn respond(io: std.Io, allocator: std.mem.Allocator, body: []const u8, single_shot: bool, one_shot_error: bool, backpressure: bool, initialized_idle: bool, saw_open: *bool, fixture: *Fixture) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .duplicate_field_behavior = .@"error", .max_value_len = body.len });
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;
    const root = parsed.value.object;
    const method_value = root.get("method") orelse return error.InvalidRequest;
    if (method_value != .string) return error.InvalidRequest;
    const method = method_value.string;
    if (std.mem.eql(u8, method, "initialize")) {
        if (single_shot) return write_json(io, " { \"jsonrpc\" : \"2.0\", \"id\" : 1, \"result\" : { \"capabilities\" : { \"hoverProvider\" : true, \"definitionProvider\" : false } } }");
        try write_json(io, " { \"jsonrpc\" : \"2.0\", \"id\" : 1, \"result\" : { \"capabilities\" : { \"hoverProvider\" : true, \"definitionProvider\" : {\"workDoneProgress\":false}, \"referencesProvider\":true, \"documentSymbolProvider\": {\"label\":\"fixture\"} } } }");
        if (backpressure or initialized_idle) while (true) try std.Io.Clock.Duration.sleep(.{ .raw = .fromSeconds(30), .clock = .awake }, io);
        return;
    }
    if (std.mem.eql(u8, method, "initialized")) {
        if (one_shot_error) return error.ForcedFailure;
        return;
    }
    if (std.mem.eql(u8, method, "exit")) std.process.exit(0);
    if (std.mem.eql(u8, method, "textDocument/didOpen")) {
        const document = try object(try object(root, "params"), "textDocument");
        const uri = try string(document, "uri");
        const version = try integer(document, "version");
        if (single_shot) try fixture.open(uri, version, try document_text(root, "textDocument"));
        saw_open.* = true;
        if (single_shot) return;
        try publish_diagnostics(io, uri, version);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/didChange")) {
        if (!saw_open.*) return error.InvalidOrder;
        const params = try object(root, "params");
        const document = try object(params, "textDocument");
        const version = try integer(document, "version");
        const uri = try string(document, "uri");
        const changes = params.get("contentChanges") orelse return error.InvalidRequest;
        if (changes != .array or changes.array.items.len != 1 or changes.array.items[0] != .object) return error.InvalidRequest;
        const text = try string(changes.array.items[0].object, "text");
        if (single_shot) try fixture.change(uri, version, text);
        if (single_shot) return;
        try publish_diagnostics(io, uri, version);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/hover")) {
        if (fixture.ignore_hover) return;
        const id = try integer(root, "id");
        if (single_shot) {
            if (!fixture.complete()) return error.IncompleteSnapshot;
            const params = try object(try object(root, "params"), "textDocument");
            if (!std.mem.eql(u8, try string(params, "uri"), "file:///C:/warkocz-lsp-native/second.zig")) return error.WrongHoverTarget;
            try publish_final_diagnostics(io);
        }
        var output: [256]u8 = undefined;
        const json = try std.fmt.bufPrint(&output, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"contents\":\"hover-current\"}}}}", .{id});
        return write_json(io, json);
    }
    if (std.mem.eql(u8, method, "textDocument/definition")) return write_location(io, root, "{\"uri\":\"file:///other.zig\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}}}");
    if (std.mem.eql(u8, method, "textDocument/references")) return write_location(io, root, "[{\"uri\":\"file:///other.zig\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}}}]");
    if (std.mem.eql(u8, method, "textDocument/documentSymbol")) return write_location(io, root, "[{\"name\":\"fixture-symbol\",\"kind\":12,\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":15}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":5}},\"children\":[{\"name\":\"fixture-child\",\"kind\":13,\"range\":{\"start\":{\"line\":0,\"character\":6},\"end\":{\"line\":0,\"character\":10}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":6},\"end\":{\"line\":0,\"character\":10}}}]}]");
    if (std.mem.eql(u8, method, "shutdown")) {
        if (fixture.ignore_shutdown) return;
        const id = try integer(root, "id");
        var output: [96]u8 = undefined;
        return write_json(io, try std.fmt.bufPrint(&output, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id}));
    }
    return error.InvalidRequest;
}

const Fixture = struct {
    main_version: i64 = -1,
    second_version: i64 = -1,
    ignore_hover: bool = false,
    ignore_shutdown: bool = false,

    fn open(self: *Fixture, uri: []const u8, version: i64, text: []const u8) !void {
        if (version != 0) return error.InvalidSnapshot;
        if (std.mem.eql(u8, uri, "file:///C:/warkocz-lsp-native/main.zig") and self.main_version == -1 and std.mem.eql(u8, text, "main-open")) {
            self.main_version = 0;
            return;
        }
        if (std.mem.eql(u8, uri, "file:///C:/warkocz-lsp-native/second.zig") and self.second_version == -1 and std.mem.eql(u8, text, "second-open")) {
            self.second_version = 0;
            return;
        }
        return error.InvalidSnapshot;
    }

    fn change(self: *Fixture, uri: []const u8, version: i64, text: []const u8) !void {
        if (std.mem.eql(u8, uri, "file:///C:/warkocz-lsp-native/main.zig")) {
            if (version != self.main_version + 1 or !main_text(version, text)) return error.InvalidSnapshot;
            self.main_version = version;
            return;
        }
        if (std.mem.eql(u8, uri, "file:///C:/warkocz-lsp-native/second.zig")) {
            if (version != self.second_version + 1 or version != 1 or !std.mem.eql(u8, text, "second-one")) return error.InvalidSnapshot;
            self.second_version = version;
            return;
        }
        return error.InvalidSnapshot;
    }

    fn complete(self: Fixture) bool {
        return self.main_version == 2 and self.second_version == 1;
    }
};

fn main_text(version: i64, text: []const u8) bool {
    return (version == 1 and std.mem.eql(u8, text, "main-one")) or (version == 2 and std.mem.eql(u8, text, "main-two"));
}

fn publish_final_diagnostics(io: std.Io) !void {
    try write_json(io, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///other.zig\",\"version\":2,\"diagnostics\":[{}]}}");
    try publish_diagnostics(io, "file:///C:/warkocz-lsp-native/main.zig", 2);
    try publish_diagnostics(io, "file:///C:/warkocz-lsp-native/second.zig", 1);
}

fn write_location(io: std.Io, root: std.json.ObjectMap, result: []const u8) !void {
    const id = try integer(root, "id");
    var output: [2048]u8 = undefined;
    return write_json(io, try std.fmt.bufPrint(&output, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ id, result }));
}

fn publish_diagnostics(io: std.Io, uri: []const u8, version: i64) !void {
    var json: [2048]u8 = undefined;
    try write_json(io, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///other.zig\",\"version\":0,\"diagnostics\":[{}]}}");
    if (version > 0) try write_json(io, try std.fmt.bufPrint(&json, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{{\"uri\":\"{s}\",\"version\":{d},\"diagnostics\":[{{}}]}}}}", .{ uri, version - 1 }));
    return write_json(io, try std.fmt.bufPrint(&json, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{{\"uri\":\"{s}\",\"version\":{d},\"diagnostics\":[{{}}]}}}}", .{ uri, version }));
}

fn object(root: std.json.ObjectMap, name: []const u8) !std.json.ObjectMap {
    const value = root.get(name) orelse return error.InvalidRequest;
    if (value != .object) return error.InvalidRequest;
    return value.object;
}

fn string(root: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = root.get(name) orelse return error.InvalidRequest;
    if (value != .string) return error.InvalidRequest;
    return value.string;
}

fn integer(root: std.json.ObjectMap, name: []const u8) !i64 {
    const value = root.get(name) orelse return error.InvalidRequest;
    if (value != .integer) return error.InvalidRequest;
    return value.integer;
}

fn document_text(root: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return string(try object(try object(root, "params"), name), "text");
}

fn write_json(io: std.Io, json: []const u8) !void {
    var header: [48]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&header, "Content-Length: {d}\r\n\r\n", .{json.len});
    try write_raw(io, prefix);
    try write_raw(io, json);
}

fn write_raw(io: std.Io, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}
