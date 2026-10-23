const builtin = @import("builtin");
const std = @import("std");
const files = @import("../files.zig");
const client = @import("../lsp/client.zig");
const protocol = @import("../lsp/protocol.zig");
const transport = @import("../lsp/transport.zig");
const navigation = @import("../lsp/navigation.zig");

pub const max_path_bytes = std.Io.Dir.max_path_bytes;
pub const executable_hash_chunk_bytes = 64 * 1024;
pub const max_executable_hash_bytes = 256 * 1024 * 1024;

pub const Stage = enum { detached, picking_executable, picking_workspace, review, starting, ready, failed };
pub const Error = error{ InvalidResult, ReviewRequired, ChangedObservation, Untrusted, Unsupported } || client.Error || files.LoadError || protocol.Error || std.Thread.SpawnError;

/// Stable, caller-owned backing. Allocate this before service start and never move it.
pub const Storage = struct {
    state: client.Client = undefined,
    worker: transport.Background = undefined,
    grants: [1]client.Identity = undefined,
    executable_hash_chunk: [executable_hash_chunk_bytes]u8 = undefined,
    executable: [max_path_bytes]u8 = undefined,
    argv: [1][]const u8 = undefined,
    workspace: [max_path_bytes]u8 = undefined,
    document_path: [max_path_bytes]u8 = undefined,
    uri: [512]u8 = undefined,
    root_uri: [512]u8 = undefined,
    publication: [transport.Background.max_json_bytes]u8 = undefined,
    publication_uri: [512]u8 = undefined,
    navigation: navigation.Model = .{},
};

/// UI state only sends current valid UTF-8 result bytes. It never discovers or installs servers.
pub const Service = struct {
    storage: *Storage,
    stage: Stage = .detached,
    executable_len: usize = 0,
    workspace_len: usize = 0,
    document_path_len: usize = 0,
    uri_len: usize = 0,
    root_uri_len: usize = 0,
    identity: ?client.Identity = null,
    version: i32 = 0,
    diagnostics: usize = 0,
    diagnostics_version: ?i32 = null,
    navigation_error: ?anyerror = null,
    failure: ?anyerror = null,

    pub fn init(self: *Service, storage: *Storage) void {
        self.* = .{ .storage = storage };
        storage.state.init();
        storage.worker.init();
        storage.navigation = .{};
        std.debug.assert(self.stage == .detached and !storage.state.running);
    }

    pub fn choose_executable(self: *Service, executable_path: []const u8) Error!void {
        if (!std.fs.path.isAbsolute(executable_path) or executable_path.len == 0 or executable_path.len > self.storage.executable.len) return error.InvalidExecutable;
        @memcpy(self.storage.executable[0..executable_path.len], executable_path);
        self.executable_len = executable_path.len;
        self.stage = .picking_workspace;
        std.debug.assert(self.executable_len > 0);
    }

    pub fn choose_workspace(self: *Service, workspace: []const u8, document_path: []const u8, result: []const u8) Error!void {
        if (!std.fs.path.isAbsolute(workspace) or !std.fs.path.isAbsolute(document_path) or workspace.len == 0 or workspace.len > self.storage.workspace.len or document_path.len == 0 or document_path.len > self.storage.document_path.len) return error.InvalidWorkspace;
        if (!std.unicode.utf8ValidateSlice(workspace) or !std.unicode.utf8ValidateSlice(document_path) or !std.unicode.utf8ValidateSlice(result)) return error.InvalidResult;
        @memcpy(self.storage.workspace[0..workspace.len], workspace);
        @memcpy(self.storage.document_path[0..document_path.len], document_path);
        self.workspace_len = workspace.len;
        self.document_path_len = document_path.len;
        self.uri_len = try path_uri(document_path, &self.storage.uri);
        self.root_uri_len = try path_uri(workspace, &self.storage.root_uri);
        self.version = 0;
        self.stage = .review;
        std.debug.assert(self.uri_len > 0 and self.root_uri_len > 0);
    }

    /// Observation must complete before visible confirmation. Config is literal empty object; argv is exact executable only.
    pub fn review(self: *Service, io: std.Io) Error!client.Identity {
        if (self.stage != .review) return error.ReviewRequired;
        const digest = files.fingerprint(io, self.executable(), &self.storage.executable_hash_chunk, max_executable_hash_bytes) catch |err| {
            self.stage = .failed;
            self.failure = err;
            return err;
        };
        const configuration = self.server();
        const identity = configuration.identity_from_digest(digest);
        self.identity = identity;
        std.debug.assert(!self.storage.state.running);
        return identity;
    }

    /// Re-observes binary immediately before spawn, so changed bytes invalidate review rather than expanding trust.
    pub fn confirm(self: *Service, io: std.Io, result: []const u8) Error!void {
        if (self.stage != .review or self.identity == null) return error.ReviewRequired;
        if (result.len > client.max_document_bytes) return error.DocumentTooLarge;
        if (!std.unicode.utf8ValidateSlice(result)) return error.InvalidResult;
        const digest = files.fingerprint(io, self.executable(), &self.storage.executable_hash_chunk, max_executable_hash_bytes) catch |err| {
            self.stage = .failed;
            self.failure = err;
            return err;
        };
        const configuration = self.server();
        const observed = configuration.identity_from_digest(digest);
        if (!observed.eql(self.identity.?)) return error.ChangedObservation;
        self.storage.state.init();
        var trust = client.TrustStore{ .grants = &self.storage.grants };
        try trust.grant(observed);
        const identity = try self.storage.state.begin_observed(configuration, digest, &trust);
        self.stage = .starting;
        self.identity = identity;
        transport_start(self, io, configuration, result) catch |err| {
            self.storage.state.revoke(identity) catch {};
            self.stage = .failed;
            self.failure = err;
            return err;
        };
        self.stage = .ready;
        std.debug.assert(self.storage.state.running and self.identity != null);
    }

    pub fn change(self: *Service, result: []const u8) Error!void {
        if (self.stage != .ready) return error.Untrusted;
        if (!std.unicode.utf8ValidateSlice(result)) return error.InvalidResult;
        const next_version = std.math.add(i32, self.version, 1) catch return error.InvalidVersion;
        try self.storage.worker.change(self.uri(), next_version, result);
        self.version = next_version;
        self.storage.navigation.count = 0;
        self.navigation_error = null;
        self.diagnostics = 0;
        self.diagnostics_version = null;
    }

    pub fn request(self: *Service, capability: protocol.Capability, position: protocol.Position) Error!void {
        if (self.stage != .ready) return error.Untrusted;
        if (!self.storage.worker.supports(capability)) return error.Unsupported;
        try self.storage.worker.request(capability, self.uri(), position);
    }

    pub fn poll(self: *Service) ?transport.Background.Publication {
        if (self.stage != .ready) return null;
        if (self.storage.worker.failed()) |failure| {
            self.fail_transport(failure);
            return null;
        }
        for (0..client.max_results) |_| {
            const publication = self.storage.worker.take(&self.storage.publication_uri, &self.storage.publication) orelse return null;
            if (!std.mem.eql(u8, publication.document_uri, self.uri()) or publication.version != self.version) continue;
            if (publication.capability == .diagnostics) {
                self.diagnostics = publication.diagnostic_count;
                self.diagnostics_version = publication.version;
            }
            if (publication.capability == .definition or publication.capability == .references or publication.capability == .document_symbol) {
                self.navigation_error = null;
                self.storage.navigation.load(publication.json, self.uri(), self.version) catch |err| {
                    self.navigation_error = err;
                };
            }
            return publication;
        }
        return null;
    }

    fn fail_transport(self: *Service, failure: anyerror) void {
        self.failure = failure;
        self.diagnostics = 0;
        self.diagnostics_version = null;
        self.navigation_error = null;
        self.storage.navigation.count = 0;
        self.stage = .failed;
        std.debug.assert(self.stage == .failed);
    }

    /// Normal detach permits bounded LSP shutdown; trust revocation remains immediate.
    pub fn close(self: *Service) void {
        if (self.identity) |identity| {
            if (self.storage.worker.worker_thread != null) {
                self.storage.worker.close(identity) catch {};
            } else if (self.storage.state.running) {
                self.storage.state.revoke(identity) catch {};
            }
        }
        self.identity = null;
        self.storage.navigation.count = 0;
        self.navigation_error = null;
        self.stage = .detached;
        self.diagnostics = 0;
        self.diagnostics_version = null;
        std.debug.assert(self.stage == .detached);
    }

    pub fn revoke(self: *Service) void {
        if (self.identity) |identity| {
            if (self.storage.worker.worker_thread != null) {
                self.storage.worker.revoke(identity) catch {};
            } else if (self.storage.state.running) {
                self.storage.state.revoke(identity) catch {};
            }
        }
        self.identity = null;
        self.storage.navigation.count = 0;
        self.navigation_error = null;
        self.stage = .detached;
        self.diagnostics = 0;
        self.diagnostics_version = null;
        std.debug.assert(self.stage == .detached);
    }

    pub fn executable(self: *const Service) []const u8 {
        return self.storage.executable[0..self.executable_len];
    }

    pub fn uri(self: *const Service) []const u8 {
        return self.storage.uri[0..self.uri_len];
    }

    fn server(self: *const Service) client.Server {
        const executable_path = self.executable();
        const mutable_storage: *Storage = @constCast(self.storage);
        mutable_storage.argv[0] = executable_path;
        return .{ .executable = executable_path, .argv = &mutable_storage.argv, .workspace = self.storage.workspace[0..self.workspace_len], .root_uri = self.storage.root_uri[0..self.root_uri_len], .config_bytes = "{}" };
    }

    fn transport_start(self: *Service, io: std.Io, configuration: client.Server, result: []const u8) !void {
        try self.storage.worker.start(io, &self.storage.state, configuration);
        errdefer self.storage.worker.revoke(self.identity.?) catch {};
        try self.storage.worker.open(.{ .uri = self.uri(), .language_id = language_id(self.storage.document_path[0..self.document_path_len]), .version = self.version, .text = result });
    }
};

pub fn language_id(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".zig")) return "zig";
    if (std.ascii.eqlIgnoreCase(extension, ".json")) return "json";
    if (std.ascii.eqlIgnoreCase(extension, ".js")) return "javascript";
    if (std.ascii.eqlIgnoreCase(extension, ".ts")) return "typescript";
    if (std.ascii.eqlIgnoreCase(extension, ".rs")) return "rust";
    if (std.ascii.eqlIgnoreCase(extension, ".lua")) return "lua";
    if (std.ascii.eqlIgnoreCase(extension, ".nu")) return "nushell";
    if (std.ascii.eqlIgnoreCase(extension, ".yaml") or std.ascii.eqlIgnoreCase(extension, ".yml")) return "yaml";
    if (std.ascii.eqlIgnoreCase(extension, ".toml")) return "toml";
    return "plaintext";
}

fn path_uri(path: []const u8, destination: []u8) Error!usize {
    const uri = try protocol.pathToUri(path, destination);
    return uri.len;
}

test "result LSP language table remains safe and unsupported extensions are plaintext" {
    try std.testing.expectEqualStrings("zig", language_id("C:/result.zig"));
    try std.testing.expectEqualStrings("plaintext", language_id("C:/result.unknown"));
    try std.testing.expectEqualStrings("plaintext", language_id("C:/result"));
}

test "result LSP chooser builds percent-escaped output URI without source input" {
    var storage: Storage = undefined;
    var service: Service = undefined;
    service.init(&storage);
    if (builtin.os.tag == .windows) {
        try service.choose_executable("C:/tools/server.exe");
        try service.choose_workspace("C:/work", "C:/work/result file #?.zig", "const x = 1;");
        try std.testing.expectEqualStrings("file:///C:/work/result%20file%20%23%3F.zig", service.uri());
    } else {
        try service.choose_executable("/tools/server");
        try service.choose_workspace("/work", "/work/result file #?.zig", "const x = 1;");
        try std.testing.expectEqualStrings("file:///work/result%20file%20%23%3F.zig", service.uri());
    }
    try std.testing.expectEqual(Stage.review, service.stage);
    try std.testing.expectEqual(@as(i32, 0), service.version);
}

test "failed transport suppresses current LSP publications and presentation" {
    const storage = try std.testing.allocator.create(Storage);
    defer std.testing.allocator.destroy(storage);
    var service: Service = undefined;
    service.init(storage);
    storage.worker.io = std.testing.io;
    service.stage = .ready;
    service.diagnostics = 3;
    service.diagnostics_version = 2;
    service.storage.navigation.count = 1;
    storage.worker.published[0].json[0] = '{';
    storage.worker.published[0].len = 1;
    storage.worker.published_uri_lengths[0] = 1;
    storage.worker.published_uris[0][0] = 'x';
    storage.worker.published_capability[0] = .hover;
    storage.worker.published_version[0] = 2;
    storage.worker.published_len = 1;
    storage.worker.failure = error.WriteFailed;
    try std.testing.expect(service.poll() == null);
    try std.testing.expectEqual(Stage.failed, service.stage);
    try std.testing.expectEqual(@as(usize, 0), service.diagnostics);
    try std.testing.expect(service.diagnostics_version == null);
    try std.testing.expectEqual(@as(usize, 0), service.storage.navigation.count);
}

test "result LSP rejects foreign same-version replies and preserves failed updates" {
    const storage = try std.testing.allocator.create(Storage);
    defer std.testing.allocator.destroy(storage);
    var service: Service = undefined;
    service.init(storage);
    storage.worker.io = std.testing.io;
    service.stage = .ready;
    service.version = 2;
    service.uri_len = 1;
    storage.uri[0] = 'x';
    storage.worker.command_len = storage.worker.commands.len;
    try std.testing.expectError(error.CapacityExceeded, service.change("current"));
    try std.testing.expectEqual(@as(i32, 2), service.version);
    for ([_]protocol.Capability{ .hover, .definition, .references, .document_symbol, .diagnostics }) |capability| {
        storage.worker.published_head = 0;
        storage.worker.published_len = 2;
        for (0..2) |index| {
            @memcpy(storage.worker.published[index].json[0..2], "{}");
            storage.worker.published[index].len = 2;
            storage.worker.published_capability[index] = capability;
            storage.worker.published_uri_lengths[index] = 1;
            storage.worker.published_uris[index][0] = if (index == 0) 'y' else 'x';
            storage.worker.published_version[index] = 2;
            storage.worker.published_diagnostic_count[index] = 3;
        }
        const publication = service.poll() orelse return error.CurrentReplyLost;
        try std.testing.expectEqual(@as(i32, 2), publication.version);
        try std.testing.expectEqual(capability, publication.capability);
        try std.testing.expect(service.poll() == null);
    }
    try std.testing.expectEqual(@as(usize, 3), service.diagnostics);
    storage.worker.command_len = 0;
    try service.change("current");
    try std.testing.expectEqual(@as(i32, 3), service.version);
    try std.testing.expectEqual(@as(usize, 0), service.diagnostics);
}
