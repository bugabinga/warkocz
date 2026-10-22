const std = @import("std");

// Exercise the actual executable, not a duplicate of its implementation.
pub fn add(b: *std.Build, executable: *std.Build.Step.Compile, tests: *std.Build.Step) void {
    const unsupported = b.addRunArtifact(executable);
    unsupported.addArgs(&.{ "--merge", "not-a-repository" });
    unsupported.expectExitCode(1);
    unsupported.expectStdOutEqual("");
    unsupported.expectStdErrMatch("UnknownArgument");
    tests.dependOn(&unsupported.step);

    const invalid_repo = b.addRunArtifact(executable);
    invalid_repo.addArgs(&.{ "repo", "--path", "repo", "--git", "git", "--history-limit", "0" });
    invalid_repo.expectExitCode(1);
    invalid_repo.expectStdOutEqual("");
    invalid_repo.expectStdErrMatch("InvalidHistoryLimit");
    tests.dependOn(&invalid_repo.step);

    const help = b.addRunArtifact(executable);
    help.addArg("--help");
    help.expectStdOutMatch("Native graphical diff/merge uses explicit paths");
    help.expectStdErrEqual("");
    help.expectExitCode(0);
    tests.dependOn(&help.step);

    const version = b.addRunArtifact(executable);
    version.addArg("--version");
    version.expectStdOutEqual("warkocz " ++ @import("../build.zig.zon").version ++ " (development native first slice)\n");
    version.expectStdErrEqual("");
    version.expectExitCode(0);
    tests.dependOn(&version.step);

    const long_label = b.allocator.alloc(u8, 5000) catch @panic("test argument allocation failed");
    @memset(long_label, 'x');
    const capacity = b.addRunArtifact(executable);
    capacity.addArgs(&.{ "diff", "--left", "left", "--right", "right", "--output", "result", "--left-label", long_label, "--wait", "--wait" });
    capacity.expectExitCode(1);
    capacity.expectStdOutEqual("");
    const windows = executable.root_module.resolved_target.?.result.os.tag == .windows;
    capacity.expectStdErrMatch(if (windows) "ArgumentCapacityExceeded" else "DuplicateOption");
    tests.dependOn(&capacity.step);

    const argument_count = b.addRunArtifact(executable);
    for (0..300) |_| argument_count.addArg("--wait");
    argument_count.expectExitCode(1);
    argument_count.expectStdOutEqual("");
    argument_count.expectStdErrMatch("ArgumentCapacityExceeded");
    argument_count.expectStdErrMatch("no files opened");
    tests.dependOn(&argument_count.step);
}
