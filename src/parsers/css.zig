const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const types = @import("../types.zig");
const HoverInfo = types.HoverInfo;
const IgnoredSpan = types.IgnoredSpan;
const Parser = @import("Parser.zig");
const bins = @import("bins.zig");
const config = @import("../config.zig");

const log = std.log.scoped(.canipls);

extern fn tree_sitter_css() callconv(.c) *ts.Language;
var lang_css: *ts.Language = undefined;

pub fn CssParser() Parser {
    return .{
        .init = init,
        .deinit = deinit,
        .parse = parse,
        .getHoverInfoAtPosition = getHoverInfoAtPosition,
    };
}

fn init() void {
    lang_css = tree_sitter_css();
}
fn deinit() void {
    lang_css.destroy();
}
const node_kind_str_to_enum = std.StaticStringMap(types.TsNodeKind).initComptime(.{
    .{ "plain_value", types.TsNodeKind.CssPlainValue },
    .{ "call_expression", types.TsNodeKind.CssCallExpression },
    .{ "property_name", types.TsNodeKind.CssProperty },
    .{ "at_keyword", types.TsNodeKind.CssAtRule },
    .{ "tag_name", types.TsNodeKind.CssTagName },
    .{ "universal_selector", types.TsNodeKind.CssUniversalSelector },
});
fn parse(
    allocator: std.mem.Allocator,
    code: []const u8,
    start_column: u32,
    start_row: u32,
) []const lsp.types.Diagnostic {
    const QUERY_AT_RULES =
        \\(
        \\  (at_keyword) @rule
        \\  _*
        \\  (block
        \\    [
        \\      (declaration
        \\        (property_name) @propname
        \\      )
        \\      (at_rule
        \\        (at_keyword) @rule
        \\      )
        \\      _
        \\    ]*
        \\  )
        \\)
    ;

    const QUERY_PROPERTIES =
        \\(
        \\  (property_name) @propname
        \\  [
        \\    (plain_value) @val
        \\    (call_expression) @val
        \\    _
        \\  ]*
        \\)
    ;

    const QUERY_SELECTORS =
        \\(
        \\  (selectors
        \\    (_
        \\      [
        \\        (tag_name) @tagname
        \\        (class_name) @classname
        \\      ]
        \\      (arguments
        \\        [
        \\          (tag_name) @tagname
        \\          (universal_selector) @star
        \\        ]
        \\      )
        \\    )
        \\  )
        \\  (block
        \\    (declaration (property_name) @propname)*
        \\  )?
        \\)
    ;

    const AtRulesContext = struct {
        var at_rule_name: ?[]const u8 = null;
        pub fn callback(
            node: *const ts.Node,
            is_first_node: bool,
            c: []const u8,
            a: std.mem.Allocator,
        ) std.mem.Allocator.Error![]const []const bins.BinSearchSymbolInfo {
            const start_index: usize = if (is_first_node or std.mem.eql(u8, node.kind(), "at_keyword")) 1 else 0;
            const name = c[node.startByte() + start_index .. node.endByte()];
            if (is_first_node) {
                at_rule_name = name;
                return try a.dupe([]const bins.BinSearchSymbolInfo, &.{
                    try a.dupe(bins.BinSearchSymbolInfo, &.{
                        .{ .name = name, .node_kind = .CssAtRule },
                    }),
                });
            }

            const node_kind = node_kind_str_to_enum.get(node.kind()) orelse return &.{};
            return try a.dupe([]const bins.BinSearchSymbolInfo, &.{
                try a.dupe(bins.BinSearchSymbolInfo, &.{
                    .{ .name = at_rule_name.?, .node_kind = .CssAtRule },
                    .{ .name = name, .node_kind = node_kind },
                }),
            });
        }
    };

    const SelectorsContext = struct {
        var selector_name: ?[]const u8 = null;
        pub fn callback(
            node: *const ts.Node,
            is_first_node: bool,
            c: []const u8,
            a: std.mem.Allocator,
        ) std.mem.Allocator.Error![]const []const bins.BinSearchSymbolInfo {
            const name = if (!is_first_node and node_kind_str_to_enum.get(node.kind()) == types.TsNodeKind.CssUniversalSelector)
                "star"
            else
                c[node.startByte()..node.endByte()];

            if (is_first_node) {
                selector_name = name;
                return try a.dupe([]const bins.BinSearchSymbolInfo, &.{
                    try a.dupe(bins.BinSearchSymbolInfo, &.{
                        .{ .name = name, .node_kind = .CssSelector },
                    }),
                });
            }

            const node_kind = node_kind_str_to_enum.get(node.kind()) orelse return &.{};
            return try a.dupe([]const bins.BinSearchSymbolInfo, &.{
                try a.dupe(bins.BinSearchSymbolInfo, &.{
                    .{ .name = selector_name.?, .node_kind = .CssSelector },
                    .{ .name = name, .node_kind = node_kind },
                }),
            });
        }
    };

    const PropertiesContext = struct {
        var property_name: ?[]const u8 = null;
        pub fn callback(
            node: *const ts.Node,
            is_first_node: bool,
            c: []const u8,
            a: std.mem.Allocator,
        ) std.mem.Allocator.Error![]const []const bins.BinSearchSymbolInfo {
            const name = c[node.startByte()..node.endByte()];

            if (is_first_node) {
                property_name = name;
                return try a.dupe([]const bins.BinSearchSymbolInfo, &.{
                    try a.dupe(bins.BinSearchSymbolInfo, &.{
                        .{ .name = name, .node_kind = .CssProperty },
                    }),
                });
            }

            const node_kind = node_kind_str_to_enum.get(node.kind()) orelse return &.{};
            return try a.dupe([]const bins.BinSearchSymbolInfo, &.{
                try a.dupe(bins.BinSearchSymbolInfo, &.{
                    .{ .name = property_name.?, .node_kind = .CssProperty },
                    .{ .name = name, .node_kind = node_kind },
                }),
            });
        }
    };

    return Parser.processCode(
        allocator,
        lang_css,
        code,
        start_column,
        start_row,
        trimComment,
        &.{
            .{
                .ts_query_text = QUERY_AT_RULES,
                .perNodeCallback = AtRulesContext.callback,
            },
            .{
                .ts_query_text = QUERY_PROPERTIES,
                .perNodeCallback = PropertiesContext.callback,
            },
            .{
                .ts_query_text = QUERY_SELECTORS,
                .perNodeCallback = SelectorsContext.callback,
            },
        },
        &.{},
        .Diagnostics,
    );
}

fn getHoverInfoAtPosition(
    code: []const u8,
    column: u32,
    row: u32,
) ?HoverInfo {
    _ = code; // autofix
    _ = column; // autofix
    _ = row; // autofix
    // const QUERY_PROPS = "(property_name) @propname";
    // const QUERY_AT_RULES = "(at_keyword) @atrule";
    // const QUERY_PSEUDO_ELEMENT_SELECTORS = "(pseudo_element_selector (tag_name) @pseudoelementname)";
    // const QUERY_PSEUDO_CLASS_SELECTORS = "(pseudo_class_selector (class_name) @pseudoelementname)";

    // const symbols = [_]types.SymbolInfo{
    //     .{
    //         .element_kind = .CssProp,
    //         .support_bin = bins.bin_map.getPtrConstAssertContains(.CssProperty),
    //         .ts_query_text = QUERY_PROPS,
    //     },
    //     .{
    //         .element_kind = .CssAtRule,
    //         .support_bin = bins.bin_map.getPtrConstAssertContains(.CssAtRule),
    //         .ts_query_text = QUERY_AT_RULES,
    //         .name_trim_start = 1,
    //     },
    //     .{
    //         .element_kind = .CssSelector,
    //         .support_bin = bins.bin_map.getPtrConstAssertContains(.CssSelector),
    //         .ts_query_text = QUERY_PSEUDO_CLASS_SELECTORS,
    //     },
    //     .{
    //         .element_kind = .CssSelector,
    //         .support_bin = bins.bin_map.getPtrConstAssertContains(.CssSelector),
    //         .ts_query_text = QUERY_PSEUDO_ELEMENT_SELECTORS,
    //     },
    // };

    // return Parser.getHoverDocFromCodeAtPosition(
    //     lang_css,
    //     code,
    //     column,
    //     row,
    //     &symbols,
    //     &.{},
    // );
    return null;
}
fn trimComment(comment_raw: []const u8) []const u8 {
    return std.mem.trim(
        u8,
        std.mem.trim(
            u8,
            std.mem.cutPrefix(
                u8,
                std.mem.cutSuffix(u8, comment_raw, "*/").?,
                "/*",
            ).?,
            "*",
        ),
        " \t",
    );
}
