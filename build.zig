const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lsp_kit = b.dependency("lsp_kit", .{});

    const exe = b.addExecutable(.{
        .name = "caniuse-ls",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lsp", .module = lsp_kit.module("lsp") },
            },
        }),
    });

    b.installArtifact(exe);
}
