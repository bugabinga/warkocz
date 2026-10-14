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
    unsupported.expectStdErrMatch("UnknownArgument");
    tests.dependOn(&unsupported.step);

    const help = b.addRunArtifact(executable);
    help.addArg("--help");
    help.expectStdOutMatch("Diff/merge execution unavailable");
    help.expectStdErrEqual("");
    help.expectExitCode(0);
    tests.dependOn(&help.step);

    const version = b.addRunArtifact(executable);
    version.addArg("--version");
    version.expectStdOutEqual("warkocz " ++ @import("../build.zig.zon").version ++ " (development; not a usable Git client)\n");
    version.expectStdErrEqual("");
    version.expectExitCode(0);
    tests.dependOn(&version.step);

    const long_label = b.allocator.alloc(u8, 5000) catch @panic("test argument allocation failed");
    @memset(long_label, 'x');
    const capacity = b.addRunArtifact(executable);
    capacity.addArgs(&.{ "diff", "--left", "left", "--right", "right", "--output", "result", "--left-label", long_label });
    capacity.expectExitCode(1);
    capacity.expectStdOutEqual("");
    const windows = executable.root_module.resolved_target.?.result.os.tag == .windows;
    capacity.expectStdErrMatch(if (windows) "ArgumentCapacityExceeded" else "FeatureUnavailable");
    tests.dependOn(&capacity.step);

    const argument_count = b.addRunArtifact(executable);
    for (0..300) |_| argument_count.addArg("--wait");
    argument_count.expectExitCode(1);
    argument_count.expectStdOutEqual("");
    argument_count.expectStdErrMatch("ArgumentCapacityExceeded");
    argument_count.expectStdErrMatch("no files opened");
    tests.dependOn(&argument_count.step);

    const requests = [_][]const []const u8{
        &.{ "diff", "--left", "not-present-left", "--right", "not-present-right", "--output", "not-present-output", "--wait" },
        &.{ "merge", "--base", "not-present-base", "--left", "a path with spaces", "--right", "-leading-dash", "--output", "not-present-output", "--wait" },
    };
    for (requests) |arguments| {
        const unavailable = b.addRunArtifact(executable);
        unavailable.addArgs(arguments);
        unavailable.expectExitCode(1);
        unavailable.expectStdOutEqual("");
        unavailable.expectStdErrMatch("FeatureUnavailable");
        tests.dependOn(&unavailable.step);
    }
}
