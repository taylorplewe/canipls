const std = @import("std");
const lsp = @import("lsp");

pub const ElementKind = enum {
    HtmlElement,
    HtmlAttribute,
    CssProp,
    CssAtRule,
    CssSelector,
    JsApi,

    pub fn getWord(self: ElementKind) []const u8 {
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

/// Internal type representing all necessary information to build an LSP `Hover` instance
pub const HoverInfo = struct {
    /// The actual textual representation of the hovered symbol
    identifier: []const u8,
    /// Global support % according to caniuse.com
    support_percentage: f32,
    /// This gets appended to "https://caniuse.com/mdn-" to form a visitable link
    caniuse_id: []const u8,
};

/// Represents a span in the code where no diagnostics should be published
pub const IgnoredSpan = union(enum) {
    region: struct {
        row_start: usize,
        row_end: usize,
    },
    row: usize,
};

pub const SymbolInfo = struct {
    ts_query_text: []const u8,
    support_bin: []const u8,
    element_kind: ElementKind,
    name_trim_start: usize = 0,
};
pub const InjectionParseInfo = struct {
    ts_query_text: []const u8,
    injection_parse_fn: *const fn (
        allocator: std.mem.Allocator,
        code: []const u8,
        code_offset_column: u32,
        code_offset_row: u32,
    ) []const lsp.types.Diagnostic,
};
pub const InjectionHoverInfo = struct {
    ts_query_text: []const u8,
    injection_hover_fn: *const fn (
        code: []const u8,
        code_offset_column: u32,
        code_offset_row: u32,
    ) ?HoverInfo,
};
