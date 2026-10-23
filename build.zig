const std = @import("std");
const cli_tests = @import("tests/cli.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.Optimize, "optimize", "debug or safe (ReleaseSafe)") orelse .safe;
    const sdl3 = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
        .linkage = .static,
    });
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
    executable.root_module.addImport("sdl3", sdl3.module("sdl3"));
    const freetype = add_freetype_library(b, target, optimize);
    const freetype_module = add_freetype_module(b, target, optimize, freetype);
    executable.root_module.linkLibrary(freetype);
    executable.root_module.addImport("freetype_c", freetype_module);
    b.installArtifact(executable);
    b.installFile("THIRD_PARTY.md", "share/doc/warkocz/THIRD_PARTY.md");

    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("run", "Run the native graphical client").dependOn(&run.step);

    const tests = b.step("test", "Verify bounded core and executable contracts");
    cli_tests.add(b, executable, tests);
    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const core_test_run = b.addRunArtifact(core_tests);
    tests.dependOn(&core_test_run.step);
    const native_output_test_run = b.addRunArtifact(core_tests);
    native_output_test_run.setEnvironmentVariable("WARKOCZ_NATIVE_E2E", "1");
    native_output_test_run.has_side_effects = true;
    const test_native_output = b.step("test-output-native", "Opt-in native durable new-file publication test");
    test_native_output.dependOn(&native_output_test_run.step);
    const native_recovery_test_run = b.addRunArtifact(core_tests);
    native_recovery_test_run.setEnvironmentVariable("WARKOCZ_NATIVE_E2E", "1");
    native_recovery_test_run.has_side_effects = true;
    const test_native_recovery = b.step("test-recovery-native", "Opt-in Windows DPAPI encrypted recovery fixture");
    test_native_recovery.dependOn(&native_recovery_test_run.step);
    const native_git_test_run = b.addRunArtifact(core_tests);
    native_git_test_run.has_side_effects = true;
    const test_git_native = b.step("test-git-native", "Opt-in installed-Git inspection fixture under OS temp root");
    test_git_native.dependOn(&native_git_test_run.step);
    const lsp_server = add_lsp_test_server(b, target, optimize);
    const native_tests = add_native_tests(b, target, optimize, sdl3, freetype, freetype_module, false, lsp_server);
    tests.dependOn(&b.addRunArtifact(native_tests).step);
    add_lsp_native_test(b, target, optimize, lsp_server);
    add_git_process_native_test(b, target, optimize);
    const gpu_tests = add_native_tests(b, target, optimize, sdl3, freetype, freetype_module, true, lsp_server);
    const test_gpu = b.step("test-gpu", "Verify bounded SDL GPU rendering and injected-event routing");
    const gpu_test_run = b.addRunArtifact(gpu_tests);
    gpu_test_run.has_side_effects = true;
    test_gpu.dependOn(&gpu_test_run.step);

    const format_paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("src"), b.path("tests"), b.path("third_party") };
    const format = b.addFmt(.{ .paths = format_paths, .check = false });
    b.step("fmt", "Format Zig sources").dependOn(&format.step);
    const format_check = b.addFmt(.{ .paths = format_paths, .check = true });
    const check = b.step("check", "Check formatting, bounded core, and executable behavior");
    check.dependOn(&format_check.step);
    check.dependOn(tests);
    add_kb_checks(b, target, optimize, freetype, tests, check);
}

/// Wires kb patch verification: the gate executable applies the vendored
/// patch table, writes the patched header plus a C smoke file, and a compile
/// step proves the patched header still compiles. Tests cover pin, golden
/// hash, markers, and failure diagnostics.
fn add_kb_checks(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    freetype: *std.Build.Step.Compile,
    tests_step: *std.Build.Step,
    check_step: *std.Build.Step,
) void {
    const kb_module = b.createModule(.{ .root_source_file = b.path("third_party/kb/patches.zig") });
    const verify = b.addExecutable(.{
        .name = "warkocz-kb-verify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/kb_verify.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    verify.root_module.addImport("kb_patches", kb_module);
    const verify_run = b.addRunArtifact(verify);
    const patched_directory = verify_run.addOutputDirectoryArg("kb");

    const kb = b.addLibrary(.{
        .linkage = .static,
        .name = "kb",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    kb.root_module.addIncludePath(patched_directory);
    kb.root_module.addCSourceFiles(.{
        .root = b.path("src/ui"),
        .files = &.{"kb_impl.c"},
        .flags = &.{ "-std=c17", "-DKB_TEXT_SHAPE_IMPLEMENTATION" },
    });
    kb.step.dependOn(&verify_run.step);
    add_grapheme_tests(b, target, optimize, kb, tests_step);

    const smoke = b.addSystemCommand(&.{ b.graph.zig_exe, "cc", "-c", "-std=c17", "-DKB_TEXT_SHAPE_IMPLEMENTATION", "-I" });
    smoke.setName("kb-c-smoke");
    smoke.addDirectoryArg(patched_directory);
    smoke.addArg("-o");
    _ = smoke.addOutputFileArg("kb_smoke.o");
    smoke.addFileArg(patched_directory.path(b, "kb_smoke.c"));
    check_step.dependOn(&smoke.step);
    b.step("kb-check", "Apply kb patches and compile-check the patched C header").dependOn(&smoke.step);

    const status = b.addExecutable(.{
        .name = "warkocz-kb-patch-status",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/kb_patch_status.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    status.root_module.addImport("kb_patches", kb_module);
    b.step("kb-patch-status", "Report which kb patches still match the vendored upstream header").dependOn(&b.addRunArtifact(status).step);

    const kb_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/kb_patches.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    kb_tests.root_module.addImport("kb_patches", kb_module);
    tests_step.dependOn(&b.addRunArtifact(kb_tests).step);
    add_freetype_checks(b, target, optimize, freetype, tests_step, check_step);
}

/// Hosted tests for the kb-backed grapheme map over the patched kb library.
fn add_grapheme_tests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    kb: *std.Build.Step.Compile,
    tests_step: *std.Build.Step,
) void {
    const grapheme_module = b.createModule(.{
        .root_source_file = b.path("src/ui/graphemes.zig"),
        .link_libc = true,
    });
    const grapheme_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/graphemes.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    grapheme_tests.root_module.addImport("graphemes", grapheme_module);
    grapheme_tests.root_module.linkLibrary(kb);
    tests_step.dependOn(&b.addRunArtifact(grapheme_tests).step);
}

/// Compiles the vendored FreeType subset into a static library with the
/// minimal vendored configuration. Reused by the app, native tests, and the
/// ft-check gate.
fn add_freetype_library(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
) *std.Build.Step.Compile {
    const freetype = b.addLibrary(.{
        .linkage = .static,
        .name = "freetype",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    freetype.root_module.addIncludePath(b.path("third_party/freetype/include"));
    freetype.root_module.addIncludePath(b.path("third_party/freetype"));
    freetype.root_module.addCSourceFiles(.{
        .root = b.path("third_party/freetype"),
        .files = &.{
            "src/base/ftbase.c",
            "src/base/ftbitmap.c",
            "src/base/ftinit.c",
            "src/base/ftsystem.c",
            "src/base/ftdebug.c",
            "src/sfnt/sfnt.c",
            "src/truetype/truetype.c",
            "src/smooth/smooth.c",
        },
        .flags = &.{
            "-std=c17",
            "-DFT2_BUILD_LIBRARY",
            "-DFT_CONFIG_MODULES_H=<config/ftmodule.h>",
            "-DFT_CONFIG_OPTIONS_H=<config/ftoption.h>",
        },
    });
    return freetype;
}

/// Translates the vendored public FreeType headers so Zig code can use the
/// real struct layouts on every platform.
fn add_freetype_module(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    freetype: *std.Build.Step.Compile,
) *std.Build.Module {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/ui/freetype_shim.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.defineCMacro("FT2_BUILD_LIBRARY", "1");
    translate.addIncludePath(b.path("third_party/freetype/include"));
    const module = translate.addModule("freetype_c");
    module.linkLibrary(freetype);
    return module;
}

/// Gates the vendored FreeType subset behind a version smoke test.
fn add_freetype_checks(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    freetype: *std.Build.Step.Compile,
    tests_step: *std.Build.Step,
    check_step: *std.Build.Step,
) void {
    check_step.dependOn(&freetype.step);
    b.step("ft-check", "Compile the vendored FreeType subset").dependOn(&freetype.step);

    const smoke = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/freetype_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    smoke.root_module.linkLibrary(freetype);
    tests_step.dependOn(&b.addRunArtifact(smoke).step);
}

fn add_lsp_test_server(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) *std.Build.Step.Compile {
    const protocol_module = b.createModule(.{
        .root_source_file = b.path("src/lsp/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const server_module = b.createModule(.{
        .root_source_file = b.path("tests/lsp_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_module.addImport("protocol", protocol_module);
    return b.addExecutable(.{ .name = "warkocz-lsp-test-server", .root_module = server_module });
}

fn add_lsp_native_test(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, server: *std.Build.Step.Compile) void {
    const runner = b.addExecutable(.{
        .name = "warkocz-lsp-native-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lsp_native_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run = b.addRunArtifact(runner);
    run.addArtifactArg2(server, .{ .make_absolute = true });
    run.has_side_effects = true;
    const test_lsp_native = b.step("test-lsp-native", "Verify native LSP process pipes against deterministic fake server");
    test_lsp_native.dependOn(&run.step);
}

fn add_git_process_native_test(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) void {
    const fixture = b.addExecutable(.{
        .name = "warkocz-git-process-child",
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/git_process_child.zig"), .target = target, .optimize = optimize }),
    });
    const runner = b.addExecutable(.{
        .name = "warkocz-git-process-native-test",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/git_process_native_runner.zig"), .target = target, .optimize = optimize }),
    });
    const run = b.addRunArtifact(runner);
    run.addArtifactArg2(fixture, .{ .make_absolute = true });
    run.has_side_effects = true;
    b.step("test-git-process-native", "Verify Windows Git subprocess deadlines and owned process cleanup").dependOn(&run.step);
}

fn add_native_tests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    sdl3: *std.Build.Dependency,
    freetype: *std.Build.Step.Compile,
    freetype_module: *std.Build.Module,
    gpu: bool,
    lsp_server: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const native_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/native_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const options = b.addOptions();
    options.addOption(bool, "gpu", gpu);
    options.addOptionPath("lsp_fixture_executable", lsp_server.getEmittedBin());
    native_tests.root_module.addOptions("native_test_options", options);
    native_tests.root_module.addImport("sdl3", sdl3.module("sdl3"));
    native_tests.root_module.linkLibrary(freetype);
    native_tests.root_module.addImport("freetype_c", freetype_module);
    return native_tests;
}
