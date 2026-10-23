//! Developer tool reporting which kb patches still match the vendored
//! upstream header. Used when re-evaluating patches after an upstream update.

const std = @import("std");
const kb_patches = @import("kb_patches");

pub fn main(init: std.process.Init) !void {
    const upstream = kb_patches.vendored_header;
    const stdout = std.Io.File.stdout();
    var matched: usize = 0;
    for (kb_patches.patches, 0..) |patch, index| {
        const occurrences = countOccurrences(upstream, patch.old);
        const state: []const u8 = switch (occurrences) {
            0 => "MISSING (upstream likely fixed; delete or port this patch)",
            1 => "matched",
            else => "AMBIGUOUS (investigate)",
        };
        if (occurrences == 1) matched += 1;
        const line = try std.fmt.allocPrint(init.gpa, "{d:>2} {s}: {s} -- {s}\n", .{ index, patch.id, state, patch.summary });
        defer init.gpa.free(line);
        try stdout.writeStreamingAll(init.io, line);
    }
    const summary = try std.fmt.allocPrint(init.gpa, "{d}/{d} patches apply cleanly against upstream {s} ({s})\n", .{ matched, kb_patches.patches.len, kb_patches.upstream_version, kb_patches.upstream_commit });
    defer init.gpa.free(summary);
    try stdout.writeStreamingAll(init.io, summary);
    if (matched == kb_patches.patches.len) {
        try stdout.writeStreamingAll(init.io, "all patches still apply; run 'zig build test' to verify the patched golden hash\n");
    }
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, cursor, needle)) |position| {
        count += 1;
        cursor = position + needle.len;
    }
    return count;
}
