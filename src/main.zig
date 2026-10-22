const std = @import("std");
const builtin = @import("builtin");
const invocation = @import("invocation.zig");
const native = @import("ui/native.zig");
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
    switch (request) {
        .bootstrap, .diff, .merge, .repo => return native.run(init, request),
        .help, .version => {},
    }
    const message = switch (request) {
        .help => invocation.usage ++ "\n\nNative graphical diff/merge uses explicit paths. repo performs bounded installed-Git metadata/history inspection through native argv only; worktree status is not scanned until separately reviewed and confirmed. Save publishes only a new output file; replacement and Git integration are not implemented. Exit 0: information or explicitly completed durable new-file output. Exit 1: invalid invocation or incomplete resolution.\n",
        .version => "warkocz " ++ build_options.version ++ " (development native first slice)\n",
        else => unreachable,
    };
    std.debug.assert(message.len > 0);
    var output_memory: [256]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &output_memory);
    try output.interface.writeAll(message);
    try output.interface.flush();
}
