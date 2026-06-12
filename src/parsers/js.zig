const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const config = @import("../config.zig");
const types = @import("../types.zig");
const HoverInfo = types.HoverInfo;
const IgnoredSpan = types.IgnoredSpan;
const Parser = @import("Parser.zig");
const html = @import("html.zig");
const bins = @import("bins.zig");

const log = std.log.scoped(.canipls);

extern fn tree_sitter_javascript() callconv(.c) *ts.Language;
var lang_javascript: *ts.Language = undefined;

pub fn JavascriptParser() Parser {
    return .{
        .init = init,
        .deinit = deinit,
        .parse = parse,
        .getHoverInfoAtPosition = getHoverInfoAtPosition,
    };
}

fn init() void {
    lang_javascript = tree_sitter_javascript();
}
fn deinit() void {
    lang_javascript.destroy();
}

const JsIdentifiersContext = struct {
    // NOTE: I hate this too. I played around with tree sitter's playground forever trying to find a way I could achieve what I'm trying to achieve. This was the *most sane* solution. I'm sure I'm still missing some cases.
    const QUERY =
        \\[
        \\  (_
        \\    value: [
        \\      (identifier) @id
        \\      (member_expression (identifier) @id (property_identifier) @prop)
        \\      (member_expression (member_expression (identifier) @id (property_identifier) @prop) (property_identifier) @prop2)
        \\      (member_expression (member_expression (member_expression (identifier) @id (property_identifier) @prop) (property_identifier) @prop2) (property_identifier) @prop3)
        \\    ]
        \\  )
        \\  (call_expression
        \\    function: [
        \\      (identifier) @id
        \\      (member_expression (identifier) @id (property_identifier) @prop)
        \\      (member_expression (member_expression (identifier) @id (property_identifier) @prop) (property_identifier) @prop2)
        \\      (member_expression (member_expression (member_expression (identifier) @id (property_identifier) @prop) (property_identifier) @prop2) (property_identifier) @prop3)
        \\    ]
        \\  )
        \\  (expression_statement
        \\    [
        \\      (identifier) @id
        \\      (member_expression (identifier) @id (property_identifier) @prop)
        \\      (member_expression (member_expression (identifier) @id (property_identifier) @prop) (property_identifier) @prop2)
        \\      (member_expression (member_expression (member_expression (identifier) @id (property_identifier) @prop) (property_identifier) @prop2) (property_identifier) @prop3)
        \\    ]
        \\  )
        \\]
    ;

    var is_last_item_prototype = false;

    pub fn callback(
        node: *const ts.Node,
        is_first_node: bool,
        c: []const u8,
        a: std.mem.Allocator,
    ) std.mem.Allocator.Error![]const []const bins.BinSearchSymbolInfo {
        const name = c[node.startByte()..node.endByte()];

        if (is_first_node) {
            symbol_stack[0] = .{ .name = name, .node_kind = .JsIdentifier };
            symbol_stack_len = 1;
            return try a.dupe([]const bins.BinSearchSymbolInfo, &.{
                try a.dupe(bins.BinSearchSymbolInfo, symbol_stack[0..symbol_stack_len]),
            });
        } else {
            if (std.mem.eql(u8, name, "prototype")) {
                if (!is_last_item_prototype)
                    is_last_item_prototype = true;
                return &.{};
            }
            defer is_last_item_prototype = false;

            if (is_last_item_prototype) {
                symbol_stack[symbol_stack_len] = .{ .name = name, .node_kind = .JsPrototypePropertyIdentifier };
            } else {
                symbol_stack[symbol_stack_len] = .{ .name = name, .node_kind = .JsPropertyIdentifier };
            }
            symbol_stack_len += 1;
            return try a.dupe([]const bins.BinSearchSymbolInfo, &.{
                try a.dupe(bins.BinSearchSymbolInfo, symbol_stack[0..symbol_stack_len]),
            });
        }
    }
};
const JsxContext = struct {
    // see the HTML query in `html.zig`
    const QUERY_DIAGNOSTICS =
        \\[
        \\  (jsx_opening_element
        \\    name: (identifier) @tagname
        \\    (jsx_attribute
        \\      (property_identifier) @attrname
        \\      (string
        \\        (string_fragment) @attrval
        \\      )?
        \\    )*
        \\  )
        \\  (jsx_self_closing_element
        \\    name: (identifier) @tagname
        \\    (jsx_attribute
        \\      (property_identifier) @attrname
        \\      (string
        \\        (string_fragment) @attrval
        \\      )?
        \\    )*
        \\  )
        \\]
    ;
    const QUERY_HOVER =
        \\  (jsx_opening_element
        \\    name: (identifier) @tagname
        \\    (jsx_attribute
        \\      (property_identifier) @attrname
        \\      (string
        \\        (string_fragment) @attrval
        \\      )?
        \\    )*
        \\  )
        \\  (jsx_closing_element
        \\    name: (identifier) @tagname
        \\    (jsx_attribute
        \\      (property_identifier) @attrname
        \\      (string
        \\        (string_fragment) @attrval
        \\      )?
        \\    )*
        \\  )
        \\  (jsx_self_closing_element
        \\    name: (identifier) @tagname
        \\    (jsx_attribute
        \\      (property_identifier) @attrname
        \\      (string
        \\        (string_fragment) @attrval
        \\      )?
        \\    )*
        \\  )
    ;

    var last_attr_name: ?[]const u8 = null;
    var tag_name: ?[]const u8 = null;

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
        } else if (last_attr_name != null and std.mem.eql(u8, node.kind(), "string_fragment")) {
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

var symbol_stack: [4]bins.BinSearchSymbolInfo = undefined;
var symbol_stack_len: usize = 0;
fn parse(
    allocator: std.mem.Allocator,
    code: []const u8,
    start_column: u32,
    start_row: u32,
) []const lsp.types.Diagnostic {
    return Parser.getDiagnosticsFromCode(
        allocator,
        lang_javascript,
        code,
        start_column,
        start_row,
        trimComment,
        &.{
            .{
                .ts_query_text = JsIdentifiersContext.QUERY,
                .perNodeCallback = JsIdentifiersContext.callback,
            },
            .{
                .ts_query_text = JsxContext.QUERY_DIAGNOSTICS,
                .perNodeCallback = JsxContext.callback,
            },
        },
        &.{},
    ) catch |err| {
        log.err("could not get diagnostics for JavaScript code: {}", .{err});
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
        lang_javascript,
        code,
        column,
        row,
        &.{
            .{
                .ts_query_text = JsIdentifiersContext.QUERY,
                .perNodeCallback = JsIdentifiersContext.callback,
            },
            .{
                .ts_query_text = JsxContext.QUERY_HOVER,
                .perNodeCallback = JsxContext.callback,
            },
        },
        &.{},
    ) catch |err| {
        log.err("encountered error retrieving hover doc in JavaScript code: {}", .{err});
        return null;
    };
}

fn trimComment(comment_raw: []const u8) []const u8 {
    if (std.mem.startsWith(u8, comment_raw, "/*")) {
        // remove leading "/* **" and trailing "** */"
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
    } else if (std.mem.startsWith(u8, comment_raw, "//")) {
        return std.mem.trim(
            u8,
            std.mem.cutPrefix(u8, comment_raw, "//").?,
            " \t",
        );
    } else return "";
}
