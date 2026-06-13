const std = @import("std");

const version: std.SemanticVersion = std.SemanticVersion.parse(@import("build.zig.zon").version) catch .{ .major = 0, .minor = 0, .patch = 0 };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lsp_kit = b.dependency("lsp_kit", .{});

    const tree_sitter = b.dependency("tree_sitter", .{ .target = target, .optimize = optimize });
    const tree_sitter_html = b.dependency("tree_sitter_html", .{ .target = target, .optimize = optimize });
    const tree_sitter_css = b.dependency("tree_sitter_css", .{ .target = target, .optimize = optimize });
    const tree_sitter_javascript = b.dependency("tree_sitter_javascript", .{ .target = target, .optimize = optimize });
    const tree_sitter_php = b.dependency("tree_sitter_php", .{ .target = target, .optimize = optimize });
    const tree_sitter_svelte = b.dependency("tree_sitter_svelte", .{ .target = target, .optimize = optimize });
    const tree_sitter_astro = b.dependency("tree_sitter_astro", .{ .target = target, .optimize = optimize });

    const build_options_mod = blk: {
        var options = b.addOptions();
        options.step.name = "canipls build options";
        options.addOption(std.SemanticVersion, "version", version);
        break :blk options.createModule();
    };

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lsp", .module = lsp_kit.module("lsp") },
            .{ .name = "tree-sitter", .module = tree_sitter.module("tree_sitter") },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_html.path("src/scanner.c") });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_html.path("src/parser.c") });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_css.path("src/scanner.c") });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_css.path("src/parser.c") });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_javascript.path("src/scanner.c") });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_javascript.path("src/parser.c") });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_php.path("src/php/scanner.c") });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_php.path("src/php/parser.c") });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_svelte.path("src/scanner.c") });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_svelte.path("src/parser.c") });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_astro.path("src/scanner.c") });
    exe_mod.addCSourceFile(.{ .file = tree_sitter_astro.path("src/parser.c") });

    const exe = b.addExecutable(.{
        .name = "canipls",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // testing
    const test_exe = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_test = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_test.step);
}
