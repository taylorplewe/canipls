const std = @import("std");
const lsp = @import("lsp");

const bins = @import("parsers/bins.zig");

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

pub const TsNodeKind = enum {
    HtmlTag,
    HtmlAttribute,
    HtmlStringLiteral,

    CssProperty,
    CssAtRule,
    CssSelector,
    CssTagName,
    CssPlainValue,
    CssMediaStatement,
    CssSupportsStatement,
    CssImportStatement,
    CssFeatureName,
    CssUniversalSelector, // "*"

    JsIdentifier,
    JsPropertyIdentifier,
    JsPrototypePropertyIdentifier,
};

// TODO: possibly delete these idk if I need them
// pub const ts_node_kind_str_to_enum_html: std.StaticStringMap(TsNodeKind) = .initComptime(.{
//     .{ "tag_name", .HtmlTag },
//     .{ "attribute_name", .HtmlTag },
//     .{ "attribute_value", .HtmlStringLiteral },
// });

// pub const ts_node_kind_str_to_enum_css: std.StaticStringMap(TsNodeKind) = .initComptime(.{
//     .{ "property_name", .CssProperty },
//     .{ "at_keyword", .CssAtRule },
//     .{ "tag_name", .HtmlTag },
// });

pub const SymbolInfo = struct {
    ts_query_text: []const u8,
    support_bin: *const bins.Bin,
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
