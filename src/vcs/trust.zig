const std = @import("std");

pub const Fingerprint = [std.crypto.hash.sha2.Sha256.digest_length]u8;

/// Identity and config fingerprints are supplied by the repository opener.
/// A grant matches one exact repository identity, executable config state, and scope.
pub const Grant = struct {
    repository: Fingerprint,
    config: Fingerprint,
    scope: Scope,
};

/// Scope is operation-specific: a confirmation for staging cannot authorize a commit.
pub const Scope = enum {
    inspect,
    executable_config,
    worktree_status,
    stage,
    unstage,
    commit,
    branch_create,
    branch_rename,
    branch_delete,
    fetch,
    push,
};

pub const Store = struct {
    grants: []Grant,
    count: usize = 0,

    pub fn init(grants: []Grant) Store {
        std.debug.assert(grants.len > 0);
        return .{ .grants = grants };
    }

    pub fn grant(self: *Store, value: Grant) error{CapacityExceeded}!void {
        std.debug.assert(self.count <= self.grants.len);
        if (self.allows(value.repository, value.config, value.scope)) return;
        if (self.count == self.grants.len) return error.CapacityExceeded;
        self.grants[self.count] = value;
        self.count += 1;
        std.debug.assert(self.count <= self.grants.len);
    }

    pub fn allows(self: *const Store, repository: Fingerprint, config: Fingerprint, scope: Scope) bool {
        std.debug.assert(self.count <= self.grants.len);
        for (self.grants[0..self.count]) |value| {
            if (value.scope == scope and std.mem.eql(u8, &value.repository, &repository) and std.mem.eql(u8, &value.config, &config)) return true;
        }
        return false;
    }

    pub fn revoke(self: *Store, repository: Fingerprint, config: Fingerprint, scope: Scope) bool {
        std.debug.assert(self.count <= self.grants.len);
        for (self.grants[0..self.count], 0..) |value, index| {
            if (value.scope != scope or !std.mem.eql(u8, &value.repository, &repository) or !std.mem.eql(u8, &value.config, &config)) continue;
            self.count -= 1;
            self.grants[index] = self.grants[self.count];
            std.debug.assert(self.count < self.grants.len);
            return true;
        }
        return false;
    }
};

pub fn fingerprint(bytes: []const u8) Fingerprint {
    var result: Fingerprint = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    std.debug.assert(result.len == std.crypto.hash.sha2.Sha256.digest_length);
    return result;
}

test "grant is exact and revocable" {
    var storage: [2]Grant = undefined;
    var store = Store.init(&storage);
    const repository = fingerprint("repo-a");
    const config = fingerprint("config-a");
    try store.grant(.{ .repository = repository, .config = config, .scope = .inspect });
    try std.testing.expect(store.allows(repository, config, .inspect));
    try std.testing.expect(!store.allows(fingerprint("repo-b"), config, .inspect));
    try std.testing.expect(!store.allows(repository, fingerprint("config-b"), .inspect));
    try std.testing.expect(!store.allows(repository, config, .executable_config));
    try std.testing.expect(!store.allows(repository, config, .worktree_status));
    try std.testing.expect(!store.allows(repository, config, .stage));
    try std.testing.expect(!store.allows(repository, config, .commit));
    try std.testing.expect(!store.allows(repository, config, .fetch));
    try std.testing.expect(store.revoke(repository, config, .inspect));
    try std.testing.expect(!store.allows(repository, config, .inspect));
}
