//! Hosted tests for the vendored kb header pin and build-time patch engine.

const std = @import("std");
const kb_patches = @import("kb_patches");

test "vendored kb header matches the pinned upstream sha256" {
    try std.testing.expect(kb_patches.pinMatches(kb_patches.vendored_header));
}

test "patch application reproduces the pinned patched header" {
    const allocator = std.testing.allocator;
    const patched = try kb_patches.apply(allocator, kb_patches.vendored_header, &kb_patches.patches, kb_patches.patched_sha256, null);
    defer allocator.free(patched);
    try std.testing.expect(kb_patches.patchedMatches(patched));
}

test "patched header carries provenance banner and fix markers" {
    const allocator = std.testing.allocator;
    const patched = try kb_patches.apply(allocator, kb_patches.vendored_header, &kb_patches.patches, kb_patches.patched_sha256, null);
    defer allocator.free(patched);
    for ([_][]const u8{ "Locally patched for warkocz", "GB11 EP Extend* ZWJ x EP", "never write through the sentinel", "never publish a partially shaped run" }) |marker| {
        try std.testing.expect(std.mem.indexOf(u8, patched, marker) != null);
    }
}

test "missing patch context is diagnosed with the failing patch id" {
    const allocator = std.testing.allocator;
    const bytes = kb_patches.vendored_header;
    const missing = kb_patches.patches[0];
    const position = std.mem.indexOf(u8, bytes, missing.old).?;
    const synthetic = try std.mem.concat(allocator, u8, &.{ bytes[0..position], bytes[position + missing.old.len ..] });
    defer allocator.free(synthetic);
    var failure = kb_patches.Failure{};
    if (kb_patches.apply(allocator, synthetic, &kb_patches.patches, kb_patches.patched_sha256, &failure)) |patched| {
        allocator.free(patched);
        return error.ExpectedPatchFailure;
    } else |err| {
        try std.testing.expectEqual(error.PatchContextMissing, err);
        try std.testing.expectEqual(@as(?usize, 0), failure.patch_index);
        const message = try kb_patches.helpMessage(allocator, failure, kb_patches.patched_sha256);
        defer allocator.free(message);
        try std.testing.expect(std.mem.indexOf(u8, message, missing.id) != null);
        try std.testing.expect(std.mem.indexOf(u8, message, "Upstream kb was likely updated") != null);
        try std.testing.expect(std.mem.indexOf(u8, message, "third_party/kb/README.md") != null);
    }
}

test "ambiguous patch context is diagnosed with occurrence count" {
    const allocator = std.testing.allocator;
    const bytes = kb_patches.vendored_header;
    const duplicated = kb_patches.patches[1];
    const synthetic = try std.mem.concat(allocator, u8, &.{ bytes, "\n", duplicated.old });
    defer allocator.free(synthetic);
    var failure = kb_patches.Failure{};
    if (kb_patches.apply(allocator, synthetic, &kb_patches.patches, kb_patches.patched_sha256, &failure)) |patched| {
        allocator.free(patched);
        return error.ExpectedPatchFailure;
    } else |err| {
        try std.testing.expectEqual(error.PatchContextAmbiguous, err);
        try std.testing.expectEqual(@as(?usize, 1), failure.patch_index);
        try std.testing.expectEqual(@as(usize, 2), failure.occurrences);
    }
}

test "patched hash drift is detected" {
    const allocator = std.testing.allocator;
    const wrong = try allocator.alloc(u8, 64);
    defer allocator.free(wrong);
    @memset(wrong, '0');
    var failure = kb_patches.Failure{};
    if (kb_patches.apply(allocator, kb_patches.vendored_header, &kb_patches.patches, wrong, &failure)) |patched| {
        allocator.free(patched);
        return error.ExpectedPatchFailure;
    } else |err| {
        try std.testing.expectEqual(error.PatchedHashMismatch, err);
        const message = try kb_patches.helpMessage(allocator, failure, wrong);
        defer allocator.free(message);
        try std.testing.expect(std.mem.indexOf(u8, message, "patched_sha256") != null);
    }
}
