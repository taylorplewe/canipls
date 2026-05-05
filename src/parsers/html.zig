const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const Parser = @import("Parser.zig");
const css = @import("css.zig");
const js = @import("js.zig");

const log = std.log.scoped(.caniuse_ls);

extern fn tree_sitter_html() callconv(.c) *ts.Language;
var lang_html: *ts.Language = undefined;

pub fn HtmlParser() Parser {
    return .{
        .init = init,
        .deinit = deinit,
        .parse = parse,
        .getHoverDocAtPosition = getHoverDocAtPosition,
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

            // send diagnostic on <geolocation> element
            if (std.mem.eql(u8, tag_name, "geolocation")) {
                diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                    allocator,
                    &tag_node,
                    .HtmlElement,
                    75.86,
                    start_column,
                    start_row,
                )) catch return &.{};
            }

            for (match.captures[1..]) |capture| {
                const attr_node = capture.node;
                const attr_name = code[attr_node.startByte()..attr_node.endByte()];

                // send diagnostic on "virtualkeyboardpolicy" attribute
                if (std.mem.eql(u8, attr_name, "virtualkeyboardpolicy")) {
                    diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                        allocator,
                        &attr_node,
                        .HtmlAttribute,
                        75.86,
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

fn getHoverDocAtPosition(
    code: []const u8,
    column: u32,
    row: u32,
) []const u8 {
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
    parser.setLanguage(lang_html) catch return &.{};

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();

        const node = ast.rootNode();

        var error_offset: u32 = 0;
        const query_tags_and_attrs = ts.Query.create(lang_html, START_TAG_NAME_AND_ATTRS_QUERY, &error_offset) catch return &.{};
        defer query_tags_and_attrs.destroy();
        const query_style_blocks = ts.Query.create(lang_html, STYLE_BLOCKS, &error_offset) catch return &.{};
        defer query_style_blocks.destroy();
        const query_script_blocks = ts.Query.create(lang_html, SCRIPT_BLOCKS, &error_offset) catch return &.{};
        defer query_script_blocks.destroy();

        var cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        cursor.setPointRange(.{ .column = column, .row = row }, .{ .column = column, .row = row }) catch return "";

        // elements and attributes
        cursor.exec(query_tags_and_attrs, node);
        while (cursor.nextMatch()) |match| {
            const tag_node = match.captures[0].node;
            const tag_name = code[tag_node.startByte()..tag_node.endByte()];

            log.info("found this tag: {s}", .{tag_name});

            // send diagnostic on <geolocation> element
            if (std.mem.eql(u8, tag_name, "geolocation")) {}

            for (match.captures[1..]) |capture| {
                const attr_node = capture.node;
                const attr_name = code[attr_node.startByte()..attr_node.endByte()];

                // send diagnostic on "virtualkeyboardpolicy" attribute
                if (std.mem.eql(u8, attr_name, "virtualkeyboardpolicy")) {}
            }
        }
    }

    return "";
}
