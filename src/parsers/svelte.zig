const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const Parser = @import("Parser.zig");
const html = @import("html.zig");

const log = std.log.scoped(.caniuse_ls);

extern fn tree_sitter_svelte() callconv(.c) *ts.Language;
var lang_svelte: *ts.Language = undefined;

pub fn SvelteParser() Parser {
    return .{
        .init = init,
        .deinit = deinit,
        .parse = parse,
        .getHoverDocAtPosition = getHoverDocAtPosition,
    };
}

fn init() void {
    lang_svelte = tree_sitter_svelte();
}
fn deinit() void {
    lang_svelte.destroy();
}
fn parse(
    allocator: std.mem.Allocator,
    code: []const u8,
    start_column: u32,
    start_row: u32,
) []const lsp.types.Diagnostic {
    return html.parseHtmlAndReturnDiagnostics(
        allocator,
        code,
        start_column,
        start_row,
        lang_svelte,
    );
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
