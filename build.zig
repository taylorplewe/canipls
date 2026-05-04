const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lsp_kit = b.dependency("lsp_kit", .{});

    const tree_sitter = b.dependency("tree_sitter", .{ .target = target, .optimize = optimize });
    const tree_sitter_html = b.dependency("tree_sitter_html", .{ .target = target, .optimize = optimize });
    const tree_sitter_css = b.dependency("tree_sitter_css", .{ .target = target, .optimize = optimize });
    const tree_sitter_javascript = b.dependency("tree_sitter_javascript", .{ .target = target, .optimize = optimize });
    const tree_sitter_svelte = b.dependency("tree_sitter_svelte", .{ .target = target, .optimize = optimize });
    const tree_sitter_astro = b.dependency("tree_sitter_astro", .{ .target = target, .optimize = optimize });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lsp", .module = lsp_kit.module("lsp") },
            .{ .name = "tree-sitter", .module = tree_sitter.module("tree_sitter") },
        },
    });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_html.path("src/scanner.c") });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_html.path("src/parser.c") });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_css.path("src/scanner.c") });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_css.path("src/parser.c") });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_javascript.path("src/scanner.c") });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_javascript.path("src/parser.c") });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_svelte.path("src/scanner.c") });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_svelte.path("src/parser.c") });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_astro.path("src/scanner.c") });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_astro.path("src/parser.c") });

    const exe = b.addExecutable(.{
        .name = "caniuse-ls",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);
}
