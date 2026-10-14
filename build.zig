const std = @import("std");
const cli_tests = @import("tests/cli.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.Optimize, "optimize", "debug or safe (ReleaseSafe)") orelse .safe;
    const executable = b.addExecutable(.{
        .name = "warkocz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(executable);

    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("run", "Run the bootstrap (not the GUI)").dependOn(&run.step);

    const tests = b.step("test", "Verify bootstrap output and unsupported invocation");
    cli_tests.add(b, executable, tests);

    const format_paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("src"), b.path("tests") };
    const format = b.addFmt(.{ .paths = format_paths, .check = false });
    b.step("fmt", "Format Zig sources").dependOn(&format.step);
    const format_check = b.addFmt(.{ .paths = format_paths, .check = true });
    const check = b.step("check", "Check formatting and bootstrap behavior");
    check.dependOn(&format_check.step);
    check.dependOn(tests);
}
