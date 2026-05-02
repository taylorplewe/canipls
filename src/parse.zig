const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const Parser = @import("parsers/Parser.zig");
const html_parser = @import("parsers/html.zig");
const css_parser = @import("parsers/css.zig");
const javascript_parser = @import("parsers/javascript.zig");

const log = std.log.scoped(.caniuse_ls);

const parsers: std.StaticStringMap(Parser) = .initComptime(.{
    .{ "html", html_parser.HtmlParser() },
    .{ "css", css_parser.CssParser() },
    .{ "javascript", javascript_parser.JavascriptParser() },
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
        .html => return parsers.get("html").?.parse(allocator, code, 0, 0),
        .css => return parsers.get("css").?.parse(allocator, code, 0, 0),
        .javascript => return parsers.get("javascript").?.parse(allocator, code, 0, 0),
        else => {},
    }

    return &.{};
}
