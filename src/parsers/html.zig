const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const types = @import("../types.zig");
const HoverInfo = types.HoverInfo;
const IgnoredSpan = types.IgnoredSpan;
const Parser = @import("Parser.zig");
const css = @import("css.zig");
const js = @import("js.zig");

const log = std.log.scoped(.canipls);

extern fn tree_sitter_html() callconv(.c) *ts.Language;
var lang_html: *ts.Language = undefined;
pub const html_tags_bin: []const u8 = @embedFile("html_tags.bin"); // TEMP
pub const html_attributes_bin: []const u8 = @embedFile("html_attributes.bin"); // TEMP

pub fn HtmlParser() Parser {
    return .{
        .init = init,
        .deinit = deinit,
        .parse = parse,
        .getHoverInfoAtPosition = getHoverInfoAtPosition,
    };
}

fn init() void {
    lang_html = tree_sitter_html();
}
fn deinit() void {
    lang_html.destroy();
}
fn parse(
    allocator: std.mem.Allocator,
    code: []const u8,
    start_column: u32,
    start_row: u32,
) []const lsp.types.Diagnostic {
    return parseHtmlAndReturnDiagnostics(
        allocator,
        code,
        start_column,
        start_row,
        lang_html,
    );
}

pub fn parseHtmlAndReturnDiagnostics(
    allocator: std.mem.Allocator,
    code: []const u8,
    start_column: u32,
    start_row: u32,
    lang: *ts.Language,
) []const lsp.types.Diagnostic {
    const QUERY_TAGS = "(start_tag (tag_name) @tagname)";
    const QUERY_ATTRS = "(attribute_name) @attrname";
    const QUERY_STYLE_BLOCKS = "(style_element (raw_text) @css)";
    const QUERY_SCRIPT_BLOCKS = "(script_element (raw_text) @js)";

    const symbols = [_]types.SymbolInfo{
        .{
            .element_kind = .HtmlAttribute,
            .support_bin = html_attributes_bin,
            .ts_query_text = QUERY_ATTRS,
        },
        .{
            .element_kind = .HtmlElement,
            .support_bin = html_tags_bin,
            .ts_query_text = QUERY_TAGS,
        },
    };

    const injections = [_]types.InjectionParseInfo{
        .{
            .injection_parse_fn = js.JavascriptParser().parse,
            .ts_query_text = QUERY_SCRIPT_BLOCKS,
        },
        .{
            .injection_parse_fn = css.CssParser().parse,
            .ts_query_text = QUERY_STYLE_BLOCKS,
        },
    };

    return Parser.getDiagnosticsFromCode(
        allocator,
        lang,
        code,
        start_column,
        start_row,
        trimComment,
        &symbols,
        &injections,
    );
}

pub fn trimComment(in: []const u8) []const u8 {
    return std.mem.trim(
        u8,
        std.mem.cutPrefix(
            u8,
            std.mem.cutSuffix(u8, in, "-->").?,
            "<!--",
        ).?,
        " \t",
    );
}

pub fn getHoverInfoFromHtmlAtPosition(
    code: []const u8,
    column: u32,
    row: u32,
    lang: *ts.Language,
) ?HoverInfo {
    const QUERY_TAGS = "(tag_name) @tagname";
    const QUERY_ATTRS = "(attribute_name) @attrname";
    const QUERY_STYLE_BLOCKS = "(style_element (raw_text) @css)";
    const QUERY_SCRIPT_BLOCKS = "(script_element (raw_text) @js)";

    const symbols = [_]types.SymbolInfo{
        .{
            .element_kind = .HtmlAttribute,
            .support_bin = html_attributes_bin,
            .ts_query_text = QUERY_ATTRS,
        },
        .{
            .element_kind = .HtmlElement,
            .support_bin = html_tags_bin,
            .ts_query_text = QUERY_TAGS,
        },
    };

    const injections = [_]types.InjectionHoverInfo{
        .{
            .injection_hover_fn = js.JavascriptParser().getHoverInfoAtPosition,
            .ts_query_text = QUERY_SCRIPT_BLOCKS,
        },
        .{
            .injection_hover_fn = css.CssParser().getHoverInfoAtPosition,
            .ts_query_text = QUERY_STYLE_BLOCKS,
        },
    };

    return Parser.getHoverDocFromCodeAtPosition(
        lang,
        code,
        column,
        row,
        &symbols,
        &injections,
    );
}

/// TODO: most of this code is copy-pasted from the parse function (same goes for other parsers), abstract the code out somehow
fn getHoverInfoAtPosition(
    code: []const u8,
    column: u32,
    row: u32,
) ?HoverInfo {
    return getHoverInfoFromHtmlAtPosition(
        code,
        column,
        row,
        lang_html,
    );
}
