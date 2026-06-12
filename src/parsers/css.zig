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

const AtRulesContext = struct {
    const QUERY =
        \\(stylesheet
        \\  (at_rule
        \\    (at_keyword) @rule
        \\    _*
        \\    (block
        \\      [
        \\        (declaration
        \\          (property_name) @propname
        \\        )
        \\        (at_rule
        \\          (at_keyword) @rule
        \\        )
        \\        _
        \\      ]*
        \\    )
        \\  )
        \\)
    ;
    var at_rule_name: ?[]const u8 = null;
    pub fn callback(
        node: *const ts.Node,
        is_first_node: bool,
        // TODO: I hate that this is here
        c: []const u8,
        // TODO: I hate that this is here
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
    const QUERY =
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
    const QUERY =
        \\(
        \\  (property_name) @propname
        \\  [
        \\    (plain_value) @val
        \\    (call_expression) @val
        \\    _
        \\  ]*
        \\)
    ;

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

fn parse(
    allocator: std.mem.Allocator,
    code: []const u8,
    start_column: u32,
    start_row: u32,
) []const lsp.types.Diagnostic {
    return Parser.getDiagnosticsFromCode(
        allocator,
        lang_css,
        code,
        start_column,
        start_row,
        trimComment,
        &.{
            .{
                .ts_query_text = AtRulesContext.QUERY,
                .perNodeCallback = AtRulesContext.callback,
            },
            .{
                .ts_query_text = PropertiesContext.QUERY,
                .perNodeCallback = PropertiesContext.callback,
            },
            .{
                .ts_query_text = SelectorsContext.QUERY,
                .perNodeCallback = SelectorsContext.callback,
            },
        },
        &.{},
    ) catch |err| {
        log.err("could not get diagnostics for CSS code: {}", .{err});
        return &.{};
    };
}

fn getHoverInfoAtPosition(
    temp_allocator: std.mem.Allocator,
    code: []const u8,
    column: u32,
    row: u32,
) ?HoverInfo {
    return Parser.getHoverInfoFromCodeAtPosition(
        temp_allocator,
        lang_css,
        code,
        column,
        row,
        &.{
            .{
                .ts_query_text = AtRulesContext.QUERY,
                .perNodeCallback = AtRulesContext.callback,
            },
            .{
                .ts_query_text = PropertiesContext.QUERY,
                .perNodeCallback = PropertiesContext.callback,
            },
            .{
                .ts_query_text = SelectorsContext.QUERY,
                .perNodeCallback = SelectorsContext.callback,
            },
        },
        &.{},
    ) catch |err| {
        log.err("encountered error retrieving hover doc in CSS code: {}", .{err});
        return null;
    };
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
