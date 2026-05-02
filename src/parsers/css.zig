const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const Parser = @import("Parser.zig");

const log = std.log.scoped(.caniuse_ls);

extern fn tree_sitter_css() callconv(.c) *ts.Language;
var lang_css: *ts.Language = undefined;

pub fn CssParser() Parser {
    return .{
        .init = init,
        .deinit = deinit,
        .parse = parse,
    };
}

fn init() void {
    lang_css = tree_sitter_css();
}
fn deinit() void {
    lang_css.destroy();
}
fn parse(allocator: std.mem.Allocator, code: []const u8) []const lsp.types.Diagnostic {
    log.info("parsing css", .{});
    const QUERY =
        \\(property_name) @propname
    ;

    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(lang_css) catch return &.{};

    var diagnostics: std.ArrayList(lsp.types.Diagnostic) = .empty;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();

        const root_node = ast.rootNode();

        var error_offset: u32 = 0;
        const query = ts.Query.create(lang_css, QUERY, &error_offset) catch return &.{};
        defer query.destroy();

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();
        cursor.exec(query, root_node);

        while (cursor.nextMatch()) |match| {
            const prop_node = match.captures[0].node;
            const prop_name = code[prop_node.startByte()..prop_node.endByte()];
            log.info("prop_name: {s}", .{prop_name});

            // send diagnostic on <geolocation> element
            if (std.mem.eql(u8, prop_name, "ime-mode")) {
                diagnostics.append(
                    allocator,
                    .{
                        .range = .{
                            .start = .{
                                .character = prop_node.startPoint().column,
                                .line = prop_node.startPoint().row,
                            },
                            .end = .{
                                .character = prop_node.endPoint().column,
                                .line = prop_node.endPoint().row,
                            },
                        },
                        .message = "This property only has 2.56% global support on caniuse.com",
                        .severity = .Warning,
                    },
                ) catch return &.{};
            }
        }
    }

    return diagnostics.items;
}
