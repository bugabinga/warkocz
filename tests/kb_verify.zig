//! Build gate for the vendored kb header: verifies the patch set still applies
//! and writes the patched header plus a C smoke file into its output directory.
//! Any drift exits nonzero with the targeted update message.

const std = @import("std");
const kb_patches = @import("kb_patches");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutable;
    const output_directory = args.next() orelse return error.MissingOutputDirectory;

    var failure = kb_patches.Failure{};
    const patched = kb_patches.apply(init.gpa, kb_patches.vendored_header, &kb_patches.patches, kb_patches.patched_sha256, &failure) catch {
        const message = kb_patches.helpMessage(init.gpa, failure, kb_patches.patched_sha256) catch "kb patching failed";
        std.Io.File.stderr().writeStreamingAll(init.io, message) catch {};
        std.process.exit(1);
    };
    defer init.gpa.free(patched);

    const header_path = join(init.gpa, output_directory, "kb_text_shape.h");
    defer init.gpa.free(header_path);
    const smoke_path = join(init.gpa, output_directory, "kb_smoke.c");
    defer init.gpa.free(smoke_path);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = header_path, .data = patched });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = smoke_path, .data = "#include \"kb_text_shape.h\"\n" });
}

fn join(allocator: std.mem.Allocator, directory: []const u8, name: []const u8) []const u8 {
    return std.fs.path.join(allocator, &.{ directory, name }) catch @panic("OOM");
}
