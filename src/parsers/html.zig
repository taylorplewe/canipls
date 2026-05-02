const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const Parser = @import("Parser.zig");

extern fn tree_sitter_html() callconv(.c) *ts.Language;
var lang_html: *ts.Language = undefined;

pub fn HtmlParser() Parser {
    return .{
        .init = init,
        .deinit = deinit,
        .parse = parse,
    };
}

fn init() void {
    lang_html = tree_sitter_html();
}
fn deinit() void {
    lang_html.destroy();
}
fn parse(allocator: std.mem.Allocator, code: []const u8) []const lsp.types.Diagnostic {
    const START_TAG_NAME_AND_ATTRS_QUERY =
        \\(start_tag
        \\  (tag_name) @tagname
        \\  (attribute
        \\    (attribute_name) @attrname
        \\  )*
        \\)
    ;

    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(lang_html) catch return &.{};

    var diagnostics: std.ArrayList(lsp.types.Diagnostic) = .empty;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();

        const node = ast.rootNode();

        var error_offset: u32 = 0;
        const query = ts.Query.create(lang_html, START_TAG_NAME_AND_ATTRS_QUERY, &error_offset) catch return &.{};
        defer query.destroy();

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();
        cursor.exec(query, node);

        while (cursor.nextMatch()) |match| {
            const tag_node = match.captures[0].node;
            const tag_name = code[tag_node.startByte()..tag_node.endByte()];

            // send diagnostic on <geolocation> element
            if (std.mem.eql(u8, tag_name, "geolocation")) {
                diagnostics.append(
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
                        .message = "This element only has 75.86% global support on caniuse.com",
                        .severity = .Warning,
                    },
                ) catch return &.{};
            }

            for (match.captures[1..]) |capture| {
                const attr_node = capture.node;
                const attr_name = code[attr_node.startByte()..attr_node.endByte()];

                // send diagnostic on "virtualkeyboardpolicy" attribute
                if (std.mem.eql(u8, attr_name, "virtualkeyboardpolicy")) {
                    diagnostics.append(
                        allocator,
                        .{
                            .range = .{
                                .start = .{
                                    .character = attr_node.startPoint().column,
                                    .line = attr_node.startPoint().row,
                                },
                                .end = .{
                                    .character = attr_node.endPoint().column,
                                    .line = attr_node.endPoint().row,
                                },
                            },
                            .message = "This attribute only has 75.86% global support on caniuse.com",
                            .severity = .Warning,
                        },
                    ) catch return &.{};
                }
            }
        }
    }

    return diagnostics.items;
}
