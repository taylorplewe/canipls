const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const Parser = @import("parsers/Parser.zig");
const html_parser = @import("parsers/html.zig");

const parsers: std.StaticStringMap(Parser) = .initComptime(.{
    .{ "html", html_parser.HtmlParser() },
});

pub fn init() void {
    for (parsers.values()) |parser| {
        parser.init();
    }
}

pub fn deinit() void {
    for (parsers.values()) |parser| {
        parser.deinit();
    }
}

pub fn parseCodeAndGetDiagnostics(
    allocator: std.mem.Allocator,
    language_kind: lsp.types.TextDocument.LanguageKind,
    code: []const u8,
) []const lsp.types.Diagnostic {
    switch (language_kind) {
        .html => return parsers.get("html").?.parse(allocator, code),
        else => {},
    }

    return &.{};
}
