const std = @import("std");
const lsp = @import("lsp");

const bins = @import("parsers/bins.zig");

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

/// NOTE: the members of this enum must match exactly those of the `TsNodeKind` enum in `parse-bcd-json.cpp`
pub const TsNodeKind = enum {
    HtmlTag,
    HtmlAttribute,
    HtmlStringLiteral,

    CssProperty,
    CssAtRule,
    CssSelector,
    CssTagName,
    CssPlainValue,
    CssCallExpression,
    CssMediaStatement,
    CssSupportsStatement,
    CssImportStatement,
    CssFeatureName,
    CssUniversalSelector, // "*"

    JsIdentifier,
    JsPropertyIdentifier,
    JsPrototypePropertyIdentifier,

    pub fn getDisplayName(self: TsNodeKind) []const u8 {
        return switch (self) {
            .HtmlTag => "element",
            .HtmlAttribute => "attribute",
            .HtmlStringLiteral => "attribute value",
            .CssProperty => "property",
            .CssPlainValue => "property value",
            .CssAtRule => "at-rule",
            .CssSelector => "selector",
            .JsIdentifier => "API",
            else => "feature",
        };
    }
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
    node_kind: TsNodeKind,
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
