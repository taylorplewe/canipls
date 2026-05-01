const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const types = @import("types.zig");

extern fn tree_sitter_html() callconv(.c) *ts.Language;

const log = std.log.scoped(.caniuse_ls);

var lang_html: *ts.Language = undefined;

pub fn init() void {
    lang_html = tree_sitter_html();
}

pub fn deinit() void {
    lang_html.destroy();
}

const START_TAG_NAME_AND_ATTRS_QUERY =
    \\(start_tag
    \\  (tag_name) @tagname
    \\  (attribute
    \\    (attribute_name) @attrname
    \\  )*
    \\)
;

/// TEMP: only parses HTML for now
pub fn parseCodeAndGetDiagnostics(allocator: std.mem.Allocator, code: []const u8) ![]const lsp.types.Diagnostic {
    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(lang_html);

    var diagnostics: std.ArrayList(lsp.types.Diagnostic) = .empty;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();

        const node = ast.rootNode();

        var error_offset: u32 = 0;
        const query = try ts.Query.create(lang_html, START_TAG_NAME_AND_ATTRS_QUERY, &error_offset);
        defer query.destroy();

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();
        cursor.exec(query, node);

        while (cursor.nextMatch()) |match| {
            const tag_node = match.captures[0].node;
            const tag_name = code[tag_node.startByte()..tag_node.endByte()];
            log.info("tag name: {s:<16}", .{tag_name});

            if (std.mem.eql(u8, tag_name, "geolocation")) {
                try diagnostics.append(
                    allocator,
                    .{
                        .range = .{
                            .start = .{
                                .character = tag_node.startPoint().column,
                                .line = tag_node.startPoint().row,
                            },
                            .end = .{
                                .character = tag_node.endPoint().column,
                                .line = tag_node.endPoint().row,
                            },
                        },
                        .message = "uh oh u cant use geolocation lmaoooo",
                    },
                );
            }
        }
    }

    return diagnostics.items;
}
