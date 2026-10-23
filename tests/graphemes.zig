//! Hosted tests for the kb-backed grapheme map (linked against the kb lib).

const std = @import("std");
const graphemes = @import("graphemes");

test "boundaries match known cluster sets" {
    inline for (.{
        .{ .text = "", .expected = &[_]u32{0} },
        .{ .text = "a\u{266a}", .expected = &[_]u32{ 0, 1, 4 } },
    }) |case| {
        var boundaries: [case.text.len + 1]u32 = undefined;
        var utf16: [case.text.len + 1]u32 = undefined;
        var scratch: [case.text.len + 1]u32 = undefined;
        const map = try graphemes.build(case.text, &boundaries, &utf16, &scratch);
        try std.testing.expectEqualSlices(u32, case.expected, map.boundaries);
    }
}

test "family ZWJ emoji is one cluster through the patched kb" {
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
    var boundaries: [family.len + 1]u32 = undefined;
    var utf16: [family.len + 1]u32 = undefined;
    var scratch: [family.len + 1]u32 = undefined;
    const map = try graphemes.build(family, &boundaries, &utf16, &scratch);
    try std.testing.expectEqual(@as(u32, 1), map.clusterCount());
    try std.testing.expectEqual(@as(u32, family.len), map.boundaries[1]);
    try std.testing.expectEqual(@as(u32, 11), map.utf16[1]);
}

test "caret walk visits every boundary exactly" {
    const text = "Zażółć gęślą jaźń";
    var boundaries: [text.len + 1]u32 = undefined;
    var utf16: [text.len + 1]u32 = undefined;
    var scratch: [text.len + 1]u32 = undefined;
    const map = try graphemes.build(text, &boundaries, &utf16, &scratch);
    var offset: u32 = 0;
    var steps: u32 = 0;
    while (map.nextBoundary(offset)) |next| {
        try std.testing.expect(next > offset);
        offset = next;
        steps += 1;
    }
    try std.testing.expectEqual(map.clusterCount(), steps);
    try std.testing.expectEqual(@as(u32, text.len), offset);
}

test "invalid UTF-8 is rejected before kb sees it" {
    const invalid = [_][]const u8{
        &.{0xc3},
        &.{ 0xc0, 0xaf },
        &.{ 0xed, 0xa0, 0x80 },
        &.{ 0xf4, 0x90, 0x80, 0x80 },
    };
    for (invalid) |sequence| {
        var boundaries: [8]u32 = undefined;
        var utf16: [8]u32 = undefined;
        var scratch: [8]u32 = undefined;
        try std.testing.expectError(error.InvalidUtf8, graphemes.build(sequence, &boundaries, &utf16, &scratch));
    }
}
