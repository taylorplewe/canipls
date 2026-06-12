const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const types = @import("../types.zig");
const HoverInfo = types.HoverInfo;
const Parser = @import("Parser.zig");
const html = @import("html.zig");
const js = @import("js.zig");
const css = @import("css.zig");
const bins = @import("bins.zig");

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

fn init() void {
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
    const QUERY_FRONTMATTER_JS = "(frontmatter (frontmatter_js_block) @js)";
    const QUERY_STYLE_BLOCKS = "(style_element (raw_text) @css)";
    const QUERY_SCRIPT_BLOCKS = "(script_element (raw_text) @js)";

    const injections = [_]types.InjectionParseInfo{
        .{
            .injectionParseFn = js.JavascriptParser().parse,
            .ts_query_text = QUERY_SCRIPT_BLOCKS,
        },
        .{
            .injectionParseFn = js.JavascriptParser().parse,
            .ts_query_text = QUERY_FRONTMATTER_JS,
        },
        .{
            .injectionParseFn = css.CssParser().parse,
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
        &.{
            .{
                .ts_query_text = html.TagsAndAttrsContext.QUERY_TAGS_AND_ATTRS_DIAGNOSTICS,
                .perNodeCallback = html.TagsAndAttrsContext.callback,
            },
        },
        &injections,
    ) catch |err| {
        log.err("could not get diagnostics for Astro code: {}", .{err});
        return &.{};
    };
}

fn getHoverInfoAtPosition(
    temp_allocator: std.mem.Allocator,
    code: []const u8,
    column: u32,
    row: u32,
) ?HoverInfo {
    _ = temp_allocator; // autofix
    _ = code; // autofix
    _ = column; // autofix
    _ = row; // autofix
    // const QUERY_TAGS = "(start_tag (tag_name) @tagname)";
    // const QUERY_ATTRS = "(attribute_name) @attrname";
    // const QUERY_STYLE_BLOCKS = "(style_element (raw_text) @css)";
    // const QUERY_SCRIPT_BLOCKS = "(script_element (raw_text) @js)";
    // const QUERY_FRONTMATTER_JS = "(frontmatter (frontmatter_js_block) @js)";

    // const symbols = [_]types.SymbolInfo{
    //     .{
    //         .element_kind = .HtmlAttribute,
    //         .support_bin = bins.bin_map.getPtrConstAssertContains(.HtmlAttribute),
    //         .ts_query_text = QUERY_ATTRS,
    //     },
    //     .{
    //         .element_kind = .HtmlElement,
    //         .support_bin = bins.bin_map.getPtrConstAssertContains(.HtmlTag),
    //         .ts_query_text = QUERY_TAGS,
    //     },
    // };

    // const injections = [_]types.InjectionHoverInfo{
    //     .{
    //         .injection_hover_fn = js.JavascriptParser().getHoverInfoAtPosition,
    //         .ts_query_text = QUERY_FRONTMATTER_JS,
    //     },
    //     .{
    //         .injection_hover_fn = js.JavascriptParser().getHoverInfoAtPosition,
    //         .ts_query_text = QUERY_SCRIPT_BLOCKS,
    //     },
    //     .{
    //         .injection_hover_fn = css.CssParser().getHoverInfoAtPosition,
    //         .ts_query_text = QUERY_STYLE_BLOCKS,
    //     },
    // };

    // return Parser.getHoverDocFromCodeAtPosition(
    //     lang_astro,
    //     code,
    //     column,
    //     row,
    //     &symbols,
    //     &injections,
    // );
    return null;
}
