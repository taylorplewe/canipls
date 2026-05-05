const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const Document = @import("Document.zig");
const Parser = @import("parsers/Parser.zig");
const html_parser = @import("parsers/html.zig");
const css_parser = @import("parsers/css.zig");
const js_parser = @import("parsers/js.zig");
const svelte_parser = @import("parsers/svelte.zig");
const astro_parser = @import("parsers/astro.zig");

const log = std.log.scoped(.caniuse_ls);

const parsers: std.StaticStringMap(Parser) = .initComptime(.{
    .{ "html", html_parser.HtmlParser() },
    .{ "css", css_parser.CssParser() },
    .{ "javascript", js_parser.JavascriptParser() },
    .{ "svelte", svelte_parser.SvelteParser() },
    .{ "astro", astro_parser.AstroParser() },
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

fn getParserFromLspLanguageKind(language_kind: lsp.types.TextDocument.LanguageKind) ?Parser {
    switch (language_kind) {
        .html => return parsers.get("html"),
        .css => return parsers.get("css"),
        .javascript => return parsers.get("javascript"),
        .typescript => return parsers.get("javascript"),
        .javascriptreact => return parsers.get("javascript"),
        .typescriptreact => return parsers.get("javascript"),
        .custom_value => |kind| {
            return if (std.mem.eql(u8, kind, "vue"))
                parsers.get("html")
            else if (std.mem.eql(u8, kind, "svelte"))
                parsers.get("svelte")
            else if (std.mem.eql(u8, kind, "astro"))
                parsers.get("astro")
            else
                null;
        },
        else => return null,
    }
}

pub fn parseCodeAndGetDiagnostics(
    allocator: std.mem.Allocator,
    language_kind: lsp.types.TextDocument.LanguageKind,
    code: []const u8,
) []const lsp.types.Diagnostic {
    const parser = getParserFromLspLanguageKind(language_kind) orelse return &.{};
    return parser.parse(allocator, code, 0, 0);
}

pub fn getHoverDocAtPoint(
    position: lsp.types.Position,
    document: *const Document,
) []const u8 {
    const parser = getParserFromLspLanguageKind(document.language) orelse return "";
    return parser.getHoverDocAtPosition(document.src, position.character, position.line);
}
