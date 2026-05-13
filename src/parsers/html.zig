const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const types = @import("../types.zig");
const HoverInfo = types.HoverInfo;
const Parser = @import("Parser.zig");
const css = @import("css.zig");
const js = @import("js.zig");

const log = std.log.scoped(.caniuse_ls);

extern fn tree_sitter_html() callconv(.c) *ts.Language;
var lang_html: *ts.Language = undefined;
const html_tags_bin: []const u8 = @embedFile("html_tags.bin"); // TEMP
const html_attributes_bin: []const u8 = @embedFile("html_attributes.bin"); // TEMP

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
    const START_TAG_NAME_AND_ATTRS_QUERY =
        \\(start_tag
        \\  (tag_name) @tagname
        \\  (attribute
        \\    (attribute_name) @attrname
        \\  )*
        \\)
    ;

    const STYLE_BLOCKS = "(style_element (raw_text) @css)";
    const SCRIPT_BLOCKS = "(script_element (raw_text) @js)";

    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(lang) catch return &.{};

    var diagnostics: std.ArrayList(lsp.types.Diagnostic) = .empty;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();

        const node = ast.rootNode();

        var error_offset: u32 = 0;
        const query_tags_and_attrs = ts.Query.create(lang, START_TAG_NAME_AND_ATTRS_QUERY, &error_offset) catch return &.{};
        defer query_tags_and_attrs.destroy();
        const query_style_blocks = ts.Query.create(lang, STYLE_BLOCKS, &error_offset) catch return &.{};
        defer query_style_blocks.destroy();
        const query_script_blocks = ts.Query.create(lang, SCRIPT_BLOCKS, &error_offset) catch return &.{};
        defer query_script_blocks.destroy();

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        // elements and attributes
        cursor.exec(query_tags_and_attrs, node);
        while (cursor.nextMatch()) |match| {
            const tag_node = match.captures[0].node;
            const tag_name = code[tag_node.startByte()..tag_node.endByte()];

            const maybe_tag_support_percentage = Parser.getLowSupportPercentageOrNullFromBin(tag_name, html_tags_bin);
            if (maybe_tag_support_percentage) |percentage| {
                diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                    allocator,
                    &tag_node,
                    .HtmlElement,
                    percentage,
                    start_column,
                    start_row,
                )) catch return &.{};
            }

            for (match.captures[1..]) |capture| {
                const attr_node = capture.node;
                const attr_name = code[attr_node.startByte()..attr_node.endByte()];

                const maybe_attr_support_percentage = Parser.getLowSupportPercentageOrNullFromBin(attr_name, html_attributes_bin);
                if (maybe_attr_support_percentage) |percentage| {
                    diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                        allocator,
                        &attr_node,
                        .HtmlAttribute,
                        percentage,
                        start_column,
                        start_row,
                    )) catch return &.{};
                }
            }
        }

        // style (CSS) blocks
        cursor.exec(query_style_blocks, node);
        while (cursor.nextMatch()) |match| {
            const css_node = match.captures[0].node;
            const css_code = code[css_node.startByte()..css_node.endByte()];

            const css_diagnostics = css.CssParser().parse(
                allocator,
                css_code,
                css_node.startPoint().column,
                css_node.startPoint().row,
            );
            diagnostics.appendSlice(allocator, css_diagnostics) catch return &.{};
        }

        // script (JS) blocks
        cursor.exec(query_script_blocks, node);
        while (cursor.nextMatch()) |match| {
            const js_node = match.captures[0].node;
            const js_code = code[js_node.startByte()..js_node.endByte()];

            const js_diagnostics = js.JavascriptParser().parse(
                allocator,
                js_code,
                js_node.startPoint().column,
                js_node.startPoint().row,
            );
            diagnostics.appendSlice(allocator, js_diagnostics) catch return &.{};
        }
    }

    return diagnostics.items;
}

fn getHoverInfoAtPosition(
    code: []const u8,
    column: u32,
    row: u32,
) ?HoverInfo {
    const START_TAG_NAME_AND_ATTRS_QUERY =
        \\(start_tag
        \\  (tag_name) @tagname
        \\  (attribute
        \\    (attribute_name) @attrname
        \\  )*
        \\)
    ;

    const STYLE_BLOCKS = "(style_element (raw_text) @css)";
    const SCRIPT_BLOCKS = "(script_element (raw_text) @js)";

    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(lang_html) catch return null;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();

        const node = ast.rootNode();

        var error_offset: u32 = 0;
        const query_tags_and_attrs = ts.Query.create(lang_html, START_TAG_NAME_AND_ATTRS_QUERY, &error_offset) catch return null;
        defer query_tags_and_attrs.destroy();
        const query_style_blocks = ts.Query.create(lang_html, STYLE_BLOCKS, &error_offset) catch return null;
        defer query_style_blocks.destroy();
        const query_script_blocks = ts.Query.create(lang_html, SCRIPT_BLOCKS, &error_offset) catch return null;
        defer query_script_blocks.destroy();

        var cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        cursor.setPointRange(.{ .column = column, .row = row }, .{ .column = column, .row = row }) catch return null;

        // elements and attributes
        cursor.exec(query_tags_and_attrs, node);
        while (cursor.nextMatch()) |match| {
            const tag_node = match.captures[0].node;
            const tag_name = code[tag_node.startByte()..tag_node.endByte()];

            if (std.mem.eql(u8, tag_name, "geolocation")) {
                return HoverInfo{
                    .caniuse_id = "html_elements_geolocation",
                    .identifier = tag_name,
                    .support_percentage = 75.86,
                };
            }

            for (match.captures[1..]) |capture| {
                const attr_node = capture.node;
                const attr_name = code[attr_node.startByte()..attr_node.endByte()];

                if (std.mem.eql(u8, attr_name, "virtualkeyboardpolicy")) {
                    return HoverInfo{
                        .caniuse_id = "api_htmlelement_virtualkeyboardpolicy",
                        .identifier = attr_name,
                        .support_percentage = 75.86,
                    };
                }
            }
        }
    }

    return null;
}
