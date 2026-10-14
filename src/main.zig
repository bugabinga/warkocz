const std = @import("std");
const builtin = @import("builtin");
const invocation = @import("invocation.zig");
const build_options = @import("build_options");

comptime {
    if (builtin.mode != .debug and builtin.mode != .safe) {
        @compileError("warkocz requires Debug or ReleaseSafe");
    }
}

pub fn main(init: std.process.Init) !void {
    // Bootstrap-only argv capacity, not an approved product resource limit.
    var argument_memory: [4096]u8 = undefined;
    var arguments_allocator = std.heap.FixedBufferAllocator.init(&argument_memory);
    const arguments = init.minimal.args.toSlice(arguments_allocator.allocator()) catch |err| {
        if (err != error.OutOfMemory) return err;
        var error_memory: [256]u8 = undefined;
        var error_output = std.Io.File.Writer.init(.stderr(), init.io, &error_memory);
        try error_output.interface.writeAll("Argument conversion exceeds the bootstrap's 4096-byte arena, including metadata. Reduce argument count or path/label lengths; no files opened.\n");
        try error_output.interface.flush();
        return error.ArgumentCapacityExceeded;
    };
    std.debug.assert(arguments.len >= 1);
    const request = try invocation.parse(arguments[1..]);
    const message = switch (request) {
        .bootstrap => "warkocz: bootstrap only; graphical client not implemented.\n",
        .help => invocation.usage ++ "\n\nDiff/merge execution unavailable; requests fail without opening files.\nExit 0: information only. Exit 1: invalid or unavailable operation.\n",
        .version => "warkocz " ++ build_options.version ++ " (development; not a usable Git client)\n",
        .diff, .merge => return error.FeatureUnavailable,
    };
    std.debug.assert(message.len > 0);
    var output_memory: [256]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &output_memory);
    try output.interface.writeAll(message);
    try output.interface.flush();
}
