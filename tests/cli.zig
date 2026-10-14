const std = @import("std");

// Exercise the actual executable, not a duplicate of its implementation.
pub fn add(b: *std.Build, executable: *std.Build.Step.Compile, tests: *std.Build.Step) void {
    const bootstrap = b.addRunArtifact(executable);
    bootstrap.expectStdOutEqual("warkocz: bootstrap only; graphical client not implemented.\n");
    bootstrap.expectStdErrEqual("");
    tests.dependOn(&bootstrap.step);

    const unsupported = b.addRunArtifact(executable);
    unsupported.addArgs(&.{ "--merge", "not-a-repository" });
    unsupported.expectExitCode(1);
    unsupported.expectStdOutEqual("");
    unsupported.expectStdErrMatch("UnsupportedInvocation");
    tests.dependOn(&unsupported.step);
}
