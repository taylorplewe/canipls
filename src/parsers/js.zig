const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const types = @import("../types.zig");
const HoverInfo = types.HoverInfo;
const IgnoredSpan = types.IgnoredSpan;
const Parser = @import("Parser.zig");
const html = @import("html.zig");

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
    const QUERY_JSX_TAGS = "(jsx_opening_element (identifier) @tagname)";
    const QUERY_JSX_ATTRS = "(jsx_attribute (property_identifier) @attrname)";

    const symbols = [_]types.SymbolInfo{
        .{
            .element_kind = .JsApi,
            .support_bin = js_identifiers_bin,
            .ts_query_text = QUERY_IDENTIFIERS,
        },
        .{
            .element_kind = .HtmlElement,
            .support_bin = html.html_tags_bin,
            .ts_query_text = QUERY_JSX_TAGS,
        },
        .{
            .element_kind = .HtmlAttribute,
            .support_bin = html.html_attributes_bin,
            .ts_query_text = QUERY_JSX_ATTRS,
        },
    };

    return Parser.getDiagnosticsFromCode(
        allocator,
        lang_javascript,
        code,
        start_column,
        start_row,
        trimComment,
        &symbols,
        &.{},
    );
}

fn getHoverInfoAtPosition(
    code: []const u8,
    column: u32,
    row: u32,
) ?HoverInfo {
    const QUERY_IDENTIFIERS = "(identifier) @name";
    const QUERY_JSX_TAGS =
        \\[
        \\  (jsx_opening_element
        \\    (identifier) @tagname
        \\  )
        \\  (jsx_closing_element
        \\    (identifier) @tagname
        \\  )
        \\]
    ;
    const QUERY_JSX_ATTRS =
        \\(jsx_attribute
        \\  (property_identifier) @attrname
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
        const query_jsx_tags = ts.Query.create(lang_javascript, QUERY_JSX_TAGS, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return null;
        };
        defer query_jsx_tags.destroy();
        const query_jsx_attrs = ts.Query.create(lang_javascript, QUERY_JSX_ATTRS, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return null;
        };
        defer query_jsx_attrs.destroy();

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

        // JSX attributes
        cursor.exec(query_jsx_tags, root_node);
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

        // JSX elements
        cursor.exec(query_jsx_tags, root_node);
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
    }

    return null;
}

fn trimComment(comment_raw: []const u8) []const u8 {
    if (std.mem.startsWith(u8, comment_raw, "/*")) {
        // remove leading "/* **" and trailing "** */"
        return std.mem.trim(
            u8,
            std.mem.trim(
                u8,
                std.mem.cutPrefix(
                    u8,
                    std.mem.cutSuffix(u8, comment_raw, "*/").?,
                    "/*",
                ).?,
                "*",
            ),
            " \t",
        );
    } else if (std.mem.startsWith(u8, comment_raw, "//")) {
        return std.mem.trim(
            u8,
            std.mem.cutPrefix(u8, comment_raw, "//").?,
            " \t",
        );
    } else return "";
}
