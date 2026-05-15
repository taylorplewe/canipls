const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const types = @import("../types.zig");
const HoverInfo = types.HoverInfo;
const Parser = @import("Parser.zig");
const html = @import("html.zig");
const js = @import("js.zig");
const css = @import("css.zig");

const log = std.log.scoped(.canipls);

extern fn tree_sitter_astro() callconv(.c) *ts.Language;
var lang_astro: *ts.Language = undefined;

pub fn AstroParser() Parser {
    return .{
        .init = init,
        .deinit = deinit,
        .parse = parse,
        .getHoverInfoAtPosition = getHoverInfoAtPosition,
    };
}

fn init(io: std.Io) void {
    _ = io; // autofix
    lang_astro = tree_sitter_astro();
}
fn deinit() void {
    lang_astro.destroy();
}
fn parse(
    allocator: std.mem.Allocator,
    code: []const u8,
    start_column: u32,
    start_row: u32,
) []const lsp.types.Diagnostic {
    const QUERY_TAGS = "(start_tag (tag_name) @tagname)";
    const QUERY_ATTRS = "(attribute_name) @attrname";
    const QUERY_STYLE_BLOCKS = "(style_element (raw_text) @css)";
    const QUERY_SCRIPT_BLOCKS = "(script_element (raw_text) @js)";
    const QUERY_FRONTMATTER_JS = "(frontmatter (frontmatter_js_block) @js)";

    const symbols = [_]types.SymbolInfo{
        .{
            .element_kind = .HtmlAttribute,
            .support_bin = html.html_attributes_bin,
            .ts_query_text = QUERY_ATTRS,
        },
        .{
            .element_kind = .HtmlElement,
            .support_bin = html.html_tags_bin,
            .ts_query_text = QUERY_TAGS,
        },
    };

    const injections = [_]types.InjectionParseInfo{
        .{
            .injection_parse_fn = js.JavascriptParser().parse,
            .ts_query_text = QUERY_FRONTMATTER_JS,
        },
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
        lang_astro,
        code,
        start_column,
        start_row,
        html.trimComment,
        &symbols,
        &injections,
    );
}

fn getHoverInfoAtPosition(
    code: []const u8,
    column: u32,
    row: u32,
) ?HoverInfo {
    const QUERY_TAGS = "(start_tag (tag_name) @tagname)";
    const QUERY_ATTRS = "(attribute_name) @attrname";
    const QUERY_STYLE_BLOCKS = "(style_element (raw_text) @css)";
    const QUERY_SCRIPT_BLOCKS = "(script_element (raw_text) @js)";
    const QUERY_FRONTMATTER_JS = "(frontmatter (frontmatter_js_block) @js)";

    const symbols = [_]types.SymbolInfo{
        .{
            .element_kind = .HtmlAttribute,
            .support_bin = html.html_attributes_bin,
            .ts_query_text = QUERY_ATTRS,
        },
        .{
            .element_kind = .HtmlElement,
            .support_bin = html.html_tags_bin,
            .ts_query_text = QUERY_TAGS,
        },
    };

    const injections = [_]types.InjectionHoverInfo{
        .{
            .injection_hover_fn = js.JavascriptParser().getHoverInfoAtPosition,
            .ts_query_text = QUERY_FRONTMATTER_JS,
        },
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
        lang_astro,
        code,
        column,
        row,
        &symbols,
        &injections,
    );
}
