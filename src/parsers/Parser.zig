//! Interface for each language tree-sitter parser to implement
const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const log = std.log.scoped(.caniuse_ls);

init: *const fn () void,
deinit: *const fn () void,
parse: *const fn (
    allocator: std.mem.Allocator,
    code: []const u8,
    start_column: u32,
    start_row: u32,
) []const lsp.types.Diagnostic,

const ElementKind = enum {
    HtmlElement,
    HtmlAttribute,
    CssProp,
    CssAtRule,
    CssPseudoElementSelector,
    CssPseudoClassSelector,
    JsApi,

    fn getWord(self: ElementKind) []const u8 {
        return switch (self) {
            .HtmlElement => "element",
            .HtmlAttribute => "attribute",
            .CssProp => "property",
            .CssAtRule => "at-rule",
            .CssPseudoElementSelector => "pseudo element selector",
            .CssPseudoClassSelector => "pseudo class selector",
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
