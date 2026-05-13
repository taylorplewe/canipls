const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const types = @import("../types.zig");
const HoverInfo = types.HoverInfo;
const Parser = @import("Parser.zig");

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

fn init(io: std.Io) void {
    _ = io; // autofix
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

            const maybe_tag_support_percentage = Parser.getSupportPercentageForIdentifierFromBin(identifier_name, js_identifiers_bin);
            if (maybe_tag_support_percentage) |percentage| {
                if (percentage < 90.0) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                    allocator,
                    &identifier_node,
                    .JsApi, // TODO: distinguish between API and builtin?
                    percentage,
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
    }

    return diagnostics.items;
}

fn getHoverInfoAtPosition(
    code: []const u8,
    column: u32,
    row: u32,
) ?HoverInfo {
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
    parser.setLanguage(lang_javascript) catch return null;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();

        const root_node = ast.rootNode();

        var error_offset: u32 = 0;
        const query_identifiers = ts.Query.create(lang_javascript, QUERY_IDENTIFIERS, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return null;
        };
        defer query_identifiers.destroy();
        const query_jsx_tags_and_attrs = ts.Query.create(lang_javascript, QUERY_TAG_NAME_AND_ATTRS, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return null;
        };
        defer query_jsx_tags_and_attrs.destroy();

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        cursor.setPointRange(
            .{ .column = column, .row = row },
            .{ .column = column, .row = row },
        ) catch return null;

        // identifiers
        cursor.exec(query_identifiers, root_node);
        while (cursor.nextMatch()) |match| {
            const identifier_node = match.captures[0].node;
            const identifier_name = code[identifier_node.startByte()..identifier_node.endByte()];

            const maybe_attr_support_percentage = Parser.getSupportPercentageForIdentifierFromBin(identifier_name, js_identifiers_bin);
            if (maybe_attr_support_percentage) |percentage| {
                return HoverInfo{
                    .caniuse_id = "html_elements_geolocation", // TEMP
                    .identifier = identifier_name,
                    .support_percentage = percentage,
                };
            }
        }

        // JSX elements and attributes
        cursor.exec(query_jsx_tags_and_attrs, root_node);
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

            for (match.captures[1..]) |capture| {
                const attr_node = capture.node;
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
        }
    }

    return null;
}
