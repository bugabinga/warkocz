const std = @import("std");
const files = @import("../files.zig");
const protocol = @import("protocol.zig");

pub const Fingerprint = [std.crypto.hash.sha2.Sha256.digest_length]u8;
pub const max_arguments = 8;
pub const max_documents = 8;
pub const max_document_bytes = 64 * 1024;
pub const max_results = 16;

pub const Error = error{
    ConsentRequired,
    TrustDenied,
    InvalidExecutable,
    InvalidWorkspace,
    InvalidArgument,
    CapacityExceeded,
    DocumentTooLarge,
    DocumentUnknown,
    InvalidVersion,
    Stale,
    NotRunning,
    AlreadyRunning,
    TransportFailed,
} || protocol.Error || files.LoadError || std.process.SpawnError || std.Io.File.Writer.Error;

/// Exact, revocable consent identity. Config is caller-observed bytes, never executed.
pub const Identity = struct {
    executable: Fingerprint,
    workspace: Fingerprint,
    arguments: Fingerprint,
    config: Fingerprint,

    pub fn eql(left: Identity, right: Identity) bool {
        return std.mem.eql(u8, &left.executable, &right.executable) and std.mem.eql(u8, &left.workspace, &right.workspace) and std.mem.eql(u8, &left.arguments, &right.arguments) and std.mem.eql(u8, &left.config, &right.config);
    }
};

pub const TrustStore = struct {
    grants: []Identity,
    count: usize = 0,

    pub fn grant(self: *TrustStore, identity: Identity) error{CapacityExceeded}!void {
        std.debug.assert(self.count <= self.grants.len);
        if (self.allows(identity)) return;
        if (self.count == self.grants.len) return error.CapacityExceeded;
        self.grants[self.count] = identity;
        self.count += 1;
        std.debug.assert(self.count <= self.grants.len);
    }

    pub fn allows(self: *const TrustStore, identity: Identity) bool {
        std.debug.assert(self.count <= self.grants.len);
        for (self.grants[0..self.count]) |stored| if (stored.eql(identity)) return true;
        return false;
    }

    pub fn revoke(self: *TrustStore, identity: Identity) bool {
        std.debug.assert(self.count <= self.grants.len);
        for (self.grants[0..self.count], 0..) |stored, index| {
            if (!stored.eql(identity)) continue;
            self.count -= 1;
            self.grants[index] = self.grants[self.count];
            std.debug.assert(self.count < self.grants.len);
            return true;
        }
        return false;
    }
};

/// Only explicit absolute argv is accepted. No PATH lookup, discovery, shell, config, or plugin loading.
pub const Server = struct {
    executable: []const u8,
    argv: []const []const u8,
    workspace: []const u8,
    root_uri: []const u8,
    config_bytes: []const u8,

    pub fn identity(self: Server, executable_bytes: []const u8) Identity {
        return self.identity_from_digest(digest(executable_bytes));
    }

    pub fn identity_from_digest(self: Server, executable_digest: Fingerprint) Identity {
        std.debug.assert(self.argv.len > 0);
        std.debug.assert(self.argv[0].len > 0);
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for (self.argv) |argument| {
            var length: [8]u8 = undefined;
            std.mem.writeInt(u64, &length, argument.len, .little);
            hasher.update(&length);
            hasher.update(argument);
        }
        var arguments: Fingerprint = undefined;
        hasher.final(&arguments);
        return .{ .executable = executable_digest, .workspace = workspace_identity(self.workspace, self.root_uri), .arguments = arguments, .config = digest(self.config_bytes) };
    }

    pub fn validate(self: Server) Error!void {
        if (self.executable.len == 0 or !std.fs.path.isAbsolute(self.executable)) return error.InvalidExecutable;
        if (self.workspace.len == 0 or !std.fs.path.isAbsolute(self.workspace)) return error.InvalidWorkspace;
        if (self.argv.len == 0 or self.argv.len > max_arguments or !std.mem.eql(u8, self.argv[0], self.executable)) return error.InvalidArgument;
        if (std.mem.indexOfScalar(u8, self.executable, 0) != null or std.mem.indexOfScalar(u8, self.workspace, 0) != null) return error.InvalidArgument;
        for (self.argv) |argument| if (argument.len == 0 or std.mem.indexOfScalar(u8, argument, 0) != null) return error.InvalidArgument;
        if (!std.unicode.utf8ValidateSlice(self.root_uri)) return error.InvalidArgument;
        std.debug.assert(self.argv.len <= max_arguments);
        std.debug.assert(self.argv[0].ptr == self.executable.ptr);
    }
};

pub const Document = struct {
    uri: []const u8,
    language_id: []const u8,
    version: i32,
    text: []const u8,
};

const StoredDocument = struct {
    active: bool = false,
    uri_len: usize = 0,
    language_len: usize = 0,
    text_len: usize = 0,
    version: i32 = 0,
    uri: [512]u8 = undefined,
    language: [64]u8 = undefined,
    text: [max_document_bytes]u8 = undefined,

    fn set(self: *StoredDocument, document: Document) Error!void {
        if (document.uri.len == 0 or document.uri.len > self.uri.len or document.language_id.len == 0 or document.language_id.len > self.language.len or document.text.len > self.text.len) return error.DocumentTooLarge;
        if (!std.unicode.utf8ValidateSlice(document.uri) or !std.unicode.utf8ValidateSlice(document.language_id) or !std.unicode.utf8ValidateSlice(document.text)) return error.InvalidVersion;
        @memcpy(self.uri[0..document.uri.len], document.uri);
        @memcpy(self.language[0..document.language_id.len], document.language_id);
        @memcpy(self.text[0..document.text.len], document.text);
        self.uri_len = document.uri.len;
        self.language_len = document.language_id.len;
        self.text_len = document.text.len;
        self.version = document.version;
        self.active = true;
        std.debug.assert(self.text_len <= self.text.len);
    }

    fn value(self: *const StoredDocument) Document {
        std.debug.assert(self.active);
        return .{ .uri = self.uri[0..self.uri_len], .language_id = self.language[0..self.language_len], .version = self.version, .text = self.text[0..self.text_len] };
    }
};

/// UI consumes only bounded results. Server input and historical content never leave this worker API.
pub const Result = struct {
    capability: protocol.Capability,
    document_uri: []const u8,
    document_version: i32,
    request: protocol.RequestKey,
    json: []const u8,
};

pub const Client = struct {
    documents: [max_documents]StoredDocument = undefined,
    pending_slots: [max_results]?protocol.RequestKey = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
    pending: protocol.Pending = undefined,
    session: protocol.Session = undefined,
    identity: ?Identity = null,
    running: bool = false,
    capabilities: protocol.ResultModel = .{},
    capabilities_known: bool = false,

    pub fn init(self: *Client) void {
        self.* = .{};
        self.pending = .{ .slots = &self.pending_slots };
        self.session = .{ .pending = &self.pending };
        std.debug.assert(!self.running);
        std.debug.assert(self.pending.slots.len == max_results);
    }

    /// Starts only after consent for this exact binary contents, workspace, and config context.
    pub fn begin(self: *Client, server: Server, executable_bytes: []const u8, trust: *const TrustStore) Error!Identity {
        return self.begin_observed(server, digest(executable_bytes), trust);
    }

    /// Starts from a caller-observed executable digest, preserving exact trust validation.
    pub fn begin_observed(self: *Client, server: Server, executable_digest: Fingerprint, trust: *const TrustStore) Error!Identity {
        try server.validate();
        if (self.running) return error.AlreadyRunning;
        const identity = server.identity_from_digest(executable_digest);
        if (!trust.allows(identity)) return error.ConsentRequired;
        self.identity = identity;
        self.running = true;
        std.debug.assert(self.identity.?.eql(identity));
        return identity;
    }

    pub fn initialize(self: *Client, root_uri: []const u8, output: []u8) Error![]u8 {
        if (!self.running) return error.NotRunning;
        const key = try self.pending.allocate();
        return self.session.initialize(output, key.id, root_uri) catch |err| {
            self.pending.accept(key) catch {};
            return err;
        };
    }

    /// Encodes initialized without mutating session or capability visibility.
    pub fn initialized(self: *Client, output: []u8) Error![]u8 {
        if (!self.running) return error.NotRunning;
        return self.session.notifyInitialized(output);
    }

    /// Commits only after initialized notification has been written successfully.
    pub fn commit_initialized(self: *Client, advertised: [5]bool) Error!void {
        if (!self.running) return error.NotRunning;
        try self.session.markInitialized();
        self.set_capabilities(advertised);
        std.debug.assert(self.session.initialized and self.capabilities_known);
    }

    pub fn open(self: *Client, document: Document, output: []u8) Error![]u8 {
        if (!self.running or !self.session.initialized) return error.NotRunning;
        const slot = self.find_or_free(document.uri) orelse return error.CapacityExceeded;
        try slot.set(document);
        const value = slot.value();
        return protocol.didOpen(output, .{ .uri = value.uri, .language_id = value.language_id, .version = value.version, .exact_text = value.text });
    }

    pub fn change(self: *Client, uri: []const u8, version: i32, text: []const u8, output: []u8) Error![]u8 {
        if (!self.running) return error.NotRunning;
        const slot = self.find(uri) orelse return error.DocumentUnknown;
        if (version <= slot.version or text.len > slot.text.len or !std.unicode.utf8ValidateSlice(text)) return error.InvalidVersion;
        @memcpy(slot.text[0..text.len], text);
        slot.text_len = text.len;
        slot.version = version;
        std.debug.assert(slot.version == version and slot.text_len <= slot.text.len);
        return protocol.didChange(output, uri, version, text);
    }

    pub fn request(self: *Client, capability: protocol.Capability, uri: []const u8, position: protocol.Position, output: []u8) Error![]u8 {
        if (!self.running) return error.NotRunning;
        if (self.capabilities_known and !self.capabilities.supports(capability)) return error.UnsupportedRequest;
        const document = self.find(uri) orelse return error.DocumentUnknown;
        std.debug.assert(document.version >= 0);
        const key = try self.pending.allocate();
        return self.session.request(output, key.id, capability, uri, position) catch |err| {
            self.pending.accept(key) catch {};
            return err;
        };
    }

    /// Records only advertised server features. Missing methods stay disabled.
    pub fn set_capabilities(self: *Client, advertised: [5]bool) void {
        self.capabilities.advertised = advertised;
        self.capabilities_known = true;
        std.debug.assert(self.capabilities_known);
    }

    pub fn document_version(self: *const Client, uri: []const u8) ?i32 {
        for (self.documents) |document| if (document.active and std.mem.eql(u8, document.uri[0..document.uri_len], uri)) return document.version;
        return null;
    }

    pub fn has_document_version(self: *const Client, version: i32) bool {
        for (self.documents) |document| if (document.active and document.version == version) return true;
        return false;
    }

    /// Discards replies for changed snapshots before UI publication.
    pub fn accept_result(self: *Client, result: Result) Error!?Result {
        if (!self.running) return error.NotRunning;
        try self.pending.accept(result.request);
        const document = self.find(result.document_uri) orelse return null;
        if (!document.active or document.version != result.document_version) return null;
        std.debug.assert(result.json.len > 0);
        return result;
    }

    /// Caller owning child process must send shutdown/exit, close stdin, then kill only that child after grace.
    pub fn revoke(self: *Client, identity: Identity) Error!void {
        if (self.identity == null or !self.identity.?.eql(identity)) return error.TrustDenied;
        self.pending.invalidate();
        self.identity = null;
        self.running = false;
        std.debug.assert(!self.running);
    }

    fn find(self: *Client, uri: []const u8) ?*StoredDocument {
        for (&self.documents) |*document| if (document.active and std.mem.eql(u8, document.uri[0..document.uri_len], uri)) return document;
        return null;
    }

    fn find_or_free(self: *Client, uri: []const u8) ?*StoredDocument {
        if (self.find(uri)) |document| return document;
        for (&self.documents) |*document| if (!document.active) return document;
        return null;
    }
};

fn workspace_identity(workspace: []const u8, root_uri: []const u8) Fingerprint {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("warkocz:lsp:workspace-root-uri:v1");
    for ([_][]const u8{ workspace, root_uri }) |field| {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, field.len, .little);
        hasher.update(&length);
        hasher.update(field);
    }
    var result: Fingerprint = undefined;
    hasher.final(&result);
    return result;
}

pub fn digest(bytes: []const u8) Fingerprint {
    var result: Fingerprint = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    std.debug.assert(result.len == std.crypto.hash.sha2.Sha256.digest_length);
    return result;
}

test "initialized encoding cannot publish capability before write commit" {
    var state: Client = undefined;
    state.init();
    state.running = true;
    var output: [128]u8 = undefined;
    _ = try state.initialized(&output);
    try std.testing.expect(!state.session.initialized and !state.capabilities_known);
    try state.commit_initialized(.{ true, false, false, false, false });
    try std.testing.expect(state.session.initialized and state.capabilities_known);
    try std.testing.expect(state.capabilities.supports(.hover));
}

test "root URI changes require fresh consent" {
    const windows_target = @import("builtin").os.tag == .windows;
    const executable = if (windows_target) "C:/tools/lsp.exe" else "/tools/lsp";
    const workspace = if (windows_target) "C:/work" else "/work";
    const argv = [_][]const u8{executable};
    const server = Server{ .executable = executable, .argv = &argv, .workspace = workspace, .root_uri = "file:///C:/work", .config_bytes = "{}" };
    const changed_root_uri_server = Server{ .executable = executable, .argv = &argv, .workspace = workspace, .root_uri = "file:///C:/other-work", .config_bytes = "{}" };
    const executable_bytes = "server-v1";
    const identity = server.identity(executable_bytes);
    const changed_identity = changed_root_uri_server.identity(executable_bytes);
    try std.testing.expect(!identity.eql(changed_identity));

    var grants: [1]Identity = undefined;
    var trust = TrustStore{ .grants = &grants };
    try trust.grant(identity);
    try std.testing.expect(trust.allows(identity));
    try std.testing.expect(!trust.allows(changed_identity));

    var changed_client: Client = undefined;
    changed_client.init();
    try std.testing.expectError(error.ConsentRequired, changed_client.begin(changed_root_uri_server, executable_bytes, &trust));
    try std.testing.expect(!changed_client.running);
    try std.testing.expect(trust.count == 1 and trust.grants[0].eql(identity));

    var original_client: Client = undefined;
    original_client.init();
    _ = try original_client.begin(server, executable_bytes, &trust);
    try std.testing.expect(original_client.running);
}

test "exact trust gates explicit server and immutable snapshots" {
    const windows_target = @import("builtin").os.tag == .windows;
    const executable = if (windows_target) "C:/tools/lsp.exe" else "/tools/lsp";
    const workspace = if (windows_target) "C:/work" else "/work";
    const argv = [_][]const u8{executable};
    const server = Server{ .executable = executable, .argv = &argv, .workspace = workspace, .root_uri = "file:///C:/work", .config_bytes = "{}" };
    var grants: [1]Identity = undefined;
    var trust = TrustStore{ .grants = &grants };
    const identity = server.identity("server-v1");
    const changed_argv = [_][]const u8{ executable, "--changed" };
    const changed_server = Server{ .executable = executable, .argv = &changed_argv, .workspace = workspace, .root_uri = "file:///C:/work", .config_bytes = "{}" };
    try std.testing.expect(!identity.eql(changed_server.identity("server-v1")));
    try trust.grant(identity);
    var client: Client = undefined;
    client.init();
    try std.testing.expectError(error.ConsentRequired, client.begin_observed(server, digest("server-v2"), &trust));
    try std.testing.expectError(error.ConsentRequired, client.begin(server, "server-v2", &trust));
    _ = try client.begin(server, "server-v1", &trust);
    var output: [1024]u8 = undefined;
    _ = try client.initialize(server.root_uri, &output);
    _ = try client.initialized(&output);
    try client.commit_initialized(.{ true, false, false, false, false });
    _ = try client.open(.{ .uri = "file:///C:/work/a.zig", .language_id = "zig", .version = 1, .text = "const x = 1;" }, &output);
    _ = try client.change("file:///C:/work/a.zig", 2, "const x = 2;", &output);
    const request_json = try client.request(.hover, "file:///C:/work/a.zig", .{ .line = 0, .character = 0 }, &output);
    try std.testing.expect(std.mem.indexOf(u8, request_json, "textDocument/hover") != null);
    const key = client.pending.slots[1].?;
    try std.testing.expect((try client.accept_result(.{ .capability = .hover, .document_uri = "file:///C:/work/a.zig", .document_version = 1, .request = key, .json = "null" })) == null);
    try client.revoke(identity);
    try std.testing.expectError(error.NotRunning, client.request(.hover, "file:///C:/work/a.zig", .{ .line = 0, .character = 0 }, &output));
}
