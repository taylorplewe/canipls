const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const types = @import("../types.zig");
const HoverInfo = types.HoverInfo;
const Parser = @import("Parser.zig");

const log = std.log.scoped(.caniuse_ls);

extern fn tree_sitter_javascript() callconv(.c) *ts.Language;
var lang_javascript: *ts.Language = undefined;
const js_identifiers_bin: []const u8 = @embedFile("js_identifiers.bin"); // TEMP

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

            // search bin files here!!
            // TEMP: just open the file here for now lmao
            const num_features_in_bin = std.mem.readInt(u32, js_identifiers_bin[0..4], .little);
            // search for feature
            var identifier_buf: [32]u8 = undefined;
            @memset(&identifier_buf, 0);
            _ = std.fmt.bufPrint(&identifier_buf, "{s}", .{identifier_name}) catch return diagnostics.items;
            log.info("identifier buf: {s}", .{identifier_buf});
            var next_name_start = (num_features_in_bin * @sizeOf(f32)) + @sizeOf(u32);
            for (0..num_features_in_bin) |i| {
                _ = i; // autofix
                const name = js_identifiers_bin[next_name_start..][0..32];
                if (std.mem.eql(u8, &identifier_buf, name)) {
                    log.info("found!", .{});
                    break;
                }
                next_name_start += 32;
            }

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

fn getHoverInfoAtPosition(
    code: []const u8,
    column: u32,
    row: u32,
) ?HoverInfo {
    _ = code; // autofix
    _ = column; // autofix
    _ = row; // autofix

    return null;
}
