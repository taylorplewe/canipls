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
// const js_identifiers_bin: []const u8 = @embedFile("js_identifiers.bin"); // TEMP
// const html_tags_bin: []const u8 = @embedFile("html_tags.bin"); // TEMP
// const html_attributes_bin: []const u8 = @embedFile("html_attributes.bin"); // TEMP

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
fn parse(
    allocator: std.mem.Allocator,
    code: []const u8,
    start_column: u32,
    start_row: u32,
) []const lsp.types.Diagnostic {
    const QUERY_IDENTIFIERS_AND_PROPERTIES =
        \\(_
        \\    value: [
        \\        (identifier) @id
        \\        (member_expression (identifier) @id (property_identifier) @prop)
        \\        (member_expression (member_expression (identifier) @id (property_identifier) @prop) (property_identifier) @prop2)
        \\        (member_expression (member_expression (member_expression (identifier) @id (property_identifier) @prop) (property_identifier) @prop2) (property_identifier) @prop3)
        \\    ]
        \\)
        \\(call_expression
        \\    function: [
        \\        (identifier) @id
        \\        (member_expression (identifier) @id (property_identifier) @prop)
        \\        (member_expression (member_expression (identifier) @id (property_identifier) @prop) (property_identifier) @prop2)
        \\        (member_expression (member_expression (member_expression (identifier) @id (property_identifier) @prop) (property_identifier) @prop2) (property_identifier) @prop3)
        \\    ]
        \\)
        \\(expression_statement
        \\    [
        \\        (identifier) @id
        \\        (member_expression (identifier) @id (property_identifier) @prop)
        \\        (member_expression (member_expression (identifier) @id (property_identifier) @prop) (property_identifier) @prop2)
        \\        (member_expression (member_expression (member_expression (identifier) @id (property_identifier) @prop) (property_identifier) @prop2) (property_identifier) @prop3)
        \\    ]
        \\)
    ;

    // TODO: add JSX back in

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(lang_javascript) catch return &.{};

    var diagnostics: std.ArrayList(lsp.types.Diagnostic) = .empty;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();

        var root_node = ast.rootNode();

        var error_offset: u32 = 0;

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        const ignored_spans = Parser.getIgnoreSpansFromCode(
            allocator,
            lang_javascript,
            &root_node,
            trimComment,
            &diagnostics,
            code,
        );
        defer allocator.free(ignored_spans);

        const query = ts.Query.create(lang_javascript, QUERY_IDENTIFIERS_AND_PROPERTIES, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return diagnostics.items;
        };
        defer query.destroy();

        cursor.exec(query, root_node);
        match_loop: while (cursor.nextMatch()) |match| {
            const id_node = match.captures[0].node;
            const id_name = code[id_node.startByte()..id_node.endByte()];

            // contained in an ignore span? if so, skip
            for (ignored_spans) |span| {
                switch (span) {
                    .row => |ignored_row| {
                        if (id_node.startPoint().row == ignored_row) continue :match_loop;
                    },
                    .region => |ignored_region| {
                        if (id_node.startPoint().row > ignored_region.row_start and id_node.startPoint().row < ignored_region.row_end) continue :match_loop;
                    },
                }
            }

            const maybe_id_feature_info = bins.getSymbolSupportInfoFromBin(&.{
                .{ .name = id_name, .node_kind = .JsIdentifier },
            });
            if (maybe_id_feature_info) |feature_info| {
                if (feature_info.support < config.config.support_threshold) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                    allocator,
                    &id_node,
                    .JsIdentifier,
                    feature_info.support,
                    start_column,
                    start_row,
                )) catch |err| {
                    log.err("could not add diagnostic for JS identifier {s} to `diagnostics` ArrayList: {}", .{ id_name, err });
                };
            }

            var symbol_stack: std.ArrayList(bins.BinSearchSymbolInfo) = .empty;
            defer symbol_stack.deinit(arena.allocator());
            var is_last_item_prototype = false;
            symbol_stack.append(arena.allocator(), .{ .name = id_name, .node_kind = .JsIdentifier }) catch |err| {
                log.err("could not build symbol stack in JS parse: {}", .{err});
            };
            for (match.captures[1..]) |capture| {
                const node = capture.node;
                const name = code[node.startByte()..node.endByte()];

                if (std.mem.eql(u8, name, "prototype")) {
                    if (!is_last_item_prototype) {
                        is_last_item_prototype = true;
                        continue;
                    } else break;
                }
                defer is_last_item_prototype = false;

                // first, try regular (static) properties
                symbol_stack.append(arena.allocator(), .{ .name = name, .node_kind = .JsPropertyIdentifier }) catch |err| {
                    log.err("could not build symbol stack in JS parse: {}", .{err});
                    continue;
                };
                if (bins.getSymbolSupportInfoFromBin(symbol_stack.items)) |feature_info| {
                    if (feature_info.support < config.config.support_threshold) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                        allocator,
                        &node,
                        .JsPropertyIdentifier,
                        feature_info.support,
                        start_column,
                        start_row,
                    )) catch |err| {
                        log.err("could not add diagnostic for JS property {s} to `diagnostics` ArrayList: {}", .{ name, err });
                    };
                    continue;
                }

                // then, try prototype properties
                _ = symbol_stack.pop();
                if (!is_last_item_prototype) continue;
                symbol_stack.append(arena.allocator(), .{ .name = name, .node_kind = .JsPrototypePropertyIdentifier }) catch |err| {
                    log.err("could not build symbol stack in JS parse: {}", .{err});
                    continue;
                };
                if (bins.getSymbolSupportInfoFromBin(symbol_stack.items)) |feature_info| {
                    if (feature_info.support < config.config.support_threshold) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                        allocator,
                        &node,
                        .JsPrototypePropertyIdentifier,
                        feature_info.support,
                        start_column,
                        start_row,
                    )) catch |err| {
                        log.err("could not add diagnostic for JS method {s} to `diagnostics` ArrayList: {}", .{ name, err });
                    };
                    continue;
                }
            }
        }
    }

    return diagnostics.items;

    // const QUERY_IDENTIFIERS = "(identifier) @name";
    // const QUERY_JSX_TAGS = "(jsx_opening_element (identifier) @tagname)";
    // const QUERY_JSX_ATTRS = "(jsx_attribute (property_identifier) @attrname)";

    // const symbols = [_]types.SymbolInfo{
    //     .{
    //         .element_kind = .JsApi,
    //         .support_bin = bins.bin_map.getPtrConstAssertContains(.JsIdentifier),
    //         .ts_query_text = QUERY_IDENTIFIERS,
    //     },
    //     .{
    //         .element_kind = .HtmlElement,
    //         .support_bin = bins.bin_map.getPtrConstAssertContains(.HtmlTag),
    //         .ts_query_text = QUERY_JSX_TAGS,
    //     },
    //     .{
    //         .element_kind = .HtmlAttribute,
    //         .support_bin = bins.bin_map.getPtrConstAssertContains(.HtmlAttribute),
    //         .ts_query_text = QUERY_JSX_ATTRS,
    //     },
    // };

    // return Parser.getDiagnosticsFromCode(
    //     allocator,
    //     lang_javascript,
    //     code,
    //     start_column,
    //     start_row,
    //     trimComment,
    //     &symbols,
    //     &.{},
    // );
    //
    //
}

fn getHoverInfoAtPosition(
    code: []const u8,
    column: u32,
    row: u32,
) ?HoverInfo {
    _ = code; // autofix
    _ = column; // autofix
    _ = row; // autofix
    // const QUERY_IDENTIFIERS = "(identifier) @name";
    // const QUERY_JSX_TAGS = "(jsx_opening_element (identifier) @tagname)"; // TODO: also look for closing elements
    // const QUERY_JSX_ATTRS = "(jsx_attribute (property_identifier) @attrname)";

    // const symbols = [_]types.SymbolInfo{
    //     .{
    //         .element_kind = .JsApi,
    //         .support_bin = bins.bin_map.getPtrConstAssertContains(.JsIdentifier),
    //         .ts_query_text = QUERY_IDENTIFIERS,
    //     },
    //     .{
    //         .element_kind = .HtmlElement,
    //         .support_bin = bins.bin_map.getPtrConstAssertContains(.HtmlTag),
    //         .ts_query_text = QUERY_JSX_TAGS,
    //     },
    //     .{
    //         .element_kind = .HtmlAttribute,
    //         .support_bin = bins.bin_map.getPtrConstAssertContains(.HtmlAttribute),
    //         .ts_query_text = QUERY_JSX_ATTRS,
    //     },
    // };

    // return Parser.getHoverDocFromCodeAtPosition(
    //     lang_javascript,
    //     code,
    //     column,
    //     row,
    //     &symbols,
    //     &.{},
    // );
    return null;
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
