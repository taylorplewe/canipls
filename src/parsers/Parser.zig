//! Interface for each language tree-sitter parser to implement

const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const types = @import("../types.zig");
const HoverInfo = types.HoverInfo;
const log = std.log.scoped(.canipls);

const BIN_FILE_STRING_WIDTH = 32;
const THRESHOLD = 90.0; // TEMP

init: *const fn (io: std.Io) void,
deinit: *const fn () void,
parse: *const fn (
    allocator: std.mem.Allocator,
    code: []const u8,
    start_column: u32,
    start_row: u32,
) []const lsp.types.Diagnostic,
getHoverInfoAtPosition: *const fn (
    code: []const u8,
    column: u32,
    row: u32,
) ?HoverInfo,

const ElementKind = enum {
    HtmlElement,
    HtmlAttribute,
    CssProp,
    CssAtRule,
    CssSelector,
    JsApi,

    fn getWord(self: ElementKind) []const u8 {
        return switch (self) {
            .HtmlElement => "element",
            .HtmlAttribute => "attribute",
            .CssProp => "property",
            .CssAtRule => "at-rule",
            .CssSelector => "selector",
            .JsApi => "API",
        };
    }
};

pub fn getLspDiagnosticFromTsNode(
    allocator: std.mem.Allocator,
    node: *const ts.Node,
    element_kind: ElementKind,
    global_support_percentage: f32,
    start_column: u32,
    start_row: u32,
) lsp.types.Diagnostic {
    const column_to_add = if (node.startPoint().row == 0) start_column else 0;
    return .{
        .range = .{
            .start = .{ .character = node.startPoint().column + column_to_add, .line = node.startPoint().row + start_row },
            .end = .{ .character = node.endPoint().column + column_to_add, .line = node.endPoint().row + start_row },
        },
        .message = getDiagnosticPhraseFromElement(
            allocator,
            element_kind,
            global_support_percentage,
        ),
        .severity = .Warning,
    };
}
fn getDiagnosticPhraseFromElement(allocator: std.mem.Allocator, element_kind: ElementKind, global_support_percentage: f32) []u8 {
    const kind_word = element_kind.getWord();
    return std.fmt.allocPrint(
        allocator,
        "This {s} only has {d:.2}% global support on caniuse.com",
        .{ kind_word, global_support_percentage },
    ) catch |err| {
        log.err("could not allocPrint diagnostic message: {}", .{err});
        return "";
    };
}
var identifier_buf: [32]u8 = undefined;
pub fn getSupportPercentageForIdentifierFromBin(
    identifier_name: []const u8,
    bin: []const u8,
) ?f32 {
    const num_features_in_bin = std.mem.readInt(u32, bin[0..4], .little);

    // make identifier name in question 32-chars wide, padded with 0's
    @memcpy(identifier_buf[0..identifier_name.len], identifier_name);
    @memset(identifier_buf[identifier_name.len..], 0);

    // search for feature
    var next_name_offset = (num_features_in_bin * @sizeOf(f32)) + @sizeOf(u32);
    for (0..num_features_in_bin) |i| {
        const name = bin[next_name_offset..][0..BIN_FILE_STRING_WIDTH];
        if (std.mem.eql(u8, &identifier_buf, name)) {
            const support_percentage_offset = (@sizeOf(f32) * i) + @sizeOf(u32);
            const support_percentage: *f32 = @ptrCast(@alignCast(@constCast(bin[support_percentage_offset..][0..4])));
            return support_percentage.*;
        }
        next_name_offset += BIN_FILE_STRING_WIDTH;
    }
    return null;
}
