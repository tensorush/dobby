const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

    // OS restrictions
    switch (builtin.object_format) {
        .elf => {},
        else => @compileError("Only ELF is supported at the moment"),
    }

    // CPU restrictions
    switch (builtin.cpu.arch) {
        .x86_64, .aarch64 => {},
        else => @compileError("Only x86_64 and aarch64 are supported at the moment"),
    }

    // Dependencies
    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });
    const clap_mod = clap_dep.module("clap");

    // Executable
    const exe_step = b.step("exe", "Run executable");

    const exe = b.addExecutable(.{
        .name = "dobby",
        .target = target,
        .link_libc = true,
        .version = version,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    exe.root_module.addImport("clap", clap_mod);

    const exe_run = b.addRunArtifact(exe);
    if (b.args) |args| {
        exe_run.addArgs(args);
    }
    exe_step.dependOn(&exe_run.step);
    b.default_step.dependOn(exe_step);

    // Example suite
    const examples_step = b.step("example", "Install example suite");

    inline for (EXAMPLE_NAMES) |EXAMPLE_NAME| {
        const example = b.addExecutable(.{
            .name = EXAMPLE_NAME,
            .target = target,
            .version = version,
            .optimize = optimize,
            .root_source_file = b.path(EXAMPLES_DIR ++ EXAMPLE_NAME ++ ".zig"),
        });

        const example_install = b.addInstallArtifact(example, .{});
        examples_step.dependOn(&example_install.step);
    }

    b.default_step.dependOn(examples_step);

    // Formatting checks
    const fmt_step = b.step("fmt", "Run formatting checks");

    const fmt = b.addFmt(.{
        .paths = &.{
            "src/",
            "build.zig",
            EXAMPLES_DIR,
        },
        .check = true,
    });
    fmt_step.dependOn(&fmt.step);
    b.default_step.dependOn(fmt_step);
}

const EXAMPLES_DIR = "examples/";

const EXAMPLE_NAMES = &.{
    "basic",
};
