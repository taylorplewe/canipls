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

    const injections = [_]types.InjectionInfo{
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

    // const html_diagnostics = html.parseHtmlAndReturnDiagnostics(
    //     allocator,
    //     code,
    //     start_column,
    //     start_row,
    //     lang_astro,
    // );

    // const QUERY_FRONTMATTER_JS = "(frontmatter (frontmatter_js_block) @js)";

    // const parser = ts.Parser.create();
    // defer parser.destroy();
    // parser.setLanguage(lang_astro) catch return &.{};

    // var diagnostics: std.ArrayList(lsp.types.Diagnostic) = .fromOwnedSlice(@constCast(html_diagnostics));

    // const parse_res = parser.parseString(code, null);
    // if (parse_res) |ast| {
    //     defer ast.destroy();

    //     const node = ast.rootNode();

    //     var error_offset: u32 = 0;
    //     const query_frontmatter_js = ts.Query.create(lang_astro, QUERY_FRONTMATTER_JS, &error_offset) catch return &.{};
    //     defer query_frontmatter_js.destroy();

    //     const cursor = ts.QueryCursor.create();
    //     defer cursor.destroy();

    //     // script (JS) blocks
    //     cursor.exec(query_frontmatter_js, node);
    //     while (cursor.nextMatch()) |match| {
    //         const js_node = match.captures[0].node;
    //         const js_code = code[js_node.startByte()..js_node.endByte()];

    //         const js_diagnostics = js.JavascriptParser().parse(
    //             allocator,
    //             js_code,
    //             js_node.startPoint().column,
    //             js_node.startPoint().row,
    //         );
    //         diagnostics.appendSlice(allocator, js_diagnostics) catch return &.{};
    //     }
    // }

    // return diagnostics.items;
}

fn getHoverInfoAtPosition(
    code: []const u8,
    column: u32,
    row: u32,
) ?HoverInfo {
    if (html.getHoverInfoFromHtmlAtPosition(
        code,
        column,
        row,
        lang_astro,
    )) |hover_info| {
        return hover_info;
    }

    const QUERY_FRONTMATTER_JS = "(frontmatter (frontmatter_js_block) @js)";

    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(lang_astro) catch return null;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();

        const node = ast.rootNode();

        var error_offset: u32 = 0;
        const query_frontmatter_js = ts.Query.create(lang_astro, QUERY_FRONTMATTER_JS, &error_offset) catch return null;
        defer query_frontmatter_js.destroy();

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        cursor.setPointRange(
            .{ .column = column, .row = row },
            .{ .column = column, .row = row },
        ) catch return null;

        // script (JS) blocks
        cursor.exec(query_frontmatter_js, node);
        while (cursor.nextMatch()) |match| {
            const js_node = match.captures[0].node;
            const js_code = code[js_node.startByte()..js_node.endByte()];

            const js_row = row - js_node.startPoint().row;
            const js_column = if (js_row == 0) column - js_node.startPoint().column else column;
            return js.JavascriptParser().getHoverInfoAtPosition(
                js_code,
                js_column,
                js_row,
            );
        }
    }

    return null;
}
