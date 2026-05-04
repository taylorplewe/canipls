const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const Parser = @import("parsers/Parser.zig");
const html_parser = @import("parsers/html.zig");
const css_parser = @import("parsers/css.zig");
const js_parser = @import("parsers/js.zig");

const log = std.log.scoped(.caniuse_ls);

const parsers: std.StaticStringMap(Parser) = .initComptime(.{
    .{ "html", html_parser.HtmlParser() },
    .{ "css", css_parser.CssParser() },
    .{ "javascript", js_parser.JavascriptParser() },
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
    const maybe_parser = prs: switch (language_kind) {
        .html => break :prs parsers.get("html"),
        .css => break :prs parsers.get("css"),
        .javascript => break :prs parsers.get("javascript"),
        .typescript => break :prs parsers.get("javascript"),
        .custom_value => |kind| {
            break :prs if (std.mem.eql(u8, kind, "vue"))
                parsers.get("html")
            else
                null;
        },
        else => break :prs null,
    };
    if (maybe_parser) |parser| {
        return parser.parse(allocator, code, 0, 0);
    }
    return &.{};
}
