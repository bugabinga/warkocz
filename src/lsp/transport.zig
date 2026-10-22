const std = @import("std");
const client = @import("client.zig");
const protocol = @import("protocol.zig");
const contained_process = @import("windows_process.zig");

pub const Client = client.Client;
pub const Server = client.Server;
pub const Identity = client.Identity;
pub const TrustStore = client.TrustStore;

pub const Error = error{
    InvalidBuffers,
    ResponseInvalid,
    ResponseTooLarge,
    ChildTimeout,
    TransportFailed,
    WriteFailed,
    ReadFailed,
} || client.Error;

/// All buffers remain caller-owned. A successful exchange leaves no live child or pipe handle.
pub const Buffers = struct {
    wire: []u8,
    inbound: []u8,
    read_scratch: []u8,
    diagnostics: []u8,
    process_scratch: *contained_process.SpawnScratch,

    fn validate(self: Buffers) Error!void {
        if (self.wire.len == 0 or self.inbound.len == 0 or self.read_scratch.len == 0 or self.diagnostics.len == 0) return error.InvalidBuffers;
        if (rangesOverlap(self.inbound, self.read_scratch) or rangesOverlap(self.inbound, self.diagnostics)) return error.InvalidBuffers;
        std.debug.assert(self.wire.len > 0);
        std.debug.assert(self.inbound.len > 0);
    }
};

/// One bounded native-pipe lifecycle. Caller must first establish exact consent with Client.begin.
pub fn initialize_open_shutdown(io: std.Io, state: *client.Client, server: client.Server, document: client.Document, buffers: Buffers, timeout: std.Io.Clock.Duration) Error![]const u8 {
    try buffers.validate();
    try server.validate();
    if (!state.running or timeout.raw.nanoseconds <= 0) return error.TransportFailed;

    var child = contained_process.spawn(io, server.executable, server.argv, server.workspace, buffers.process_scratch) catch return error.TransportFailed;
    defer child.terminate(io);
    const stdin = child.stdin();
    const stdout = child.stdout();
    child.detach_pipes();
    defer stdout.close(io);
    defer stdin.close(io);

    const deadline = std.Io.Clock.Timestamp.now(io, timeout.clock).addDuration(timeout);
    var framer = protocol.Framer.init(buffers.inbound);

    try send(io, stdin, try state.initialize(server.root_uri, buffers.wire), deadline);
    _ = try receive(io, stdout, &framer, buffers.read_scratch, buffers.wire, deadline);
    try send(io, stdin, try state.initialized(buffers.wire), deadline);
    if (!std.Io.Clock.Timestamp.now(io, deadline.clock).compare(.lt, deadline)) return error.ChildTimeout;
    try state.commit_initialized(.{ false, false, false, false, false });
    try send(io, stdin, try state.open(document, buffers.wire), deadline);
    const diagnostics = try receive(io, stdout, &framer, buffers.read_scratch, buffers.diagnostics, deadline);
    try send(io, stdin, try state.session.shutdown(buffers.wire, 2), deadline);
    _ = try receive(io, stdout, &framer, buffers.read_scratch, buffers.wire, deadline);
    try send(io, stdin, try state.session.exit(buffers.wire), deadline);
    return diagnostics;
}

/// Persistent native LSP service.
/// UI only copies commands into fixed slots; this worker is sole mutable Client owner after start.
pub const Background = struct {
    pub const max_json_bytes = client.max_document_bytes + 4096;
    pub const Publication = struct { capability: protocol.Capability, document_uri: []const u8, version: i32, diagnostic_count: usize = 0, json: []const u8 };
    const Command = union(enum) { open: Open, change: Change, request: Request };
    const Open = struct { uri: [512]u8, uri_len: usize, language: [64]u8, language_len: usize, version: i32, text: [client.max_document_bytes]u8, text_len: usize };
    const Change = struct { uri: [512]u8, uri_len: usize, version: i32, text: [client.max_document_bytes]u8, text_len: usize };
    const Request = struct { capability: protocol.Capability, uri: [512]u8, uri_len: usize, position: protocol.Position };
    const Inbound = struct { json: [max_json_bytes]u8 = undefined, len: usize = 0 };

    io: std.Io,
    state: *client.Client,
    server: client.Server,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    worker_thread: ?std.Thread = null,
    reader_thread: ?std.Thread = null,
    child: ?contained_process.Child = null,
    write_pipe: ?std.Io.File = null,
    read_pipe: ?std.Io.File = null,
    stopping: bool = false,
    graceful_stopping: bool = false,
    shutdown_id: ?u32 = null,
    shutdown_deadline: ?std.Io.Clock.Timestamp = null,
    shutdown_acknowledged: bool = false,
    exit_sent: bool = false,
    /// Absolute startup budget starts once and expires only until `initialized` write succeeds.
    startup_pending: bool = true,
    startup_deadline: std.Io.Clock.Timestamp = undefined,
    command_write_started: bool = false,
    reader_done: bool = false,
    failure: ?Error = null,
    capabilities: protocol.ResultModel = .{},
    capabilities_known: bool = false,
    initialize_request: ?protocol.RequestKey = null,
    initialize_capabilities: ?[5]bool = null,
    commands: [client.max_documents]Command = undefined,
    command_head: usize = 0,
    command_len: usize = 0,
    inbound: [client.max_results]Inbound = undefined,
    inbound_head: usize = 0,
    inbound_len: usize = 0,
    published: [client.max_results]Inbound = undefined,
    published_head: usize = 0,
    published_len: usize = 0,
    published_capability: [client.max_results]protocol.Capability = undefined,
    published_uris: [client.max_results][512]u8 = undefined,
    published_uri_lengths: [client.max_results]usize = undefined,
    published_version: [client.max_results]i32 = undefined,
    published_diagnostic_count: [client.max_results]usize = undefined,
    request_versions: [client.max_results]?i32 = undefined,
    request_deadlines: [client.max_results]?std.Io.Clock.Timestamp = undefined,
    request_uris: [client.max_results][512]u8 = undefined,
    request_uri_lengths: [client.max_results]usize = undefined,
    request_capabilities: [client.max_results]protocol.Capability = undefined,
    json_scratch: [max_json_bytes * 4]u8 = undefined,
    process_scratch: contained_process.SpawnScratch = .{},

    pub fn init(self: *Background) void {
        self.* = .{ .io = undefined, .state = undefined, .server = undefined };
    }

    pub fn start(self: *Background, io: std.Io, state: *client.Client, server: client.Server) !void {
        try server.validate();
        if (!state.running or self.worker_thread != null) return error.TransportFailed;
        self.* = .{ .io = io, .state = state, .server = server };
        self.startup_deadline = far_deadline(io);
        for (&self.request_versions, &self.request_deadlines) |*version, *deadline| {
            version.* = null;
            deadline.* = null;
        }
        self.worker_thread = try std.Thread.spawn(.{}, worker, .{self});
        std.debug.assert(self.worker_thread != null and self.command_len == 0);
    }

    /// Revocation claims and kills child before joining writer blocked on its detached stdin.
    pub fn revoke(self: *Background, identity: client.Identity) !void {
        self.stop_immediately();
        try self.state.revoke(identity);
        std.debug.assert(self.reader_done and !self.state.running and self.child == null);
    }

    /// Normal close waits only for a matching shutdown response; timeout falls back to contained termination.
    pub fn close(self: *Background, identity: client.Identity) !void {
        self.mutex.lockUncancelable(self.io);
        self.graceful_stopping = true;
        self.shutdown_deadline = far_deadline(self.io);
        const pipe = self.read_pipe;
        self.wake.signal(self.io);
        self.mutex.unlock(self.io);
        if (pipe) |read_pipe| contained_process.cancel_read(read_pipe);
        if (self.worker_thread) |thread| thread.join();
        self.worker_thread = null;
        const failure = self.failed();
        try self.state.revoke(identity);
        std.debug.assert(self.reader_done and !self.state.running and self.child == null);
        if (failure) |value| return value;
    }

    fn stop_immediately(self: *Background) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.wake.signal(self.io);
        var child = self.claim_child_locked();
        const pipe = self.claim_write_pipe_locked();
        self.mutex.unlock(self.io);
        if (pipe) |write_pipe| contained_process.cancel_write(write_pipe);
        if (child) |*live| live.terminate(self.io);
        if (self.worker_thread) |thread| thread.join();
        self.worker_thread = null;
    }

    pub fn open(self: *Background, document: client.Document) !void {
        if (document.uri.len == 0 or document.uri.len > 512 or document.language_id.len == 0 or document.language_id.len > 64 or document.text.len > client.max_document_bytes) return error.DocumentTooLarge;
        var copied = Open{ .uri = undefined, .uri_len = document.uri.len, .language = undefined, .language_len = document.language_id.len, .version = document.version, .text = undefined, .text_len = document.text.len };
        @memcpy(copied.uri[0..document.uri.len], document.uri);
        @memcpy(copied.language[0..document.language_id.len], document.language_id);
        @memcpy(copied.text[0..document.text.len], document.text);
        try self.push(.{ .open = copied });
    }

    pub fn change(self: *Background, uri: []const u8, version: i32, text: []const u8) !void {
        if (uri.len == 0 or uri.len > 512 or text.len > client.max_document_bytes) return error.DocumentTooLarge;
        var copied = Change{ .uri = undefined, .uri_len = uri.len, .version = version, .text = undefined, .text_len = text.len };
        @memcpy(copied.uri[0..uri.len], uri);
        @memcpy(copied.text[0..text.len], text);
        try self.push(.{ .change = copied });
    }

    pub fn request(self: *Background, capability: protocol.Capability, uri: []const u8, position: protocol.Position) !void {
        if (uri.len == 0 or uri.len > 512) return error.DocumentTooLarge;
        var copied = Request{ .capability = capability, .uri = undefined, .uri_len = uri.len, .position = position };
        @memcpy(copied.uri[0..uri.len], uri);
        try self.push(.{ .request = copied });
    }

    /// Copies bounded attribution and JSON before consuming publication.
    /// Returned slices borrow caller buffers; valid until caller reuses or releases them.
    pub fn take(self: *Background, uri_output: []u8, json_output: []u8) ?Publication {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.failure != null or self.published_len == 0) return null;
        const self_bytes = std.mem.asBytes(self);
        if (rangesOverlap(uri_output, json_output) or rangesOverlap(uri_output, self_bytes) or rangesOverlap(json_output, self_bytes)) return null;
        const index = self.published_head;
        const value = &self.published[index];
        const uri_len = self.published_uri_lengths[index];
        if (uri_len > uri_output.len or value.len > json_output.len) return null;
        @memcpy(uri_output[0..uri_len], self.published_uris[index][0..uri_len]);
        @memcpy(json_output[0..value.len], value.json[0..value.len]);
        self.published_head = (index + 1) % self.published.len;
        self.published_len -= 1;
        return .{ .capability = self.published_capability[index], .document_uri = uri_output[0..uri_len], .version = self.published_version[index], .diagnostic_count = self.published_diagnostic_count[index], .json = json_output[0..value.len] };
    }

    pub fn failed(self: *Background) ?Error {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.failure;
    }

    /// Immutable UI snapshot. `state` remains worker-thread-owned after start.
    pub fn supports(self: *Background, capability: protocol.Capability) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.failure == null and self.capabilities_known and self.capabilities.supports(capability);
    }

    fn push(self: *Background, command: Command) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // Delivery may have reached the server before failing; this connection cannot be reused.
        if (self.failure != null or self.reader_done or self.graceful_stopping) return error.TransportFailed;
        if (self.stopping or self.command_len == self.commands.len) return error.CapacityExceeded;
        self.commands[(self.command_head + self.command_len) % self.commands.len] = command;
        self.command_len += 1;
        self.wake.signal(self.io);
    }

    fn worker(self: *Background) void {
        var child = self.spawn_child() catch {
            self.record_failure(error.TransportFailed);
            self.mark_reader_done();
            return;
        };
        const stdin = child.stdin();
        const stdout = child.stdout();
        child.detach_pipes();
        if (!self.publish_child(child, stdin)) {
            stdin.close(self.io);
            stdout.close(self.io);
            child.terminate(self.io);
            self.mark_reader_done();
            return;
        }
        defer self.cleanup_worker(stdin);
        self.publish_read_pipe(stdout);
        self.reader_thread = std.Thread.spawn(.{}, reader, .{ self, stdout }) catch null;
        if (self.reader_thread == null) {
            stdout.close(self.io);
            self.record_failure(error.TransportFailed);
            return;
        }
        self.run_writer(stdin);
    }

    fn spawn_child(self: *Background) !contained_process.Child {
        return contained_process.spawn(self.io, self.server.executable, self.server.argv, self.server.workspace, &self.process_scratch);
    }

    fn publish_child(self: *Background, child: contained_process.Child, stdin: std.Io.File) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping) return false;
        std.debug.assert(self.child == null and self.write_pipe == null);
        self.child = child;
        self.write_pipe = stdin;
        return true;
    }

    fn cleanup_worker(self: *Background, stdin: std.Io.File) void {
        stdin.close(self.io);
        self.clear_write_pipe(stdin);
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        self.clear_read_pipe();
        self.terminate_captured_child();
        self.mark_reader_done();
    }

    fn run_writer(self: *Background, stdin: std.Io.File) void {
        var wire: [max_json_bytes]u8 = undefined;
        const initialize = self.state.initialize(self.server.root_uri, &wire) catch {
            self.record_failure(error.TransportFailed);
            return;
        };
        const initialize_id = json_unsigned(initialize, "\"id\":") orelse {
            self.record_failure(error.TransportFailed);
            return;
        };
        self.initialize_request = self.pending_key(initialize_id) orelse {
            self.record_failure(error.TransportFailed);
            return;
        };
        send(self.io, stdin, initialize, self.startup_deadline) catch |err| {
            self.record_failure(err);
            return;
        };
        while (true) {
            const step = self.next_command();
            self.drain_inbound();
            if (step.failed or self.failed() != null) return;
            if (!self.state.session.initialized and self.initialize_capabilities != null) {
                const json = self.state.initialized(&wire) catch {
                    self.record_failure(error.TransportFailed);
                    return;
                };
                if (self.startup_expired()) {
                    self.record_failure(error.ChildTimeout);
                    return;
                }
                send(self.io, stdin, json, self.startup_deadline) catch |err| {
                    self.record_failure(err);
                    return;
                };
                self.commit_initialized();
            }
            if (step.stop or step.closing) break;
            if (step.command) |value| self.write_command(stdin, value, &wire);
        }
        if (self.state.session.initialized and !self.is_stopping()) self.stop_session(stdin, &wire);
    }

    const WriterStep = struct { stop: bool, closing: bool, failed: bool, command: ?Command };

    fn next_command(self: *Background) WriterStep {
        self.mutex.lockUncancelable(self.io);
        while (!self.stopping and !self.graceful_stopping and self.failure == null and !self.reader_done and self.inbound_len == 0 and (!self.state.session.initialized or self.command_len == 0)) self.wake.waitUncancelable(self.io, &self.mutex);
        const stop = self.stopping;
        const closing = self.graceful_stopping;
        const has_failure = self.failure != null or self.reader_done;
        const command = if (!stop and !closing and self.state.session.initialized) self.pop_command_locked() else null;
        self.mutex.unlock(self.io);
        return .{ .stop = stop, .closing = closing, .failed = has_failure, .command = command };
    }

    fn stop_session(self: *Background, stdin: std.Io.File, wire: []u8) void {
        const id = 0xffff_fffe;
        const shutdown = self.state.session.shutdown(wire, id) catch return self.record_failure(error.TransportFailed);
        self.forget_all_requests();
        const deadline = self.close_deadline();
        self.begin_shutdown_wait(id, deadline);
        send(self.io, stdin, shutdown, deadline) catch |err| return self.record_failure(err);
        if (!self.wait_for_shutdown()) return;
        const exit = self.state.session.exit(wire) catch return self.record_failure(error.TransportFailed);
        self.mark_exit_sent();
        send(self.io, stdin, exit, deadline) catch |err| self.record_failure(err);
    }

    fn close_deadline(self: *Background) std.Io.Clock.Timestamp {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.shutdown_deadline orelse far_deadline(self.io);
    }

    fn begin_shutdown_wait(self: *Background, id: u32, deadline: std.Io.Clock.Timestamp) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown_id = id;
        self.shutdown_deadline = deadline;
        self.shutdown_acknowledged = false;
        const pipe = self.read_pipe;
        std.debug.assert(!self.stopping);
        self.mutex.unlock(self.io);
        if (pipe) |read_pipe| contained_process.cancel_read(read_pipe);
    }

    fn wait_for_shutdown(self: *Background) bool {
        while (true) {
            // The writer remains the sole protocol owner during shutdown.
            self.drain_inbound();
            self.mutex.lockUncancelable(self.io);
            const has_failure = self.stopping or self.failure != null;
            if (has_failure or self.shutdown_acknowledged) {
                const acknowledged = self.shutdown_acknowledged;
                self.mutex.unlock(self.io);
                return !has_failure and acknowledged;
            }
            if (self.inbound_len == 0) self.wake.waitUncancelable(self.io, &self.mutex);
            self.mutex.unlock(self.io);
        }
    }

    fn is_stopping(self: *Background) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.stopping;
    }

    fn mark_exit_sent(self: *Background) void {
        self.mutex.lockUncancelable(self.io);
        self.exit_sent = true;
        self.mutex.unlock(self.io);
    }

    fn exit_is_sent(self: *Background) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.exit_sent;
    }

    fn claim_child_locked(self: *Background) ?contained_process.Child {
        const child = self.child;
        self.child = null;
        return child;
    }

    fn claim_write_pipe_locked(self: *Background) ?std.Io.File {
        const pipe = self.write_pipe;
        self.write_pipe = null;
        return pipe;
    }

    fn clear_write_pipe(self: *Background, stdin: std.Io.File) void {
        self.mutex.lockUncancelable(self.io);
        if (self.write_pipe) |pipe| {
            if (pipe.handle == stdin.handle) self.write_pipe = null;
        }
        self.mutex.unlock(self.io);
    }

    fn publish_read_pipe(self: *Background, stdout: std.Io.File) void {
        self.mutex.lockUncancelable(self.io);
        self.read_pipe = stdout;
        self.mutex.unlock(self.io);
    }

    fn clear_read_pipe(self: *Background) void {
        self.mutex.lockUncancelable(self.io);
        self.read_pipe = null;
        self.mutex.unlock(self.io);
    }

    fn terminate_captured_child(self: *Background) void {
        self.mutex.lockUncancelable(self.io);
        var child = self.claim_child_locked();
        self.mutex.unlock(self.io);
        if (child) |*live| live.terminate(self.io);
    }

    fn mark_reader_done(self: *Background) void {
        self.mutex.lockUncancelable(self.io);
        self.reader_done = true;
        self.wake.signal(self.io);
        self.mutex.unlock(self.io);
    }

    fn write_command(self: *Background, stdin: std.Io.File, command: Command, wire: []u8) void {
        const json = self.encode_command_or_fail(command, wire) orelse return;
        self.mutex.lockUncancelable(self.io);
        self.command_write_started = true;
        self.mutex.unlock(self.io);
        send(self.io, stdin, json, far_deadline(self.io)) catch |err| self.record_failure(err);
    }

    fn encode_command_or_fail(self: *Background, command: Command, wire: []u8) ?[]const u8 {
        return self.encode_command(command, wire) catch {
            self.record_failure(error.TransportFailed);
            return null;
        };
    }

    fn encode_command(self: *Background, command: Command, wire: []u8) ![]const u8 {
        return switch (command) {
            .open => |value| self.state.open(.{ .uri = value.uri[0..value.uri_len], .language_id = value.language[0..value.language_len], .version = value.version, .text = value.text[0..value.text_len] }, wire),
            .change => |value| self.state.change(value.uri[0..value.uri_len], value.version, value.text[0..value.text_len], wire),
            .request => |value| blk: {
                const uri = value.uri[0..value.uri_len];
                const version = self.state.document_version(uri) orelse return error.DocumentUnknown;
                const encoded = try self.state.request(value.capability, uri, value.position, wire);
                self.remember_request(json_unsigned(encoded, "\"id\":") orelse return error.TransportFailed, uri, version, value.capability);
                break :blk encoded;
            },
        };
    }

    fn remember_request(self: *Background, id: u32, uri: []const u8, version: i32, capability: protocol.Capability) void {
        for (self.state.pending.slots, 0..) |entry, index| if (entry) |key| {
            if (key.id != id) continue;
            self.mutex.lockUncancelable(self.io);
            self.request_versions[index] = version;
            self.request_deadlines[index] = far_deadline(self.io);
            @memcpy(self.request_uris[index][0..uri.len], uri);
            self.request_uri_lengths[index] = uri.len;
            self.request_capabilities[index] = capability;
            self.mutex.unlock(self.io);
            return;
        };
    }

    fn forget_request(self: *Background, index: usize) void {
        std.debug.assert(index < self.request_versions.len);
        self.mutex.lockUncancelable(self.io);
        self.request_versions[index] = null;
        self.request_deadlines[index] = null;
        self.request_uri_lengths[index] = 0;
        self.mutex.unlock(self.io);
    }

    fn forget_all_requests(self: *Background) void {
        self.mutex.lockUncancelable(self.io);
        for (&self.request_versions, &self.request_deadlines, &self.request_uri_lengths) |*version, *deadline, *uri_length| {
            version.* = null;
            deadline.* = null;
            uri_length.* = 0;
        }
        self.mutex.unlock(self.io);
    }

    fn reader(self: *Background, stdout: std.Io.File) void {
        defer stdout.close(self.io);
        defer if (!self.exit_is_sent()) self.terminate_captured_child();
        var storage: [max_json_bytes]u8 = undefined;
        var scratch: [4096]u8 = undefined;
        var framer = protocol.Framer.init(&storage);
        while (true) {
            const count = contained_process.read_some(self.io, stdout, &scratch, self.read_deadline()) catch |err| {
                if (self.exit_is_sent()) return;
                if (err == error.Timeout and self.deadline_expired()) {
                    self.record_failure(error.ChildTimeout);
                    return;
                }
                if (err == error.Timeout or self.shutdown_or_close_active()) continue;
                self.record_failure(error.ReadFailed);
                return;
            };
            if (count == 0) {
                if (!self.exit_is_sent()) self.record_failure(error.TransportFailed);
                return;
            }
            if (self.startup_expired()) {
                self.record_failure(error.ChildTimeout);
                return;
            }
            if (!self.feed_inbound(&framer, scratch[0..count])) return;
        }
    }

    fn feed_inbound(self: *Background, framer: *protocol.Framer, bytes: []const u8) bool {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const fed = framer.feed(bytes[offset..], bytes.len - offset) catch |err| {
                self.record_failure(switch (err) {
                    error.FrameTooLarge => error.ResponseTooLarge,
                    else => error.ResponseInvalid,
                });
                return false;
            };
            offset += fed;
            while (framer.body()) |body| {
                if (self.push_inbound(body)) |failure| {
                    self.record_failure(failure);
                    self.terminate_captured_child();
                    return false;
                }
                framer.consume() catch {
                    self.record_failure(error.ResponseInvalid);
                    return false;
                };
            }
        }
        return true;
    }

    /// Every read has a finite deadline: POSIX cannot cancel a blocked pipe read.
    fn read_deadline(self: *Background) std.Io.Clock.Timestamp {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var deadline = far_deadline(self.io);
        if (self.startup_pending) deadline = self.startup_deadline;
        if (self.shutdown_deadline) |value| deadline = earlier_deadline(self.io, deadline, value);
        for (self.request_deadlines) |value| {
            if (value) |request_deadline| deadline = earlier_deadline(self.io, deadline, request_deadline);
        }
        return deadline;
    }

    /// Idle read expiry is a POSIX wakeup; lifecycle/request expiry is terminal.
    fn deadline_expired(self: *Background) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const now = std.Io.Clock.Timestamp.now(self.io, .awake);
        if (self.startup_pending and !now.compare(.lt, self.startup_deadline)) return true;
        if (self.shutdown_deadline) |value| if (!now.compare(.lt, value)) return true;
        for (self.request_deadlines) |value| if (value) |request_deadline| if (!now.compare(.lt, request_deadline)) return true;
        return false;
    }

    fn startup_expired(self: *Background) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.startup_pending) return false;
        return !std.Io.Clock.Timestamp.now(self.io, self.startup_deadline.clock).compare(.lt, self.startup_deadline);
    }

    /// Writer owns Client; mutex makes externally visible startup state one commit.
    fn commit_initialized(self: *Background) void {
        const advertised = self.initialize_capabilities orelse {
            self.record_failure(error.ResponseInvalid);
            return;
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.startup_pending or !std.Io.Clock.Timestamp.now(self.io, self.startup_deadline.clock).compare(.lt, self.startup_deadline)) {
            self.record_failure_locked(error.ChildTimeout);
            return;
        }
        self.state.commit_initialized(advertised) catch {
            self.record_failure_locked(error.TransportFailed);
            return;
        };
        self.startup_pending = false;
        self.capabilities = self.state.capabilities;
        self.capabilities_known = true;
        self.initialize_capabilities = null;
        std.debug.assert(self.state.session.initialized and self.capabilities_known and !self.startup_pending);
    }

    fn record_failure(self: *Background, failure: Error) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.record_failure_locked(failure);
    }

    /// Caller holds mutex; failure invalidates presentation without changing document bytes.
    fn record_failure_locked(self: *Background, failure: Error) void {
        if (!self.stopping and self.failure == null) self.failure = failure;
        self.capabilities = .{};
        self.capabilities_known = false;
        self.published_head = 0;
        self.published_len = 0;
        self.wake.signal(self.io);
    }

    /// Returns failure without changing queued bytes when bounded inbound storage is exhausted.
    fn push_inbound(self: *Background, json: []const u8) ?Error {
        if (json.len == 0 or json.len > max_json_bytes) return error.ResponseInvalid;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.inbound_len == self.inbound.len) return error.CapacityExceeded;
        const slot = (self.inbound_head + self.inbound_len) % self.inbound.len;
        @memcpy(self.inbound[slot].json[0..json.len], json);
        self.inbound[slot].len = json.len;
        self.inbound_len += 1;
        self.wake.signal(self.io);
        return null;
    }

    fn pop_command_locked(self: *Background) ?Command {
        if (self.command_len == 0) return null;
        const value = self.commands[self.command_head];
        self.command_head = (self.command_head + 1) % self.commands.len;
        self.command_len -= 1;
        return value;
    }

    fn drain_inbound(self: *Background) void {
        for (0..self.inbound.len) |_| {
            self.mutex.lockUncancelable(self.io);
            if (self.failure != null or self.stopping or self.inbound_len == 0) {
                self.mutex.unlock(self.io);
                return;
            }
            const index = self.inbound_head;
            const value = self.inbound[index];
            self.inbound_head = (index + 1) % self.inbound.len;
            self.inbound_len -= 1;
            self.mutex.unlock(self.io);
            self.handle_json(value.json[0..value.len]);
        }
    }

    fn handle_json(self: *Background, json: []const u8) void {
        const message = parse_message(json, &self.json_scratch) catch {
            self.record_failure(error.ResponseInvalid);
            return;
        };
        if (self.accept_shutdown(message)) return;
        if (self.shutdown_active()) return;
        if (self.accept_initialize(message)) return;
        if (self.failed() != null) return;
        if (message.kind == .response) {
            for (self.state.pending.slots, 0..) |entry, index| if (entry) |key| {
                if (key.id != message.id) continue;
                if (self.request_versions[index] == null) {
                    self.state.pending.accept(key) catch return;
                    return;
                }
                if (!message.has_result) {
                    self.state.pending.accept(key) catch return;
                    self.forget_request(index);
                    return;
                }
                const version = self.request_versions[index].?;
                const uri = self.request_uris[index][0..self.request_uri_lengths[index]];
                const accepted = self.state.accept_result(.{ .capability = self.request_capabilities[index], .document_uri = uri, .document_version = version, .request = key, .json = json }) catch return;
                self.forget_request(index);
                if (accepted) |value| self.publish(value.capability, value.document_uri, value.document_version, 0, value.json);
                return;
            };
            return;
        }
        // Unversioned push diagnostics are unsupported: publishing them could claim stale data is current.
        if (message.kind != .diagnostics or message.version == null) return;
        const version = message.version.?;
        var current_document = false;
        for (self.state.documents) |document| {
            if (document.active and document.version == version and std.mem.eql(u8, document.uri[0..document.uri_len], message.uri)) current_document = true;
        }
        if (!current_document) return;
        self.publish(.diagnostics, message.uri, version, message.diagnostic_count, json);
    }

    fn accept_shutdown(self: *Background, message: ParsedMessage) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const id = self.shutdown_id orelse return false;
        if (message.kind != .response or message.id != id) return false;
        if (!message.has_result) {
            self.record_failure_locked(error.ResponseInvalid);
            return true;
        }
        self.shutdown_acknowledged = true;
        self.wake.signal(self.io);
        return true;
    }

    fn shutdown_active(self: *Background) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.shutdown_id != null;
    }

    fn shutdown_or_close_active(self: *Background) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.shutdown_id != null or self.graceful_stopping;
    }

    /// A matching initialize reply must be a successful capability result exactly once.
    fn accept_initialize(self: *Background, message: ParsedMessage) bool {
        const key = self.initialize_request orelse return false;
        if (message.kind != .response or message.id != key.id) return false;
        const advertised = message.capabilities orelse {
            self.record_failure(error.ResponseInvalid);
            return true;
        };
        if (!message.has_result) {
            self.record_failure(error.ResponseInvalid);
            return true;
        }
        self.state.pending.accept(key) catch {
            self.record_failure(error.ResponseInvalid);
            return true;
        };
        self.initialize_request = null;
        self.initialize_capabilities = advertised;
        return true;
    }

    fn pending_key(self: *Background, id: u32) ?protocol.RequestKey {
        for (self.state.pending.slots) |entry| if (entry) |key| {
            if (key.id == id) return key;
        };
        return null;
    }

    fn publish(self: *Background, capability: protocol.Capability, uri: []const u8, version: i32, diagnostic_count: usize, json: []const u8) void {
        std.debug.assert(uri.len > 0 and uri.len <= self.published_uris[0].len);
        std.debug.assert(json.len > 0 and json.len <= self.published[0].json.len);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.failure != null or self.stopping) return;
        if (self.published_len == self.published.len) {
            self.record_failure_locked(error.CapacityExceeded);
            return;
        }
        const slot = (self.published_head + self.published_len) % self.published.len;
        @memcpy(self.published[slot].json[0..json.len], json);
        @memcpy(self.published_uris[slot][0..uri.len], uri);
        self.published[slot].len = json.len;
        self.published_capability[slot] = capability;
        self.published_uri_lengths[slot] = uri.len;
        self.published_version[slot] = version;
        self.published_diagnostic_count[slot] = diagnostic_count;
        self.published_len += 1;
    }
};

const ParsedMessage = struct {
    kind: enum { response, diagnostics, ignored },
    id: u32 = 0,
    capabilities: ?[5]bool = null,
    uri: []const u8 = "",
    version: ?i32 = null,
    has_result: bool = false,
    diagnostic_count: usize = 0,
};

/// Reject excessive nesting/work before std.json parses using fixed caller-owned arena bytes.
pub fn validate_json_structure(json: []const u8) !void {
    if (json.len == 0 or json.len > Background.max_json_bytes) return error.ResponseTooLarge;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (json) |byte| {
        if (in_string) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == '"') in_string = false;
            continue;
        }
        if (byte == '"') {
            in_string = true;
        } else if (byte == '{' or byte == '[') {
            depth += 1;
            if (depth > 32) return error.JsonInvalid;
        } else if (byte == '}' or byte == ']') {
            if (depth == 0) return error.JsonInvalid;
            depth -= 1;
        }
    }
    if (in_string or depth != 0) return error.JsonInvalid;
}

fn parse_message(json: []const u8, scratch: []u8) !ParsedMessage {
    try validate_json_structure(json);
    var arena = std.heap.FixedBufferAllocator.init(scratch);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{ .duplicate_field_behavior = .@"error", .max_value_len = json.len });
    defer parsed.deinit();
    if (parsed.value != .object) return error.JsonInvalid;
    const root = parsed.value.object;
    const rpc = root.get("jsonrpc") orelse return error.JsonInvalid;
    if (rpc != .string or !std.mem.eql(u8, rpc.string, "2.0")) return error.JsonInvalid;
    if (root.get("method")) |method| {
        if (method != .string) return error.JsonInvalid;
        if (!std.mem.eql(u8, method.string, "textDocument/publishDiagnostics")) return .{ .kind = .ignored };
        const params_value = root.get("params") orelse return error.JsonInvalid;
        if (params_value != .object) return error.JsonInvalid;
        const params = params_value.object;
        const uri_value = params.get("uri") orelse return error.JsonInvalid;
        if (uri_value != .string or uri_value.string.len == 0 or uri_value.string.len > 512) return error.JsonInvalid;
        const diagnostics_value = params.get("diagnostics") orelse return error.JsonInvalid;
        if (diagnostics_value != .array) return error.JsonInvalid;
        const version_value = params.get("version") orelse return .{ .kind = .diagnostics, .uri = uri_value.string, .diagnostic_count = diagnostics_value.array.items.len };
        if (version_value != .integer or version_value.integer < 0 or version_value.integer > std.math.maxInt(i32)) return error.JsonInvalid;
        return .{ .kind = .diagnostics, .uri = uri_value.string, .version = @intCast(version_value.integer), .diagnostic_count = diagnostics_value.array.items.len };
    }
    const id_value = root.get("id") orelse return error.JsonInvalid;
    if (id_value != .integer or id_value.integer < 0 or id_value.integer > std.math.maxInt(u32)) return error.JsonInvalid;
    const has_result = root.contains("result");
    const has_error = root.contains("error");
    if (has_result == has_error) return error.JsonInvalid;
    if (root.get("error")) |rpc_error| if (rpc_error != .object) return error.JsonInvalid;
    if (root.get("result")) |result| {
        if (result == .object) if (result.object.get("capabilities")) |caps_value| {
            if (caps_value != .object) return error.JsonInvalid;
            var advertised: [5]bool = @splat(false);
            const names = [_][]const u8{ "hoverProvider", "definitionProvider", "referencesProvider", "documentSymbolProvider", "diagnosticProvider" };
            for (names, 0..) |name, index| advertised[index] = try capability_enabled(caps_value.object.get(name));
            return .{ .kind = .response, .id = @intCast(id_value.integer), .capabilities = advertised, .has_result = true };
        };
    }
    return .{ .kind = .response, .id = @intCast(id_value.integer), .has_result = has_result };
}

fn capability_enabled(value: ?std.json.Value) !bool {
    const item = value orelse return false;
    return switch (item) {
        .bool => |enabled| enabled,
        .null => false,
        .object => true,
        else => error.JsonInvalid,
    };
}

test "bounded JSON-RPC parser rejects ambiguity and binds diagnostics exactly" {
    var scratch: [Background.max_json_bytes * 4]u8 = undefined;
    const whitespace = try parse_message("{ \"jsonrpc\" : \"2.0\", \"id\" : 1, \"result\" : { \"capabilities\" : { \"hoverProvider\" : true, \"definitionProvider\" : {\"workDoneProgress\":false}, \"referencesProvider\":false } } }", &scratch);
    try std.testing.expectEqual(.response, whitespace.kind);
    try std.testing.expect(whitespace.capabilities.?[0] and whitespace.capabilities.?[1]);
    const pull_diagnostics = try parse_message("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"diagnosticProvider\":{\"interFileDependencies\":false,\"workspaceDiagnostics\":false}}}}", &scratch);
    try std.testing.expect(pull_diagnostics.capabilities.?[@backingInt(protocol.Capability.diagnostics)]);
    const escaped = try parse_message("{\"jsonrpc\":\"2.0\",\"\\u0069d\":2,\"result\":null}", &scratch);
    try std.testing.expectEqual(@as(u32, 2), escaped.id);
    const id_ten = try parse_message("{\"jsonrpc\":\"2.0\",\"id\":10,\"result\":{\"capabilities\":{}}}", &scratch);
    try std.testing.expectEqual(.response, id_ten.kind);
    const max_id = try parse_message("{\"jsonrpc\":\"2.0\",\"id\":4294967295,\"result\":null}", &scratch);
    try std.testing.expectEqual(std.math.maxInt(u32), max_id.id);
    try std.testing.expectError(error.JsonInvalid, parse_message("{\"jsonrpc\":\"2.0\",\"id\":4294967296,\"result\":null}", &scratch));
    const out_of_order = try parse_message("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"message\":\"\\\"version\\\":9, hoverProvider:true\"}}", &scratch);
    try std.testing.expectEqual(@as(u32, 2), out_of_order.id);
    try std.testing.expect(out_of_order.has_result);
    const unrelated = try parse_message("{\"jsonrpc\":\"2.0\",\"method\":\"other\",\"params\":{\"uri\":\"file:///a\",\"version\":7}}", &scratch);
    try std.testing.expectEqual(.ignored, unrelated.kind);
    try std.testing.expectError(error.DuplicateField, parse_message("{\"jsonrpc\":\"2.0\",\"id\":1,\"\\u0069d\":1,\"result\":null}", &scratch));
    try std.testing.expectError(error.JsonInvalid, parse_message("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null,\"error\":{}}", &scratch));
    const diag = try parse_message("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///b\",\"version\":7,\"diagnostics\":[]}}", &scratch);
    try std.testing.expectEqualStrings("file:///b", diag.uri);
    try std.testing.expectEqual(@as(?i32, 7), diag.version);
    const wrong_document = try parse_message("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///other\",\"version\":7,\"diagnostics\":[]}}", &scratch);
    try std.testing.expect(!std.mem.eql(u8, wrong_document.uri, diag.uri));
    const unversioned = try parse_message("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///a\",\"diagnostics\":[]}}", &scratch);
    try std.testing.expect(unversioned.version == null);
    var deep: [128]u8 = undefined;
    @memset(&deep, '[');
    deep[64] = '0';
    @memset(deep[65..], ']');
    try std.testing.expectError(error.JsonInvalid, parse_message(&deep, &scratch));
    var oversized: [Background.max_json_bytes + 1]u8 = undefined;
    @memset(&oversized, 0);
    try std.testing.expectError(error.ResponseTooLarge, parse_message(&oversized, &scratch));
}

test "failed initialized notification cannot commit capabilities" {
    const failing_write = struct {
        fn operate(_: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            std.debug.assert(operation == .file_write_streaming);
            return .{ .file_write_streaming = error.BrokenPipe };
        }
    };
    var io = std.testing.io;
    var vtable = io.vtable.*;
    vtable.operate = failing_write.operate;
    io.vtable = &vtable;
    var state: client.Client = undefined;
    state.init();
    state.running = true;
    var wire: [128]u8 = undefined;
    const initialized = try state.initialized(&wire);
    const deadline = std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = .fromSeconds(1), .clock = .awake });
    try std.testing.expectError(error.WriteFailed, send(io, std.Io.File.stdin(), initialized, deadline));
    try std.testing.expect(!state.session.initialized and !state.capabilities_known);
}

test "initialize reply binds exact request and commits only before startup deadline" {
    const background = try std.testing.allocator.create(Background);
    defer std.testing.allocator.destroy(background);
    background.init();
    background.io = std.testing.io;
    background.state = try std.testing.allocator.create(client.Client);
    defer std.testing.allocator.destroy(background.state);
    background.state.init();
    background.state.running = true;
    var wire: [Background.max_json_bytes]u8 = undefined;
    const request = try background.state.initialize("file:///work", &wire);
    background.initialize_request = background.pending_key(json_unsigned(request, "\"id\":").?);
    background.startup_deadline = std.Io.Clock.Timestamp.now(background.io, .awake).addDuration(.{ .raw = .fromSeconds(1), .clock = .awake });
    background.handle_json("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"hoverProvider\":true}}}");
    try std.testing.expect(background.initialize_capabilities != null);
    try std.testing.expect(!background.state.session.initialized and !background.capabilities_known);
    background.handle_json("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"hoverProvider\":true}}}");
    try std.testing.expect(background.failed() == null);
    background.startup_deadline = std.Io.Clock.Timestamp.now(background.io, .awake);
    background.commit_initialized();
    try std.testing.expectEqual(@as(?Error, error.ChildTimeout), background.failed());
    try std.testing.expect(!background.state.session.initialized and !background.capabilities_known);
}

test "shutdown accepts one exact successful response and suppresses late replies" {
    const background = try std.testing.allocator.create(Background);
    defer std.testing.allocator.destroy(background);
    background.init();
    background.io = std.testing.io;
    background.shutdown_id = 9;
    background.handle_json("{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":null}");
    try std.testing.expect(!background.shutdown_acknowledged and background.failed() == null);
    background.handle_json("{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":null}");
    try std.testing.expect(background.shutdown_acknowledged and background.failed() == null);
    background.handle_json("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"hoverProvider\":true}}}");
    try std.testing.expect(background.failed() == null and !background.capabilities_known);
}

test "matching malformed initialize response is terminal" {
    const background = try std.testing.allocator.create(Background);
    defer std.testing.allocator.destroy(background);
    background.init();
    background.io = std.testing.io;
    background.state = try std.testing.allocator.create(client.Client);
    defer std.testing.allocator.destroy(background.state);
    background.state.init();
    background.state.running = true;
    var wire: [Background.max_json_bytes]u8 = undefined;
    const request = try background.state.initialize("file:///work", &wire);
    background.initialize_request = background.pending_key(json_unsigned(request, "\"id\":").?);
    background.handle_json("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}");
    try std.testing.expectEqual(@as(?Error, error.ResponseInvalid), background.failed());
}

test "inbound capacity failure preserves queued bytes and publishes nothing after failure" {
    const background = try std.testing.allocator.create(Background);
    defer std.testing.allocator.destroy(background);
    background.init();
    background.io = std.testing.io;
    for (0..background.inbound.len) |index| {
        background.inbound[index].json[0] = @intCast(index);
        background.inbound[index].len = 1;
    }
    background.inbound_len = background.inbound.len;
    const capacity_failure = background.push_inbound("overflow") orelse return error.ExpectedCapacityFailure;
    try std.testing.expectEqual(error.CapacityExceeded, capacity_failure);
    try std.testing.expectEqual(background.inbound.len, background.inbound_len);
    for (0..background.inbound.len) |index| {
        try std.testing.expectEqual(@as(u8, @intCast(index)), background.inbound[index].json[0]);
        try std.testing.expectEqual(@as(usize, 1), background.inbound[index].len);
    }
    background.publish(.hover, "file:///a.zig", 1, 0, "{\"result\":null}");
    background.record_failure(error.CapacityExceeded);
    background.drain_inbound();
    try std.testing.expectEqual(background.inbound.len, background.inbound_len);
    var uri: [512]u8 = undefined;
    var json: [32]u8 = undefined;
    try std.testing.expect(background.take(&uri, &json) == null);
    try std.testing.expect(!background.supports(.hover));
}

test "publication capacity failure is visible instead of silently losing replies" {
    const background = try std.testing.allocator.create(Background);
    defer std.testing.allocator.destroy(background);
    background.init();
    background.io = std.testing.io;
    for (0..background.published.len) |_| background.publish(.hover, "x", 1, 0, "{}");
    try std.testing.expectEqual(background.published.len, background.published_len);
    background.publish(.hover, "x", 1, 0, "overflow");
    try std.testing.expectEqual(@as(?Error, error.CapacityExceeded), background.failed());
    try std.testing.expectEqualStrings("{}", background.published[0].json[0..2]);
    var uri: [8]u8 = undefined;
    var json: [8]u8 = undefined;
    try std.testing.expect(background.take(&uri, &json) == null);
}

test "failed or closing transport rejects commands without changing its queue" {
    const background = try std.testing.allocator.create(Background);
    defer std.testing.allocator.destroy(background);
    background.init();
    background.io = std.testing.io;
    try background.request(.hover, "x", .{ .line = 0, .character = 0 });
    background.record_failure(error.ChildTimeout);
    try std.testing.expectError(error.TransportFailed, background.request(.hover, "x", .{ .line = 0, .character = 0 }));
    try std.testing.expectEqual(@as(usize, 1), background.command_len);
    try std.testing.expectEqual(@as(usize, 0), background.command_head);
    background.init();
    background.io = std.testing.io;
    background.graceful_stopping = true;
    try std.testing.expectError(error.TransportFailed, background.request(.hover, "x", .{ .line = 0, .character = 0 }));
    try std.testing.expectEqual(@as(usize, 0), background.command_len);
}

test "outbound encoding failure becomes terminal transport failure" {
    const background = try std.testing.allocator.create(Background);
    defer std.testing.allocator.destroy(background);
    background.init();
    background.io = std.testing.io;
    background.state = try std.testing.allocator.create(client.Client);
    defer std.testing.allocator.destroy(background.state);
    background.state.init();
    background.state.running = true;
    background.state.session.initialized = true;
    var wire: [Background.max_json_bytes]u8 = undefined;
    _ = try background.state.open(.{ .uri = "x", .language_id = "zig", .version = 0, .text = "ok" }, &wire);
    var invalid = Background.Change{ .uri = undefined, .uri_len = 1, .version = 1, .text = undefined, .text_len = 1 };
    invalid.uri[0] = 'x';
    invalid.text[0] = 0xff;
    try std.testing.expect(background.encode_command_or_fail(.{ .change = invalid }, &wire) == null);
    try std.testing.expectEqual(@as(?Error, error.TransportFailed), background.failed());
}

test "outbound write failure suppresses advanced document state and publications" {
    const failing_write = struct {
        fn operate(_: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            std.debug.assert(operation == .file_write_streaming);
            std.debug.assert(operation.file_write_streaming.data.len > 0);
            return .{ .file_write_streaming = error.BrokenPipe };
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.operate = failing_write.operate;
    const background = try std.testing.allocator.create(Background);
    defer std.testing.allocator.destroy(background);
    background.init();
    background.io = std.testing.io;
    background.io.vtable = &vtable;
    background.state = try std.testing.allocator.create(client.Client);
    defer std.testing.allocator.destroy(background.state);
    background.state.init();
    background.state.running = true;
    background.state.session.initialized = true;
    var wire: [Background.max_json_bytes]u8 = undefined;
    _ = try background.state.open(.{ .uri = "x", .language_id = "zig", .version = 0, .text = "ok" }, &wire);
    var change = Background.Change{ .uri = undefined, .uri_len = 1, .version = 1, .text = undefined, .text_len = 1 };
    change.uri[0] = 'x';
    change.text[0] = 'y';
    // The injected operation never touches this borrowed process handle.
    background.write_command(std.Io.File.stdin(), .{ .change = change }, &wire);
    try std.testing.expect(background.command_write_started);
    try std.testing.expectEqual(@as(?Error, error.WriteFailed), background.failed());
    try std.testing.expectEqual(@as(?i32, 1), background.state.document_version("x"));
    background.publish(.hover, "x", 1, 0, "{}");
    var uri: [8]u8 = undefined;
    var json: [8]u8 = undefined;
    try std.testing.expect(background.take(&uri, &json) == null);
}

test "publication copies URI and JSON only when both caller buffers fit" {
    const background = try std.testing.allocator.create(Background);
    defer std.testing.allocator.destroy(background);
    background.init();
    background.io = std.testing.io;
    background.publish(.diagnostics, "file:///a.zig", 4, 1, "{\"ok\":true}");
    var short_uri: [4]u8 = @splat(0xa5);
    var json: [32]u8 = @splat(0x5a);
    try std.testing.expect(background.take(&short_uri, &json) == null);
    try std.testing.expectEqualSlices(u8, &@as([4]u8, @splat(0xa5)), &short_uri);
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0x5a)), &json);
    try std.testing.expectEqual(@as(usize, 1), background.published_len);
    var uri: [512]u8 = @splat(0x3c);
    var short_json: [2]u8 = @splat(0xc3);
    try std.testing.expect(background.take(&uri, &short_json) == null);
    try std.testing.expectEqualSlices(u8, &@as([512]u8, @splat(0x3c)), &uri);
    try std.testing.expectEqualSlices(u8, &@as([2]u8, @splat(0xc3)), &short_json);
    try std.testing.expectEqual(@as(usize, 1), background.published_len);
    try std.testing.expect(background.take(uri[0..16], uri[8..24]) == null);
    try std.testing.expectEqual(@as(usize, 1), background.published_len);
    try std.testing.expect(background.take(background.published_uris[0][0..], &json) == null);
    const publication = background.take(&uri, &json) orelse return error.ExpectedPublication;
    try std.testing.expectEqualStrings("file:///a.zig", publication.document_uri);
    try std.testing.expectEqualStrings("{\"ok\":true}", publication.json);
    try std.testing.expectEqual(@as(usize, 0), background.published_len);
    background.publish(.diagnostics, "file:///b.zig", 5, 0, "{\"next\":true}");
    var next_uri: [512]u8 = undefined;
    var next_json: [32]u8 = undefined;
    const next = background.take(&next_uri, &next_json) orelse return error.ExpectedPublication;
    try std.testing.expectEqualStrings("{\"next\":true}", next.json);
    try std.testing.expectEqualStrings("{\"ok\":true}", publication.json);
}

fn earlier_deadline(io: std.Io, left: std.Io.Clock.Timestamp, right: std.Io.Clock.Timestamp) std.Io.Clock.Timestamp {
    std.debug.assert(left.clock == right.clock);
    std.debug.assert(left.clock == .awake);
    _ = io;
    return if (left.compare(.lt, right)) left else right;
}

fn far_deadline(io: std.Io) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = .fromSeconds(30), .clock = .awake });
}

fn json_unsigned(json: []const u8, prefix: []const u8) ?u32 {
    const start = (std.mem.indexOf(u8, json, prefix) orelse return null) + prefix.len;
    var end = start;
    while (end < json.len and std.ascii.isDigit(json[end])) : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(u32, json[start..end], 10) catch null;
}

fn send(io: std.Io, pipe: std.Io.File, json: []const u8, deadline: std.Io.Clock.Timestamp) Error!void {
    var header: [48]u8 = undefined;
    const prefix = std.fmt.bufPrint(&header, "Content-Length: {d}\r\n\r\n", .{json.len}) catch return error.TransportFailed;
    try write_all(io, pipe, prefix, deadline);
    try write_all(io, pipe, json, deadline);
}
fn write_all(io: std.Io, pipe: std.Io.File, bytes: []const u8, deadline: std.Io.Clock.Timestamp) Error!void {
    contained_process.write_all(io, pipe, bytes, deadline) catch |err| switch (err) {
        error.Timeout => return error.ChildTimeout,
        error.Failed => return error.WriteFailed,
    };
}
fn receive(io: std.Io, pipe: std.Io.File, framer: *protocol.Framer, scratch: []u8, output: []u8, deadline: std.Io.Clock.Timestamp) Error![]u8 {
    while (framer.body() == null) {
        const count = contained_process.read_some(io, pipe, scratch, deadline) catch |err| switch (err) {
            error.Timeout => return error.ChildTimeout,
            error.Failed => return error.ReadFailed,
        };
        if (count == 0 or count > scratch.len) return error.ReadFailed;
        _ = framer.feed(scratch[0..count], scratch.len) catch |err| switch (err) {
            error.FrameTooLarge => return error.ResponseTooLarge,
            else => return error.ResponseInvalid,
        };
    }
    const body = framer.body().?;
    if (body.len == 0 or body.len > output.len or body[0] != '{' or !std.unicode.utf8ValidateSlice(body)) return error.ResponseTooLarge;
    @memcpy(output[0..body.len], body);
    framer.consume() catch return error.ResponseInvalid;
    return output[0..body.len];
}
fn rangesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    return left_start < right_start + right.len and right_start < left_start + left.len;
}
