const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.mode != .debug and builtin.mode != .safe) {
        @compileError("warkocz requires Debug or ReleaseSafe");
    }
}

pub fn main(init: std.process.Init) !void {
    // This executable cannot fulfill a diff/merge invocation yet.
    var argument_memory: [4096]u8 = undefined;
    var arguments_allocator = std.heap.FixedBufferAllocator.init(&argument_memory);
    const arguments = try init.minimal.args.toSlice(arguments_allocator.allocator());
    if (arguments.len != 1) return error.UnsupportedInvocation;

    var output_memory: [256]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &output_memory);
    try output.interface.writeAll("warkocz: bootstrap only; graphical client not implemented.\n");
    try output.interface.flush();
}
