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
    const QUERY_COMMENT = "(comment) @comment";

    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(lang) catch return &.{};

    var diagnostics: std.ArrayList(lsp.types.Diagnostic) = .empty;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();

        const root_node = ast.rootNode();

        var error_offset: u32 = 0;
        const query_comments = ts.Query.create(lang, QUERY_COMMENT, &error_offset) catch return &.{};
        defer query_comments.destroy();
        const query_tags_and_attrs = ts.Query.create(lang, START_TAG_NAME_AND_ATTRS_QUERY, &error_offset) catch return &.{};
        defer query_tags_and_attrs.destroy();
        const query_style_blocks = ts.Query.create(lang, STYLE_BLOCKS, &error_offset) catch return &.{};
        defer query_style_blocks.destroy();
        const query_script_blocks = ts.Query.create(lang, SCRIPT_BLOCKS, &error_offset) catch return &.{};
        defer query_script_blocks.destroy();

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        // comments (look for canipls-ignore)
        var ignored_spans: std.ArrayList(IgnoredSpan) = .empty;
        defer ignored_spans.deinit(allocator);
        var current_ignore_region_start_row: ?usize = null;
        cursor.exec(query_comments, root_node);
        while (cursor.nextMatch()) |match| {
            const comment_node = match.captures[0].node;
            const comment_raw = code[comment_node.startByte()..comment_node.endByte()];

            const comment = std.mem.trim(
                u8,
                std.mem.cutPrefix(
                    u8,
                    std.mem.cutSuffix(u8, comment_raw, "-->").?,
                    "<!--",
                ).?,
                " \t",
            );

            if (std.mem.eql(u8, comment, "canipls-ignore-file")) {
                return &.{};
            } else if (std.mem.eql(u8, comment, "canipls-ignore")) {
                ignored_spans.append(allocator, .{ .row = comment_node.startPoint().row }) catch return &.{};
            } else if (std.mem.eql(u8, comment, "canipls-ignore-start")) {
                if (current_ignore_region_start_row) |row_start| {
                    diagnostics.append(allocator, .{
                        .range = .{
                            .start = .{ .character = comment_node.startPoint().column, .line = comment_node.startPoint().row },
                            .end = .{ .character = comment_node.endPoint().column, .line = comment_node.endPoint().row },
                        },
                        .message = std.fmt.allocPrint(allocator, "This ignore-start shadows the one found on line {d}", .{row_start + 1}) catch "ERROR - could not call allocPrint()",
                        .severity = .Warning,
                    }) catch return &.{};
                } else {
                    current_ignore_region_start_row = comment_node.startPoint().row;
                }
            } else if (std.mem.eql(u8, comment, "canipls-ignore-end")) {
                if (current_ignore_region_start_row) |row_start| {
                    ignored_spans.append(
                        allocator,
                        .{
                            .region = .{ .row_start = row_start, .row_end = comment_node.startPoint().row },
                        },
                    ) catch return &.{};
                } else {
                    diagnostics.append(allocator, .{
                        .range = .{
                            .start = .{ .character = comment_node.startPoint().column, .line = comment_node.startPoint().row },
                            .end = .{ .character = comment_node.endPoint().column, .line = comment_node.endPoint().row },
                        },
                        .message = std.fmt.allocPrint(allocator, "This ignore-end has no ignore-start pairing", .{}) catch "ERROR - could not call allocPrint()",
                        .severity = .Warning,
                    }) catch return &.{};
                }
            }
        }

        // elements and attributes
        cursor.exec(query_tags_and_attrs, root_node);
        els_and_attrs_loop: while (cursor.nextMatch()) |match| {
            const tag_node = match.captures[0].node;
            const tag_name = code[tag_node.startByte()..tag_node.endByte()];

            // TODO extract this ignore check out somehow - code is not DRY
            // contained in an ignore span?
            for (ignored_spans.items) |span| {
                switch (span) {
                    .row => |ignored_row| {
                        if (tag_node.startPoint().row == ignored_row) continue :els_and_attrs_loop;
                    },
                    .region => |ignored_region| {
                        if (tag_node.startPoint().row > ignored_region.row_start and tag_node.startPoint().row < ignored_region.row_end) continue :els_and_attrs_loop;
                    },
                }
            }

            const maybe_tag_support_percentage = Parser.getSupportPercentageForIdentifierFromBin(tag_name, html_tags_bin);
            if (maybe_tag_support_percentage) |percentage| {
                if (percentage < 90.0) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
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

                // NOTE: no ignore check needed since comments could not appear alongside individual attributes

                const maybe_attr_support_percentage = Parser.getSupportPercentageForIdentifierFromBin(attr_name, html_attributes_bin);
                if (maybe_attr_support_percentage) |percentage| {
                    if (percentage < 90.0) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
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
        cursor.exec(query_style_blocks, root_node);
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
        cursor.exec(query_script_blocks, root_node);
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
