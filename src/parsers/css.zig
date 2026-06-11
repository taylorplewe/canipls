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

    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(lang_css) catch return &.{};

    var diagnostics: std.ArrayList(lsp.types.Diagnostic) = .empty;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();
        const root_node = ast.rootNode();

        // const ignored_spans = Parser.getIgnoreSpansFromCode(
        //     allocator,
        //     lang_css,
        //     &root_node,
        //     trimComment,
        //     &diagnostics,
        //     code,
        // );
        // defer allocator.free(ignored_spans);
        const ignored_spans: []types.IgnoredSpan = &.{};

        var error_offset: u32 = 0;
        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        // at-rules
        const query_at_rules = ts.Query.create(lang_css, QUERY_AT_RULES, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return diagnostics.items;
        };
        defer query_at_rules.destroy();
        cursor.exec(query_at_rules, root_node);
        match_loop: while (cursor.nextMatch()) |match| {
            const at_rule_node = match.captures[0].node;
            const at_rule_name = code[at_rule_node.startByte() + 1 .. at_rule_node.endByte()];

            // contained in an ignore span? if so, skip
            for (ignored_spans) |span| {
                switch (span) {
                    .row => |ignored_row| {
                        if (at_rule_node.startPoint().row == ignored_row) continue :match_loop;
                    },
                    .region => |ignored_region| {
                        if (at_rule_node.startPoint().row > ignored_region.row_start and at_rule_node.startPoint().row < ignored_region.row_end) continue :match_loop;
                    },
                }
            }

            if (bins.getSymbolSupportInfoFromBin(&.{
                .{ .name = at_rule_name, .node_kind = .CssAtRule },
            })) |feature_info| {
                if (feature_info.support < config.config.support_threshold) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                    allocator,
                    &at_rule_node,
                    .CssAtRule,
                    feature_info.support,
                    start_column,
                    start_row,
                )) catch |err| {
                    log.err("could not add diagnostic for CSS at-rule '{s}' to `diagnostics` ArrayList: {}", .{ at_rule_name, err });
                };
            }

            val_loop: for (match.captures[1..]) |capture| {
                const node = capture.node;
                const start_index: usize = if (std.mem.eql(u8, node.kind(), "at_keyword")) 1 else 0;
                const name = code[node.startByte() + start_index .. node.endByte()];

                // contained in an ignore span? if so, skip
                for (ignored_spans) |span| {
                    switch (span) {
                        .row => |ignored_row| {
                            if (node.startPoint().row == ignored_row) continue :val_loop;
                        },
                        .region => |ignored_region| {
                            if (node.startPoint().row > ignored_region.row_start and node.startPoint().row < ignored_region.row_end) continue :val_loop;
                        },
                    }
                }

                const node_kind = node_kind_str_to_enum.get(node.kind()) orelse continue :val_loop;
                if (bins.getSymbolSupportInfoFromBin(&.{
                    .{ .name = at_rule_name, .node_kind = .CssAtRule },
                    .{ .name = name, .node_kind = node_kind },
                })) |feature_info| {
                    if (feature_info.support < config.config.support_threshold) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                        allocator,
                        &node,
                        node_kind,
                        feature_info.support,
                        start_column,
                        start_row,
                    )) catch |err| {
                        log.err("could not add diagnostic for CSS at-rule descriptor '{s}' to `diagnostics` ArrayList: {}", .{ name, err });
                    };
                    continue;
                }
            }
        }

        // pseudo class & pseudo element selectors
        const query_selectors = ts.Query.create(lang_css, QUERY_SELECTORS, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return diagnostics.items;
        };
        defer query_selectors.destroy();
        cursor.exec(query_selectors, root_node);
        match_loop: while (cursor.nextMatch()) |match| {
            const selector_node = match.captures[0].node;
            const selector_name = code[selector_node.startByte()..selector_node.endByte()];

            // contained in an ignore span? if so, skip
            for (ignored_spans) |span| {
                switch (span) {
                    .row => |ignored_row| {
                        if (selector_node.startPoint().row == ignored_row) continue :match_loop;
                    },
                    .region => |ignored_region| {
                        if (selector_node.startPoint().row > ignored_region.row_start and selector_node.startPoint().row < ignored_region.row_end) continue :match_loop;
                    },
                }
            }

            if (bins.getSymbolSupportInfoFromBin(&.{
                .{ .name = selector_name, .node_kind = .CssSelector },
            })) |feature_info| {
                if (feature_info.support < config.config.support_threshold) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                    allocator,
                    &selector_node,
                    .CssSelector,
                    feature_info.support,
                    start_column,
                    start_row,
                )) catch |err| {
                    log.err("could not add diagnostic for CSS pseudo-selector '{s}' to `diagnostics` ArrayList: {}", .{ selector_name, err });
                };
            }

            val_loop: for (match.captures[1..]) |capture| {
                const node = capture.node;
                const name = if (node_kind_str_to_enum.get(node.kind()) == types.TsNodeKind.CssUniversalSelector)
                    "star"
                else
                    code[node.startByte()..node.endByte()];

                // contained in an ignore span? if so, skip
                for (ignored_spans) |span| {
                    switch (span) {
                        .row => |ignored_row| {
                            if (node.startPoint().row == ignored_row) continue :val_loop;
                        },
                        .region => |ignored_region| {
                            if (node.startPoint().row > ignored_region.row_start and node.startPoint().row < ignored_region.row_end) continue :val_loop;
                        },
                    }
                }

                const node_kind = node_kind_str_to_enum.get(node.kind()) orelse continue :val_loop;
                if (bins.getSymbolSupportInfoFromBin(&.{
                    .{ .name = selector_name, .node_kind = .CssSelector },
                    .{ .name = name, .node_kind = node_kind },
                })) |feature_info| {
                    if (feature_info.support < config.config.support_threshold) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                        allocator,
                        &node,
                        node_kind,
                        feature_info.support,
                        start_column,
                        start_row,
                    )) catch |err| {
                        log.err("could not add diagnostic for CSS property-inside-pseudo-selector '{s}' to `diagnostics` ArrayList: {}", .{ name, err });
                    };
                    continue;
                }
            }
        }

        // properties
        const query = ts.Query.create(lang_css, QUERY_PROPERTIES, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return diagnostics.items;
        };
        defer query.destroy();
        cursor.exec(query, root_node);
        match_loop: while (cursor.nextMatch()) |match| {
            const prop_node = match.captures[0].node;
            const prop_name = code[prop_node.startByte()..prop_node.endByte()];

            // contained in an ignore span? if so, skip
            for (ignored_spans) |span| {
                switch (span) {
                    .row => |ignored_row| {
                        if (prop_node.startPoint().row == ignored_row) continue :match_loop;
                    },
                    .region => |ignored_region| {
                        if (prop_node.startPoint().row > ignored_region.row_start and prop_node.startPoint().row < ignored_region.row_end) continue :match_loop;
                    },
                }
            }

            if (bins.getSymbolSupportInfoFromBin(&.{
                .{ .name = prop_name, .node_kind = .CssProperty },
            })) |feature_info| {
                if (feature_info.support < config.config.support_threshold) {
                    // already found one as a child of one of the previous queries? those take precedence
                    // TODO: see if this is the most efficient way of checking this, and if it should be done in other places too
                    for (diagnostics.items) |diagnostic| {
                        if (diagnostic.range.start.line == prop_node.startPoint().row and diagnostic.range.start.character == prop_node.startPoint().column)
                            continue :match_loop;
                    }
                    diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                        allocator,
                        &prop_node,
                        .CssProperty,
                        feature_info.support,
                        start_column,
                        start_row,
                    )) catch |err| {
                        log.err("could not add diagnostic for CSS property '{s}' to `diagnostics` ArrayList: {}", .{ prop_name, err });
                    };
                }
            }

            val_loop: for (match.captures[1..]) |capture| {
                const node = capture.node;
                const name = code[node.startByte()..node.endByte()];

                // contained in an ignore span? if so, skip
                for (ignored_spans) |span| {
                    switch (span) {
                        .row => |ignored_row| {
                            if (node.startPoint().row == ignored_row) continue :val_loop;
                        },
                        .region => |ignored_region| {
                            if (node.startPoint().row > ignored_region.row_start and node.startPoint().row < ignored_region.row_end) continue :val_loop;
                        },
                    }
                }

                const node_kind = node_kind_str_to_enum.get(node.kind()) orelse continue :val_loop;
                if (bins.getSymbolSupportInfoFromBin(&.{
                    .{ .name = prop_name, .node_kind = .CssProperty },
                    .{ .name = name, .node_kind = node_kind },
                })) |feature_info| {
                    if (feature_info.support < config.config.support_threshold) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                        allocator,
                        &node,
                        node_kind,
                        feature_info.support,
                        start_column,
                        start_row,
                    )) catch |err| {
                        log.err("could not add diagnostic for CSS property value '{s}' to `diagnostics` ArrayList: {}", .{ name, err });
                    };
                    continue;
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
