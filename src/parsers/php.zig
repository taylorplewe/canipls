const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const types = @import("../types.zig");
const HoverInfo = types.HoverInfo;
const Parser = @import("Parser.zig");
const html = @import("html.zig");

const log = std.log.scoped(.canipls);

extern fn tree_sitter_php() callconv(.c) *ts.Language;
var lang_php: *ts.Language = undefined;

pub fn PhpParser() Parser {
    return .{
        .init = init,
        .deinit = deinit,
        .parse = parse,
        .getHoverInfoAtPosition = getHoverInfoAtPosition,
    };
}

fn init() void {
    lang_php = tree_sitter_php();
}
fn deinit() void {
    lang_php.destroy();
}

const QUERY_HTML_TEXT = "(text) @html";

fn parse(
    allocator: std.mem.Allocator,
    code: []const u8,
    start_column: u32,
    start_row: u32,
) []const lsp.types.Diagnostic {
    const injections = [_]types.InjectionParseInfo{
        .{
            .injectionParseFn = html.HtmlParser().parse,
            .ts_query_text = QUERY_HTML_TEXT,
        },
    };

    return Parser.getDiagnosticsFromCode(
        allocator,
        lang_php,
        code,
        start_column,
        start_row,
        trimComment,
        &.{},
        &injections,
    ) catch |err| {
        log.err("could not get diagnostics for PHP code: {}", .{err});
        return &.{};
    };
}

pub fn trimComment(_: []const u8) []const u8 {}

fn getHoverInfoAtPosition(
    temp_allocator: std.mem.Allocator,
    code: []const u8,
    column: u32,
    row: u32,
) ?HoverInfo {
    const injections = [_]types.InjectionParseInfo{
        .{
            .injectionParseFn = html.HtmlParser().parse,
            .ts_query_text = QUERY_HTML_TEXT,
        },
    };

    return Parser.getHoverInfoFromCodeAtPosition(
        temp_allocator,
        lang_php,
        code,
        column,
        row,
        &.{},
        &injections,
    ) catch |err| {
        log.err("encountered error retrieving hover doc in PHP code: {}", .{err});
        return &.{};
    };
}
