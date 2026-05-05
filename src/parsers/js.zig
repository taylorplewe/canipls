const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const Parser = @import("Parser.zig");

const log = std.log.scoped(.caniuse_ls);

extern fn tree_sitter_javascript() callconv(.c) *ts.Language;
var lang_javascript: *ts.Language = undefined;

pub fn JavascriptParser() Parser {
    return .{
        .init = init,
        .deinit = deinit,
        .parse = parse,
        .getHoverDocAtPosition = getHoverDocAtPosition,
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
    const QUERY_TAG_NAME_AND_ATTRS =
        \\(jsx_opening_element
        \\  (identifier) @tagname
        \\  (jsx_attribute
        \\    (property_identifier) @attrname
        \\  )*
        \\)
    ;

    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(lang_javascript) catch return &.{};

    var diagnostics: std.ArrayList(lsp.types.Diagnostic) = .empty;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();

        const root_node = ast.rootNode();

        var error_offset: u32 = 0;
        const query_identifiers = ts.Query.create(lang_javascript, QUERY_IDENTIFIERS, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return &.{};
        };
        defer query_identifiers.destroy();
        const query_jsx_tags_and_attrs = ts.Query.create(lang_javascript, QUERY_TAG_NAME_AND_ATTRS, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return &.{};
        };
        defer query_jsx_tags_and_attrs.destroy();

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        // identifiers
        cursor.exec(query_identifiers, root_node);
        while (cursor.nextMatch()) |match| {
            const identifier_node = match.captures[0].node;
            const identifier_name = code[identifier_node.startByte()..identifier_node.endByte()];

            // TEMP
            if (std.mem.eql(u8, identifier_name, "trustedTypes")) {
                diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                    allocator,
                    &identifier_node,
                    .JsApi,
                    88.95,
                    start_column,
                    start_row,
                )) catch return &.{};
            } else if (std.mem.eql(u8, identifier_name, "Temporal")) {
                diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                    allocator,
                    &identifier_node,
                    .JsApi,
                    69.28,
                    start_column,
                    start_row,
                )) catch return &.{};
            }
        }

        // JSX elements and attributes
        cursor.exec(query_jsx_tags_and_attrs, root_node);
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
    }

    return diagnostics.items;
}

fn getHoverDocAtPosition(
    code: []const u8,
    column: u32,
    row: u32,
) []const u8 {
    _ = code; // autofix
    _ = column; // autofix
    _ = row; // autofix

    return "";
}
