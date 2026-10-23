//! Hosted smoke test for the vendored FreeType subset: initialize the
//! library, verify the pinned version, and tear it down.

const std = @import("std");

extern "c" fn FT_Init_FreeType(library: *?*anyopaque) c_int;
extern "c" fn FT_Done_FreeType(library: ?*anyopaque) c_int;
extern "c" fn FT_Library_Version(library: ?*anyopaque, major: *c_int, minor: *c_int, patch: *c_int) void;
extern "c" fn FT_Error_String(error_code: c_int) [*:0]const u8;

test "vendored freetype initializes and reports the pinned version" {
    var library: ?*anyopaque = null;
    const init_error = FT_Init_FreeType(&library);
    if (init_error != 0) {
        std.debug.print("FT_Init_FreeType error {d}: {s}\n", .{ init_error, FT_Error_String(init_error) });
        return error.InitFailed;
    }
    defer _ = FT_Done_FreeType(library);
    try std.testing.expect(library != null);
    var major: c_int = 0;
    var minor: c_int = 0;
    var patch: c_int = 0;
    FT_Library_Version(library, &major, &minor, &patch);
    try std.testing.expectEqual(@as(c_int, 2), major);
    try std.testing.expectEqual(@as(c_int, 14), minor);
    try std.testing.expectEqual(@as(c_int, 1), patch);
}
