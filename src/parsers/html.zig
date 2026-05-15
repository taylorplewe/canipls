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

fn init(io: std.Io) void {
    _ = io; // autofix
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

    const injections = [_]types.InjectionInfo{
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
    const TAG_NAME_QUERY = "(tag_name) @tagname";
    const ATTR_QUERY = "(attribute_name) @attrname";

    const STYLE_BLOCKS = "(style_element (raw_text) @css)";
    const SCRIPT_BLOCKS = "(script_element (raw_text) @js)";

    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(lang) catch return null;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();

        const node = ast.rootNode();

        var error_offset: u32 = 0;
        const query_tags = ts.Query.create(lang, TAG_NAME_QUERY, &error_offset) catch return null;
        defer query_tags.destroy();
        const query_attrs = ts.Query.create(lang, ATTR_QUERY, &error_offset) catch return null;
        defer query_attrs.destroy();
        const query_style_blocks = ts.Query.create(lang, STYLE_BLOCKS, &error_offset) catch return null;
        defer query_style_blocks.destroy();
        const query_script_blocks = ts.Query.create(lang, SCRIPT_BLOCKS, &error_offset) catch return null;
        defer query_script_blocks.destroy();

        var cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        cursor.setPointRange(
            .{ .column = column, .row = row },
            .{ .column = column, .row = row },
        ) catch return null;

        // elements
        cursor.exec(query_tags, node);
        while (cursor.nextMatch()) |match| {
            const tag_node = match.captures[0].node;
            const tag_name = code[tag_node.startByte()..tag_node.endByte()];

            const maybe_tag_support_percentage = Parser.getSupportPercentageForIdentifierFromBin(tag_name, html_tags_bin);
            if (maybe_tag_support_percentage) |percentage| {
                return HoverInfo{
                    .caniuse_id = "html_elements_geolocation", // TEMP
                    .identifier = tag_name,
                    .support_percentage = percentage,
                };
            }
        }

        // attributes
        cursor.exec(query_attrs, node);
        while (cursor.nextMatch()) |match| {
            const attr_node = match.captures[0].node;
            const attr_name = code[attr_node.startByte()..attr_node.endByte()];

            const maybe_attr_support_percentage = Parser.getSupportPercentageForIdentifierFromBin(attr_name, html_attributes_bin);
            if (maybe_attr_support_percentage) |percentage| {
                return HoverInfo{
                    .caniuse_id = "html_elements_geolocation", // TEMP
                    .identifier = attr_name,
                    .support_percentage = percentage,
                };
            }
        }

        // style (CSS) blocks
        cursor.exec(query_style_blocks, node);
        while (cursor.nextMatch()) |match| {
            const css_node = match.captures[0].node;
            const css_code = code[css_node.startByte()..css_node.endByte()];

            const css_row = row - css_node.startPoint().row;
            const css_column = if (css_row == 0) column - css_node.startPoint().column else column;
            return css.CssParser().getHoverInfoAtPosition(css_code, css_column, css_row);
        }

        // script (JS) blocks
        cursor.exec(query_script_blocks, node);
        while (cursor.nextMatch()) |match| {
            const js_node = match.captures[0].node;
            const js_code = code[js_node.startByte()..js_node.endByte()];

            const js_row = row - js_node.startPoint().row;
            const js_column = if (js_row == 0) column - js_node.startPoint().column else column;
            return js.JavascriptParser().getHoverInfoAtPosition(js_code, js_column, js_row);
        }
    }

    return null;
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
