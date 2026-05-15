const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const types = @import("../types.zig");
const HoverInfo = types.HoverInfo;
const IgnoredSpan = types.IgnoredSpan;
const Parser = @import("Parser.zig");
const html = @import("html.zig");

const log = std.log.scoped(.canipls);

extern fn tree_sitter_javascript() callconv(.c) *ts.Language;
var lang_javascript: *ts.Language = undefined;
const js_identifiers_bin: []const u8 = @embedFile("js_identifiers.bin"); // TEMP
const html_tags_bin: []const u8 = @embedFile("html_tags.bin"); // TEMP
const html_attributes_bin: []const u8 = @embedFile("html_attributes.bin"); // TEMP

pub fn JavascriptParser() Parser {
    return .{
        .init = init,
        .deinit = deinit,
        .parse = parse,
        .getHoverInfoAtPosition = getHoverInfoAtPosition,
    };
}

fn init() void {
    lang_javascript = tree_sitter_javascript();
}
fn deinit() void {
    lang_javascript.destroy();
}
fn parse(
    allocator: std.mem.Allocator,
    code: []const u8,
    start_column: u32,
    start_row: u32,
) []const lsp.types.Diagnostic {
    const QUERY_IDENTIFIERS = "(identifier) @name";
    const QUERY_JSX_TAGS = "(jsx_opening_element (identifier) @tagname)";
    const QUERY_JSX_ATTRS = "(jsx_attribute (property_identifier) @attrname)";

    const symbols = [_]types.SymbolInfo{
        .{
            .element_kind = .JsApi,
            .support_bin = js_identifiers_bin,
            .ts_query_text = QUERY_IDENTIFIERS,
        },
        .{
            .element_kind = .HtmlElement,
            .support_bin = html.html_tags_bin,
            .ts_query_text = QUERY_JSX_TAGS,
        },
        .{
            .element_kind = .HtmlAttribute,
            .support_bin = html.html_attributes_bin,
            .ts_query_text = QUERY_JSX_ATTRS,
        },
    };

    return Parser.getDiagnosticsFromCode(
        allocator,
        lang_javascript,
        code,
        start_column,
        start_row,
        trimComment,
        &symbols,
        &.{},
    );
}

fn getHoverInfoAtPosition(
    code: []const u8,
    column: u32,
    row: u32,
) ?HoverInfo {
    const QUERY_IDENTIFIERS = "(identifier) @name";
    const QUERY_JSX_TAGS = "(jsx_opening_element (identifier) @tagname)";
    const QUERY_JSX_ATTRS = "(jsx_attribute (property_identifier) @attrname)";

    const symbols = [_]types.SymbolInfo{
        .{
            .element_kind = .JsApi,
            .support_bin = js_identifiers_bin,
            .ts_query_text = QUERY_IDENTIFIERS,
        },
        .{
            .element_kind = .HtmlElement,
            .support_bin = html.html_tags_bin,
            .ts_query_text = QUERY_JSX_TAGS,
        },
        .{
            .element_kind = .HtmlAttribute,
            .support_bin = html.html_attributes_bin,
            .ts_query_text = QUERY_JSX_ATTRS,
        },
    };

    return Parser.getHoverDocFromCodeAtPosition(
        lang_javascript,
        code,
        column,
        row,
        &symbols,
        &.{},
    );
}

fn trimComment(comment_raw: []const u8) []const u8 {
    if (std.mem.startsWith(u8, comment_raw, "/*")) {
        // remove leading "/* **" and trailing "** */"
        return std.mem.trim(
            u8,
            std.mem.trim(
                u8,
                std.mem.cutPrefix(
                    u8,
                    std.mem.cutSuffix(u8, comment_raw, "*/").?,
                    "/*",
                ).?,
                "*",
            ),
            " \t",
        );
    } else if (std.mem.startsWith(u8, comment_raw, "//")) {
        return std.mem.trim(
            u8,
            std.mem.cutPrefix(u8, comment_raw, "//").?,
            " \t",
        );
    } else return "";
}
