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
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    executable.root_module.addOptions("build_options", build_options);
    b.installArtifact(executable);

    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("run", "Run the bootstrap (not the GUI)").dependOn(&run.step);

    const tests = b.step("test", "Verify bounded core and executable contracts");
    cli_tests.add(b, executable, tests);
    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.dependOn(&b.addRunArtifact(core_tests).step);

    const format_paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("src"), b.path("tests") };
    const format = b.addFmt(.{ .paths = format_paths, .check = false });
    b.step("fmt", "Format Zig sources").dependOn(&format.step);
    const format_check = b.addFmt(.{ .paths = format_paths, .check = true });
    const check = b.step("check", "Check formatting, bounded core, and executable behavior");
    check.dependOn(&format_check.step);
    check.dependOn(tests);
}
