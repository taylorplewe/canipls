const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const utils = @import("../utils.zig");
const config = @import("../config.zig");
const types = @import("../types.zig");
const HoverInfo = types.HoverInfo;
const IgnoredSpan = types.IgnoredSpan;
const Parser = @import("Parser.zig");
const css = @import("css.zig");
const js = @import("js.zig");
const bins = @import("bins.zig");

const log = std.log.scoped(.canipls);

extern fn tree_sitter_html() callconv(.c) *ts.Language;
var lang_html: *ts.Language = undefined;

pub fn HtmlParser() Parser {
    return .{
        .init = init,
        .deinit = deinit,
        .parse = parse,
        .getHoverInfoAtPosition = getHoverInfoAtPosition,
    };
}

fn init() void {
    lang_html = tree_sitter_html();
}
fn deinit() void {
    lang_html.destroy();
}
fn parse(
    allocator: std.mem.Allocator,
    code: []const u8,
    start_column: u32,
    start_row: u32,
) []const lsp.types.Diagnostic {
    return parseHtmlAndReturnDiagnostics(
        allocator,
        code,
        start_column,
        start_row,
        lang_html,
    );
}

// TEMP
const BinSection = enum {
    Support,
    CiuIdAddr,
    Reserved,
    FirstChildIndex,
    NumChildren,
    TreeSitterSyntaxNodeType,
    Identifier,
};
var sizeof_entry_per_bin_section = std.EnumArray(BinSection, usize).init(.{
    .Support = @sizeOf(f32),
    .CiuIdAddr = @sizeOf(u32),
    .Reserved = @sizeOf(u32),
    .FirstChildIndex = @sizeOf(u32),
    .NumChildren = @sizeOf(u16),
    .TreeSitterSyntaxNodeType = @sizeOf(u8),
    .Identifier = 32,
});
var identifier_buf: [32]u8 = undefined;

pub const TagsAndAttrsContext = struct {
    var last_attr_name: ?[]const u8 = null;
    var tag_name: ?[]const u8 = null;
    pub const QUERY_DIAGNOSTICS =
        \\[
        \\  (start_tag
        \\    (tag_name) @tagname
        \\    (attribute
        \\      (attribute_name) @attrname
        \\      (quoted_attribute_value
        \\        (attribute_value) @attrval
        \\      )?
        \\    )*
        \\  )
        \\  (self_closing_tag
        \\    (tag_name) @tagname
        \\    (attribute
        \\      (attribute_name) @attrname
        \\      (quoted_attribute_value
        \\        (attribute_value) @attrval
        \\      )?
        \\    )*
        \\  )
        \\]
    ;
    pub const QUERY_HOVER =
        \\(
        \\  (tag_name) @tagname
        \\  (attribute
        \\    (attribute_name) @attrname
        \\    (quoted_attribute_value
        \\      (attribute_value) @attrval
        \\    )?
        \\  )*
        \\)
    ;

    pub fn callback(
        node: *const ts.Node,
        is_first_node: bool,
        c: []const u8,
        a: std.mem.Allocator,
    ) std.mem.Allocator.Error![]const []const bins.BinSearchSymbolInfo {
        const name = c[node.startByte()..node.endByte()];

        if (is_first_node) {
            tag_name = name;
            return try a.dupe([]const bins.BinSearchSymbolInfo, &.{
                try a.dupe(bins.BinSearchSymbolInfo, &.{
                    .{ .name = name, .node_kind = .HtmlTag },
                }),
            });
        } else if (last_attr_name != null and std.mem.eql(u8, node.kind(), "attribute_value")) {
            return try a.dupe([]const bins.BinSearchSymbolInfo, &.{
                try a.dupe(bins.BinSearchSymbolInfo, &.{
                    .{ .name = last_attr_name.?, .node_kind = .HtmlAttribute },
                    .{ .name = name, .node_kind = .HtmlStringLiteral },
                }),
                try a.dupe(bins.BinSearchSymbolInfo, &.{
                    .{ .name = tag_name.?, .node_kind = .HtmlTag },
                    .{ .name = last_attr_name.?, .node_kind = .HtmlAttribute },
                    .{ .name = name, .node_kind = .HtmlStringLiteral },
                }),
            });
        } else {
            last_attr_name = name;
            return try a.dupe([]const bins.BinSearchSymbolInfo, &.{
                try a.dupe(bins.BinSearchSymbolInfo, &.{
                    .{ .name = name, .node_kind = .HtmlAttribute },
                }),
                try a.dupe(bins.BinSearchSymbolInfo, &.{
                    .{ .name = tag_name.?, .node_kind = .HtmlTag },
                    .{ .name = name, .node_kind = .HtmlAttribute },
                }),
            });
        }
    }
};

const QUERY_STYLE_BLOCKS = "(style_element (raw_text) @css)";
const QUERY_SCRIPT_BLOCKS = "(script_element (raw_text) @js)";

pub fn parseHtmlAndReturnDiagnostics(
    allocator: std.mem.Allocator,
    code: []const u8,
    start_column: u32,
    start_row: u32,
    lang: *ts.Language,
) []const lsp.types.Diagnostic {
    const injections = [_]types.InjectionParseInfo{
        .{
            .injectionParseFn = js.JavascriptParser().parse,
            .ts_query_text = QUERY_SCRIPT_BLOCKS,
        },
        .{
            .injectionParseFn = css.CssParser().parse,
            .ts_query_text = QUERY_STYLE_BLOCKS,
        },
    };

    return Parser.getDiagnosticsFromCode(
        allocator,
        lang,
        code,
        start_column,
        start_row,
        trimComment,
        &.{
            .{
                .ts_query_text = TagsAndAttrsContext.QUERY_DIAGNOSTICS,
                .perNodeCallback = TagsAndAttrsContext.callback,
            },
        },
        &injections,
    ) catch |err| {
        log.err("could not get diagnostics for HTML code: {}", .{err});
        return &.{};
    };
}

pub fn trimComment(in: []const u8) []const u8 {
    return std.mem.trim(
        u8,
        std.mem.cutPrefix(
            u8,
            std.mem.cutSuffix(u8, in, "-->").?,
            "<!--",
        ).?,
        " \t",
    );
}

pub fn getHoverInfoFromHtmlAtPosition(
    temp_allocator: std.mem.Allocator,
    code: []const u8,
    column: u32,
    row: u32,
    lang: *ts.Language,
) ?HoverInfo {
    const injections = [_]types.InjectionHoverInfo{
        .{
            .injectionHoverFn = js.JavascriptParser().getHoverInfoAtPosition,
            .ts_query_text = QUERY_SCRIPT_BLOCKS,
        },
        .{
            .injectionHoverFn = css.CssParser().getHoverInfoAtPosition,
            .ts_query_text = QUERY_STYLE_BLOCKS,
        },
    };

    return Parser.getHoverInfoFromCodeAtPosition(
        temp_allocator,
        lang,
        code,
        column,
        row,
        &.{
            .{
                .ts_query_text = TagsAndAttrsContext.QUERY_HOVER,
                .perNodeCallback = TagsAndAttrsContext.callback,
            },
        },
        &injections,
    ) catch |err| {
        log.err("encountered error retrieving hover doc: {}", .{err});
        return null;
    };
}

fn getHoverInfoAtPosition(
    temp_allocator: std.mem.Allocator,
    code: []const u8,
    column: u32,
    row: u32,
) ?HoverInfo {
    return getHoverInfoFromHtmlAtPosition(
        temp_allocator,
        code,
        column,
        row,
        lang_html,
    );
}
