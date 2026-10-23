const std = @import("std");
const client = @import("lsp/client.zig");
const protocol = @import("lsp/protocol.zig");
const transport = @import("lsp/transport.zig");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const executable = args.next() orelse return error.MissingServer;
    const temporary = try init.minimal.environ.getAlloc(init.gpa, "TEMP");
    defer init.gpa.free(temporary);
    const workspace = try create_workspace(init.io, init.gpa, temporary);
    defer init.gpa.free(workspace);
    defer std.Io.Dir.cwd().deleteTree(init.io, workspace) catch {};

    std.debug.print("LSP fixture: background\n", .{});
    try exercise_background(init.io, executable, workspace);
    std.debug.print("LSP fixture: one_shot_error_handles\n", .{});
    try exercise_one_shot_error_handles(init.io, executable, workspace);
    std.debug.print("LSP fixture: failure\n", .{});
    try exercise_failure(init.io, executable, workspace, "malformed", error.ResponseInvalid);
    std.debug.print("LSP fixture: failure\n", .{});
    try exercise_failure(init.io, executable, workspace, "oversize", error.ResponseTooLarge);
    std.debug.print("LSP fixture: startup_timeout\n", .{});
    try exercise_startup_timeout(init.io, executable, workspace, "stalled-init");
    std.debug.print("LSP fixture: startup_timeout\n", .{});
    try exercise_startup_timeout(init.io, executable, workspace, "partial-init");
    std.debug.print("LSP fixture: initialized_idle\n", .{});
    try exercise_initialized_idle(init.io, executable, workspace);
    std.debug.print("LSP fixture: request_timeout\n", .{});
    try exercise_request_timeout(init.io, executable, workspace);
    std.debug.print("LSP fixture: graceful_close\n", .{});
    try exercise_graceful_close(init.io, executable, workspace);
    std.debug.print("LSP fixture: shutdown_timeout\n", .{});
    try exercise_shutdown_timeout(init.io, executable, workspace);
    std.debug.print("LSP fixture: idle_queue\n", .{});
    try exercise_idle_queue(init.io, executable, workspace);
    std.debug.print("LSP fixture: backpressure_revoke\n", .{});
    try exercise_backpressure_revoke(init.io, executable, workspace);
    std.debug.print("LSP fixture: backpressure_timeout\n", .{});
    try exercise_backpressure_timeout(init.io, executable, workspace);
    std.debug.print("LSP fixture: descendant_revoke\n", .{});
    try exercise_descendant_revoke(init.io, executable, workspace);
    std.debug.print("LSP fixture: missing_executable\n", .{});
    try exercise_missing_executable(init.io, init.gpa, workspace);
}

fn exercise_background(io: std.Io, executable: []const u8, workspace: []const u8) !void {
    const argv = [_][]const u8{ executable, "single-shot" };
    const server = client.Server{ .executable = executable, .argv = &argv, .workspace = workspace, .root_uri = "file:///C:/warkocz-lsp-native", .config_bytes = "{}" };
    var grants: [1]client.Identity = undefined;
    var trust = client.TrustStore{ .grants = &grants };
    try trust.grant(server.identity("fake-server-v1"));
    var state: client.Client = undefined;
    state.init();
    const identity = try state.begin(server, "fake-server-v1", &trust);
    var worker: transport.Background = undefined;
    worker.init();
    try worker.start(io, &state, server);
    var worker_live = true;
    defer if (worker_live) worker.revoke(identity) catch {};
    const main_uri = "file:///C:/warkocz-lsp-native/main.zig";
    const second_uri = "file:///C:/warkocz-lsp-native/second.zig";
    try worker.open(.{ .uri = main_uri, .language_id = "zig", .version = 0, .text = "main-open" });
    try worker.open(.{ .uri = second_uri, .language_id = "zig", .version = 0, .text = "second-open" });
    try worker.change(main_uri, 1, "main-one");
    try worker.change(second_uri, 1, "second-one");
    try worker.change(main_uri, 2, "main-two");
    try worker.request(.hover, second_uri, .{ .line = 0, .character = 0 });
    try expect_publications(io, &worker, main_uri, second_uri);
    try std.testing.expect(state.capabilities_known and state.capabilities.supports(.hover));
    try std.testing.expect(!state.capabilities.supports(.definition));
    try std.testing.expect(worker.failed() == null);
    try worker.revoke(identity);
    worker_live = false;
    try std.testing.expect(worker.worker_thread == null and worker.reader_thread == null and worker.reader_done);
}

/// Failed one-shot startup must return after detached pipe ownership is closed.
fn exercise_one_shot_error_handles(io: std.Io, executable: []const u8, workspace: []const u8) !void {
    const argv = [_][]const u8{ executable, "one-shot-error" };
    const server = client.Server{ .executable = executable, .argv = &argv, .workspace = workspace, .root_uri = "file:///C:/warkocz-lsp-native", .config_bytes = "{}" };
    var grants: [1]client.Identity = undefined;
    var trust = client.TrustStore{ .grants = &grants };
    try trust.grant(server.identity("fake-server-v1"));
    var state: client.Client = undefined;
    state.init();
    const identity = try state.begin(server, "fake-server-v1", &trust);
    var wire: [transport.Background.max_json_bytes]u8 = undefined;
    var inbound: [transport.Background.max_json_bytes]u8 = undefined;
    var scratch: [4096]u8 = undefined;
    var diagnostics: [transport.Background.max_json_bytes]u8 = undefined;
    var process_scratch: @import("lsp/windows_process.zig").SpawnScratch = .{};
    const buffers = transport.Buffers{ .wire = &wire, .inbound = &inbound, .read_scratch = &scratch, .diagnostics = &diagnostics, .process_scratch = &process_scratch };
    _ = transport.initialize_open_shutdown(io, &state, server, .{ .uri = "file:///C:/warkocz-lsp-native/main.zig", .language_id = "zig", .version = 0, .text = "x" }, buffers, .{ .raw = .fromSeconds(2), .clock = .awake }) catch {};
    try state.revoke(identity);
    try std.testing.expect(!state.running);
}

fn expect_publications(io: std.Io, worker: *transport.Background, main_uri: []const u8, second_uri: []const u8) !void {
    var json: [transport.Background.max_json_bytes]u8 = undefined;
    var uri: [512]u8 = undefined;
    var main_diagnostics = false;
    var second_diagnostics = false;
    var hover_seen = false;
    for (0..400) |_| {
        if (worker.take(&uri, &json)) |publication| {
            if (publication.capability == .diagnostics) {
                const main_current = std.mem.eql(u8, publication.document_uri, main_uri) and publication.version == 2;
                const second_current = std.mem.eql(u8, publication.document_uri, second_uri) and publication.version == 1;
                try std.testing.expect(main_current or second_current);
                main_diagnostics = main_diagnostics or main_current;
                second_diagnostics = second_diagnostics or second_current;
            }
            if (publication.capability == .hover) {
                try std.testing.expectEqualStrings(second_uri, publication.document_uri);
                try std.testing.expectEqual(@as(i32, 1), publication.version);
                try std.testing.expect(std.mem.indexOf(u8, publication.json, "hover-current") != null);
                hover_seen = true;
            }
            if (main_diagnostics and second_diagnostics and hover_seen) break;
        }
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(10), .clock = .awake }, io);
    }
    try std.testing.expect(main_diagnostics and second_diagnostics and hover_seen);
}

fn exercise_failure(io: std.Io, executable: []const u8, workspace: []const u8, mode: []const u8, expected: anyerror) !void {
    const argv = [_][]const u8{ executable, mode };
    const server = client.Server{ .executable = executable, .argv = &argv, .workspace = workspace, .root_uri = "file:///C:/warkocz-lsp-native", .config_bytes = "{}" };
    var grants: [1]client.Identity = undefined;
    var trust = client.TrustStore{ .grants = &grants };
    try trust.grant(server.identity("fake-server-v1"));
    var state: client.Client = undefined;
    state.init();
    const identity = try state.begin(server, "fake-server-v1", &trust);
    var worker: transport.Background = undefined;
    worker.init();
    try worker.start(io, &state, server);
    var worker_live = true;
    defer if (worker_live) worker.revoke(identity) catch {};
    try worker.open(.{ .uri = "file:///C:/warkocz-lsp-native/main.zig", .language_id = "zig", .version = 0, .text = "unchanged-session" });
    for (0..100) |_| {
        if (worker.failed()) |failure| {
            try std.testing.expectEqual(expected, failure);
            break;
        }
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(10), .clock = .awake }, io);
    }
    try std.testing.expectEqual(expected, worker.failed().?);
    try std.testing.expect(state.running);
    try worker.revoke(identity);
    worker_live = false;
    try std.testing.expect(worker.worker_thread == null and worker.reader_thread == null and worker.reader_done);
}

/// No revoke occurs before timeout: a server silent during initialize must fail independently.
fn exercise_startup_timeout(io: std.Io, executable: []const u8, workspace: []const u8, mode: []const u8) !void {
    const argv = [_][]const u8{ executable, mode };
    const server = client.Server{ .executable = executable, .argv = &argv, .workspace = workspace, .root_uri = "file:///C:/warkocz-lsp-native", .config_bytes = "{}" };
    var grants: [1]client.Identity = undefined;
    var trust = client.TrustStore{ .grants = &grants };
    try trust.grant(server.identity("fake-server-v1"));
    var state: client.Client = undefined;
    state.init();
    const identity = try state.begin(server, "fake-server-v1", &trust);
    var worker: transport.Background = undefined;
    worker.init();
    try worker.start(io, &state, server);
    var worker_live = true;
    defer if (worker_live) worker.revoke(identity) catch {};
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    try wait_for_failure(io, &worker, 350);
    const elapsed = start.durationTo(std.Io.Clock.Timestamp.now(io, .awake));
    try std.testing.expectEqual(error.ChildTimeout, worker.failed().?);
    try std.testing.expect(elapsed.raw.nanoseconds < 35_000_000_000);
    try worker.revoke(identity);
    worker_live = false;
    try std.testing.expect(worker.worker_thread == null and worker.reader_thread == null and worker.reader_done);
}

/// Startup deadline cannot kill an initialized server that is simply idle.
fn exercise_initialized_idle(io: std.Io, executable: []const u8, workspace: []const u8) !void {
    const argv = [_][]const u8{ executable, "initialized-idle" };
    const server = client.Server{ .executable = executable, .argv = &argv, .workspace = workspace, .root_uri = "file:///C:/warkocz-lsp-native", .config_bytes = "{}" };
    var grants: [1]client.Identity = undefined;
    var trust = client.TrustStore{ .grants = &grants };
    try trust.grant(server.identity("fake-server-v1"));
    var state: client.Client = undefined;
    state.init();
    const identity = try state.begin(server, "fake-server-v1", &trust);
    var worker: transport.Background = undefined;
    worker.init();
    try worker.start(io, &state, server);
    var worker_live = true;
    defer if (worker_live) worker.revoke(identity) catch {};
    try wait_for_hover(io, &worker);
    try std.Io.Clock.Duration.sleep(.{ .raw = .fromSeconds(31), .clock = .awake }, io);
    try std.testing.expect(worker.failed() == null and worker.supports(.hover));
    try worker.revoke(identity);
    worker_live = false;
}

/// A reply deadline begins at request encoding and is not refreshed by initialized idle time.
fn exercise_request_timeout(io: std.Io, executable: []const u8, workspace: []const u8) !void {
    const argv = [_][]const u8{ executable, "ignored-hover" };
    const server = client.Server{ .executable = executable, .argv = &argv, .workspace = workspace, .root_uri = "file:///C:/warkocz-lsp-native", .config_bytes = "{}" };
    var grants: [1]client.Identity = undefined;
    var trust = client.TrustStore{ .grants = &grants };
    try trust.grant(server.identity("fake-server-v1"));
    var state: client.Client = undefined;
    state.init();
    const identity = try state.begin(server, "fake-server-v1", &trust);
    var worker: transport.Background = undefined;
    worker.init();
    try worker.start(io, &state, server);
    var worker_live = true;
    defer if (worker_live) worker.revoke(identity) catch {};
    try wait_for_hover(io, &worker);
    try worker.open(.{ .uri = "file:///C:/warkocz-lsp-native/main.zig", .language_id = "zig", .version = 0, .text = "request-timeout" });
    try worker.request(.hover, "file:///C:/warkocz-lsp-native/main.zig", .{ .line = 0, .character = 0 });
    try wait_for_failure(io, &worker, 350);
    try std.testing.expectEqual(error.ChildTimeout, worker.failed().?);
    try worker.revoke(identity);
    worker_live = false;
    try std.testing.expect(worker.worker_thread == null and worker.reader_thread == null and worker.reader_done);
}

/// Normal close waits for the shutdown reply on its worker, then sends exit and reaps.
fn exercise_graceful_close(io: std.Io, executable: []const u8, workspace: []const u8) !void {
    const argv = [_][]const u8{ executable, "graceful-close" };
    const server = client.Server{ .executable = executable, .argv = &argv, .workspace = workspace, .root_uri = "file:///C:/warkocz-lsp-native", .config_bytes = "{}" };
    var grants: [1]client.Identity = undefined;
    var trust = client.TrustStore{ .grants = &grants };
    try trust.grant(server.identity("fake-server-v1"));
    var state: client.Client = undefined;
    state.init();
    const identity = try state.begin(server, "fake-server-v1", &trust);
    var worker: transport.Background = undefined;
    worker.init();
    try worker.start(io, &state, server);
    try wait_for_hover(io, &worker);
    try worker.close(identity);
    try std.testing.expect(worker.worker_thread == null and worker.reader_thread == null and worker.reader_done and !state.running);
}

/// Close reports missing shutdown acknowledgement only after worker cleanup and trust revocation.
fn exercise_shutdown_timeout(io: std.Io, executable: []const u8, workspace: []const u8) !void {
    const argv = [_][]const u8{ executable, "ignored-shutdown" };
    const server = client.Server{ .executable = executable, .argv = &argv, .workspace = workspace, .root_uri = "file:///C:/warkocz-lsp-native", .config_bytes = "{}" };
    var grants: [1]client.Identity = undefined;
    var trust = client.TrustStore{ .grants = &grants };
    try trust.grant(server.identity("fake-server-v1"));
    var state: client.Client = undefined;
    state.init();
    const identity = try state.begin(server, "fake-server-v1", &trust);
    var worker: transport.Background = undefined;
    worker.init();
    try worker.start(io, &state, server);
    try wait_for_hover(io, &worker);
    try std.testing.expectError(error.ChildTimeout, worker.close(identity));
    try std.testing.expect(worker.worker_thread == null and worker.reader_thread == null and worker.reader_done and !state.running);
}

fn exercise_idle_queue(io: std.Io, executable: []const u8, workspace: []const u8) !void {
    const argv = [_][]const u8{ executable, "stall" };
    const server = client.Server{ .executable = executable, .argv = &argv, .workspace = workspace, .root_uri = "file:///C:/warkocz-lsp-native", .config_bytes = "{}" };
    var grants: [1]client.Identity = undefined;
    var trust = client.TrustStore{ .grants = &grants };
    try trust.grant(server.identity("fake-server-v1"));
    var state: client.Client = undefined;
    state.init();
    const identity = try state.begin(server, "fake-server-v1", &trust);
    var worker: transport.Background = undefined;
    worker.init();
    try worker.start(io, &state, server);
    var worker_live = true;
    defer if (worker_live) worker.revoke(identity) catch {};
    try worker.open(.{ .uri = "file:///C:/warkocz-lsp-native/main.zig", .language_id = "zig", .version = 0, .text = "queued-without-ui-wait" });
    worker.mutex.lockUncancelable(io);
    const command_len = worker.command_len;
    worker.mutex.unlock(io);
    try std.testing.expectEqual(@as(usize, 1), command_len);
    try worker.revoke(identity);
    worker_live = false;
    try std.testing.expect(worker.worker_thread == null and worker.reader_thread == null and worker.reader_done);
}

fn exercise_backpressure_revoke(io: std.Io, executable: []const u8, workspace: []const u8) !void {
    const argv = [_][]const u8{ executable, "backpressure" };
    const server = client.Server{ .executable = executable, .argv = &argv, .workspace = workspace, .root_uri = "file:///C:/warkocz-lsp-native", .config_bytes = "{}" };
    var grants: [1]client.Identity = undefined;
    var trust = client.TrustStore{ .grants = &grants };
    try trust.grant(server.identity("fake-server-v1"));
    var state: client.Client = undefined;
    state.init();
    const identity = try state.begin(server, "fake-server-v1", &trust);
    var worker: transport.Background = undefined;
    worker.init();
    try worker.start(io, &state, server);
    var worker_live = true;
    defer if (worker_live) worker.revoke(identity) catch {};
    try wait_for_hover(io, &worker);
    var text: [client.max_document_bytes]u8 = undefined;
    @memset(&text, 'x');
    for (0..client.max_documents) |index| {
        var uri: [512]u8 = undefined;
        const value = try std.fmt.bufPrint(&uri, "file:///C:/warkocz-lsp-native/pressure-{d}.zig", .{index});
        try worker.open(.{ .uri = value, .language_id = "zig", .version = 0, .text = &text });
    }
    try wait_for_command_write(io, &worker);
    try worker.revoke(identity);
    worker_live = false;
    try std.testing.expect(worker.worker_thread == null and worker.reader_thread == null and worker.reader_done);
    try std.testing.expect(!state.running);
}

/// Fixture stops reading after initialize, filling child stdin capacity without revocation.
fn exercise_backpressure_timeout(io: std.Io, executable: []const u8, workspace: []const u8) !void {
    const argv = [_][]const u8{ executable, "deadline-backpressure" };
    const server = client.Server{ .executable = executable, .argv = &argv, .workspace = workspace, .root_uri = "file:///C:/warkocz-lsp-native", .config_bytes = "{}" };
    var grants: [1]client.Identity = undefined;
    var trust = client.TrustStore{ .grants = &grants };
    try trust.grant(server.identity("fake-server-v1"));
    var state: client.Client = undefined;
    state.init();
    const identity = try state.begin(server, "fake-server-v1", &trust);
    var worker: transport.Background = undefined;
    worker.init();
    try worker.start(io, &state, server);
    var worker_live = true;
    defer if (worker_live) worker.revoke(identity) catch {};
    try wait_for_hover(io, &worker);
    var text: [client.max_document_bytes]u8 = undefined;
    @memset(&text, 'q');
    const original = text;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    try worker.open(.{ .uri = "file:///C:/warkocz-lsp-native/timeout.zig", .language_id = "zig", .version = 0, .text = &text });
    for (0..350) |_| {
        if (worker.failed() != null) break;
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(100), .clock = .awake }, io);
    }
    const elapsed = start.durationTo(std.Io.Clock.Timestamp.now(io, .awake));
    try std.testing.expectEqual(error.ChildTimeout, worker.failed().?);
    try std.testing.expect(elapsed.raw.nanoseconds < 35_000_000_000);
    try std.testing.expectEqualSlices(u8, &original, &text);
    try worker.revoke(identity);
    worker_live = false;
    try std.testing.expect(worker.worker_thread == null and worker.reader_thread == null and worker.reader_done and !state.running);
}

/// Fixture sends initialize response after descendant spawn, then descendant holds stdout open.
/// Revocation kills job tree and proves pipe EOF by completing reader join.
fn exercise_descendant_revoke(io: std.Io, executable: []const u8, workspace: []const u8) !void {
    const argv = [_][]const u8{ executable, "descendant" };
    const server = client.Server{ .executable = executable, .argv = &argv, .workspace = workspace, .root_uri = "file:///C:/warkocz-lsp-native", .config_bytes = "{}" };
    var grants: [1]client.Identity = undefined;
    var trust = client.TrustStore{ .grants = &grants };
    try trust.grant(server.identity("fake-server-v1"));
    var state: client.Client = undefined;
    state.init();
    const identity = try state.begin(server, "fake-server-v1", &trust);
    var worker: transport.Background = undefined;
    worker.init();
    try worker.start(io, &state, server);
    try wait_for_hover(io, &worker);
    try std.testing.expect(worker.supports(.hover));
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    try worker.revoke(identity);
    const elapsed = start.durationTo(std.Io.Clock.Timestamp.now(io, .awake));
    try std.testing.expect(elapsed.raw.nanoseconds < 2_000_000_000);
    try std.testing.expect(worker.worker_thread == null and worker.reader_thread == null and worker.reader_done and !state.running);
}

fn wait_for_failure(io: std.Io, worker: *transport.Background, attempts: usize) !void {
    for (0..attempts) |_| {
        if (worker.failed() != null) return;
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(100), .clock = .awake }, io);
    }
    return error.FailureNotObserved;
}

fn wait_for_hover(io: std.Io, worker: *transport.Background) !void {
    for (0..100) |_| {
        if (worker.supports(.hover)) return;
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(10), .clock = .awake }, io);
    }
    return error.InitializeNotObserved;
}

fn wait_for_command_write(io: std.Io, worker: *transport.Background) !void {
    for (0..100) |_| {
        worker.mutex.lockUncancelable(io);
        const started = worker.command_write_started;
        worker.mutex.unlock(io);
        if (started) return;
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(10), .clock = .awake }, io);
    }
    return error.CommandWriteNotObserved;
}

fn exercise_missing_executable(io: std.Io, allocator: std.mem.Allocator, workspace: []const u8) !void {
    const missing = try std.fmt.allocPrint(allocator, "{s}/missing-server.exe", .{workspace});
    defer allocator.free(missing);
    const argv = [_][]const u8{missing};
    const server = client.Server{ .executable = missing, .argv = &argv, .workspace = workspace, .root_uri = "file:///C:/warkocz-lsp-native", .config_bytes = "{}" };
    var grants: [1]client.Identity = undefined;
    var trust = client.TrustStore{ .grants = &grants };
    try trust.grant(server.identity("fake-server-v1"));
    var state: client.Client = undefined;
    state.init();
    const identity = try state.begin(server, "fake-server-v1", &trust);
    var worker: transport.Background = undefined;
    worker.init();
    try worker.start(io, &state, server);
    var worker_live = true;
    defer if (worker_live) worker.revoke(identity) catch {};
    for (0..100) |_| {
        if (worker.failed() != null) break;
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(10), .clock = .awake }, io);
    }
    const failure = worker.failed() orelse return error.SpawnFailureNotObserved;
    try std.testing.expectEqual(error.TransportFailed, failure);
    try worker.revoke(identity);
    worker_live = false;
    try std.testing.expect(worker.worker_thread == null and worker.reader_thread == null and worker.reader_done);
}

fn create_workspace(io: std.Io, allocator: std.mem.Allocator, temporary: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(temporary)) return error.InvalidTempRoot;
    const root = try std.fmt.allocPrint(allocator, "{s}/warkocz-native-e2e", .{temporary});
    defer allocator.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    const child = try std.fmt.allocPrint(allocator, "{s}/run-{x}", .{ root, std.Io.Clock.real.now(io).nanoseconds });
    errdefer allocator.free(child);
    try std.Io.Dir.cwd().createDir(io, child, .default_dir);
    return child;
}
