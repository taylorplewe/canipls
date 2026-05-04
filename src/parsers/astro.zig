const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const Parser = @import("Parser.zig");
const html = @import("html.zig");
const js = @import("js.zig");

const log = std.log.scoped(.caniuse_ls);

extern fn tree_sitter_astro() callconv(.c) *ts.Language;
var lang_astro: *ts.Language = undefined;

pub fn AstroParser() Parser {
    return .{
        .init = init,
        .deinit = deinit,
        .parse = parse,
    };
}

fn init() void {
    lang_astro = tree_sitter_astro();
}
fn deinit() void {
    lang_astro.destroy();
}
fn parse(
    allocator: std.mem.Allocator,
    code: []const u8,
    start_column: u32,
    start_row: u32,
) []const lsp.types.Diagnostic {
    const html_diagnostics = html.parseHtmlAndReturnDiagnostics(
        allocator,
        code,
        start_column,
        start_row,
        lang_astro,
    );

    const QUERY_FRONTMATTER_JS = "(frontmatter (frontmatter_js_block) @js)";

    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(lang_astro) catch return &.{};

    var diagnostics: std.ArrayList(lsp.types.Diagnostic) = .fromOwnedSlice(@constCast(html_diagnostics));

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();

        const node = ast.rootNode();

        var error_offset: u32 = 0;
        const query_frontmatter_js = ts.Query.create(lang_astro, QUERY_FRONTMATTER_JS, &error_offset) catch return &.{};
        defer query_frontmatter_js.destroy();

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        // script (JS) blocks
        cursor.exec(query_frontmatter_js, node);
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
