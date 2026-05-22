//! This file acts as a liaison between the *parsing* world (tree sitter) and the *server* world (LSP)

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

const log = std.log.scoped(.canipls);

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
            log.info("custom type: {s}", .{kind});
            return if (std.mem.eql(u8, kind, "vue"))
                parsers.get("html")
            else if (std.mem.eql(u8, kind, "Vue.js"))
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
    return parser.parse(
        allocator,
        code,
        0,
        0,
    );
}

const CANIUSE_HREF_PREFIX = "https://caniuse.com/";
pub fn getHoverDocAtPosition(
    temp_allocator: std.mem.Allocator,
    position: lsp.types.Position,
    document: *const Document,
) ?lsp.types.Hover {
    const parser = getParserFromLspLanguageKind(document.language) orelse return null;

    const hover_info = parser.getHoverInfoAtPosition(document.src, position.character, position.line);
    if (hover_info) |info| {
        const hover_content = std.fmt.allocPrint(
            temp_allocator,
            "**{d:.2}%** global support on caniuse.com\n\n[See \"{s}\" on caniuse.com](" ++ CANIUSE_HREF_PREFIX ++ "{s})",
            .{
                info.support_percentage,
                info.identifier,
                info.caniuse_id,
            },
        ) catch return null;

        return .{
            .contents = .{
                .markup_content = .{
                    .kind = .markdown,
                    .value = hover_content,
                },
            },
        };
    }

    return null;
}
