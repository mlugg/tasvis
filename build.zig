pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zpng = b.dependency("zpng", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "tasvis",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zpng", zpng.module("zpng"));
    exe.linkSystemLibrary("avformat");
    exe.linkSystemLibrary("avcodec");
    exe.linkSystemLibrary("avutil");
    exe.linkSystemLibrary("swscale");
    exe.linkLibC();

    b.installArtifact(exe);
}

const std = @import("std");
