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
var symbol_stack: [4]bins.BinSearchSymbolInfo = undefined;
var symbol_stack_len: usize = 0;
fn parse(
    allocator: std.mem.Allocator,
    code: []const u8,
    start_column: u32,
    start_row: u32,
) []const lsp.types.Diagnostic {
    // NOTE: I hate this too. I played around with tree sitter's playground forever trying to find a way I could achieve what I'm trying to achieve. This was the *most sane* solution. I'm sure I'm still missing some cases.
    const QUERY_IDENTIFIERS_AND_PROPERTIES =
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

    // see the HTML query in `html.zig`
    const QUERY_JSX_TAGS_AND_ATTRS =
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

    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(lang_javascript) catch return &.{};

    var diagnostics: std.ArrayList(lsp.types.Diagnostic) = .empty;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();

        const root_node = ast.rootNode();

        var error_offset: u32 = 0;

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        // const ignored_spans = Parser.getIgnoreSpansFromCode(
        //     allocator,
        //     lang_javascript,
        //     &root_node,
        //     trimComment,
        //     &diagnostics,
        //     code,
        // );
        // defer allocator.free(ignored_spans);
        const ignored_spans: []types.IgnoredSpan = &.{};

        const query = ts.Query.create(lang_javascript, QUERY_IDENTIFIERS_AND_PROPERTIES, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return diagnostics.items;
        };
        defer query.destroy();

        // JavaScript identifiers
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

            var is_last_item_prototype = false;
            symbol_stack[0] = .{ .name = id_name, .node_kind = .JsIdentifier };
            symbol_stack_len = 1;
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
                symbol_stack[symbol_stack_len] = .{ .name = name, .node_kind = .JsPropertyIdentifier };
                symbol_stack_len += 1;
                if (bins.getSymbolSupportInfoFromBin(symbol_stack[0..symbol_stack_len])) |feature_info| {
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
                symbol_stack_len -= 1;
                if (!is_last_item_prototype) continue;
                symbol_stack[symbol_stack_len] = .{ .name = name, .node_kind = .JsPrototypePropertyIdentifier };
                symbol_stack_len += 1;
                if (bins.getSymbolSupportInfoFromBin(symbol_stack[0..symbol_stack_len])) |feature_info| {
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

        // JSX elements & attributes
        const query_jsx = ts.Query.create(lang_javascript, QUERY_JSX_TAGS_AND_ATTRS, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return diagnostics.items;
        };
        defer query_jsx.destroy();

        cursor.exec(query_jsx, root_node);
        match_loop: while (cursor.nextMatch()) |match| {
            const tag_node = match.captures[0].node;
            const tag_name = code[tag_node.startByte()..tag_node.endByte()];

            // contained in an ignore span? if so, skip
            for (ignored_spans) |span| {
                switch (span) {
                    .row => |ignored_row| {
                        if (tag_node.startPoint().row == ignored_row) continue :match_loop;
                    },
                    .region => |ignored_region| {
                        if (tag_node.startPoint().row > ignored_region.row_start and tag_node.startPoint().row < ignored_region.row_end) continue :match_loop;
                    },
                }
            }

            const maybe_tag_feature_info = bins.getSymbolSupportInfoFromBin(&.{.{ .name = tag_name, .node_kind = .HtmlTag }});
            if (maybe_tag_feature_info) |feature_info| {
                if (feature_info.support < config.config.support_threshold) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                    allocator,
                    &tag_node,
                    .HtmlTag,
                    feature_info.support,
                    start_column,
                    start_row,
                )) catch |err| {
                    log.err("could not add diagnostic for HTML tag {s} to `diagnostics` ArrayList: {}", .{ tag_name, err });
                };
            }

            var last_attr_name: ?[]const u8 = null;
            for (match.captures[1..]) |capture| {
                const node = capture.node;
                const name = code[node.startByte()..node.endByte()];
                if (last_attr_name != null and std.mem.eql(u8, capture.node.kind(), "string_fragment")) {
                    defer last_attr_name = null;
                    if (bins.getSymbolSupportInfoFromBin(&.{
                        .{ .name = last_attr_name.?, .node_kind = .HtmlAttribute },
                        .{ .name = name, .node_kind = .HtmlStringLiteral },
                    })) |feature_info| {
                        if (feature_info.support < config.config.support_threshold) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                            allocator,
                            &node,
                            .HtmlStringLiteral,
                            feature_info.support,
                            start_column,
                            start_row,
                        )) catch |err| {
                            log.err("could not add diagnostic for HTML attribute value {s} to `diagnostics` ArrayList: {}", .{ name, err });
                        };
                        continue;
                    }
                    if (bins.getSymbolSupportInfoFromBin(&.{
                        .{ .name = tag_name, .node_kind = .HtmlTag },
                        .{ .name = last_attr_name.?, .node_kind = .HtmlAttribute },
                        .{ .name = name, .node_kind = .HtmlStringLiteral },
                    })) |feature_info| {
                        if (feature_info.support < config.config.support_threshold) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                            allocator,
                            &node,
                            .HtmlStringLiteral,
                            feature_info.support,
                            start_column,
                            start_row,
                        )) catch |err| {
                            log.err("could not add diagnostic for HTML attribute value {s} to `diagnostics` ArrayList: {}", .{ name, err });
                        };
                        continue;
                    }
                } else {
                    last_attr_name = name;
                    if (bins.getSymbolSupportInfoFromBin(&.{
                        .{ .name = name, .node_kind = .HtmlAttribute },
                    })) |feature_info| {
                        if (feature_info.support < config.config.support_threshold) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                            allocator,
                            &node,
                            .HtmlAttribute,
                            feature_info.support,
                            start_column,
                            start_row,
                        )) catch |err| {
                            log.err("could not add diagnostic for HTML attribute {s} to `diagnostics` ArrayList: {}", .{ name, err });
                        };
                        continue;
                    }
                    if (bins.getSymbolSupportInfoFromBin(&.{
                        .{ .name = tag_name, .node_kind = .HtmlTag },
                        .{ .name = name, .node_kind = .HtmlAttribute },
                    })) |feature_info| {
                        if (feature_info.support < config.config.support_threshold) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                            allocator,
                            &node,
                            .HtmlAttribute,
                            feature_info.support,
                            start_column,
                            start_row,
                        )) catch |err| {
                            log.err("could not add diagnostic for HTML attribute {s} to `diagnostics` ArrayList: {}", .{ name, err });
                        };
                        continue;
                    }
                }
            }
        }
    }

    return diagnostics.items;
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
