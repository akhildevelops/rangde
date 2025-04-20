const std = @import("std");

pub fn build(b: *std.Build) void {
    // Build Parameters
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const libcoro = b.dependency("zigcoro", .{ .target = target, .optimize = optimize }).module("libcoro");
    const libxev = b.dependency("libxev", .{}).module("xev");

    // Library
    const librangde_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    librangde_module.addImport("xev", libxev);
    librangde_module.addImport("coro", libcoro);

    // Application
    const exerangde_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    exerangde_module.addImport("rangde", librangde_module);

    // Create executables
    const exe = b.addExecutable(.{ .name = "rangde", .root_module = exerangde_module });
    const install_step = b.addInstallArtifact(exe, .{});

    // Run executable
    const exe_step_run = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the executable");
    run_step.dependOn(&install_step.step);
    run_step.dependOn(&exe_step_run.step);

    // Tests
    const test_module = b.createModule(.{ .root_source_file = b.path("tests/test_coro.zig"), .target = target, .optimize = optimize });
    test_module.addImport("coro", libcoro);
    test_module.addImport("xev", libxev);

    const tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
