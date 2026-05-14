const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const types = @import("../types.zig");
const HoverInfo = types.HoverInfo;
const Parser = @import("Parser.zig");

const log = std.log.scoped(.canipls);

extern fn tree_sitter_css() callconv(.c) *ts.Language;
var lang_css: *ts.Language = undefined;
const css_at_rules_bin: []const u8 = @embedFile("css_at_rules.bin"); // TEMP
const css_selectors_bin: []const u8 = @embedFile("css_selectors.bin"); // TEMP
const css_properties_bin: []const u8 = @embedFile("css_props.bin"); // TEMP

pub fn CssParser() Parser {
    return .{
        .init = init,
        .deinit = deinit,
        .parse = parse,
        .getHoverInfoAtPosition = getHoverInfoAtPosition,
    };
}

fn init(io: std.Io) void {
    _ = io; // autofix
    lang_css = tree_sitter_css();
}
fn deinit() void {
    lang_css.destroy();
}
fn parse(
    allocator: std.mem.Allocator,
    code: []const u8,
    start_column: u32,
    start_row: u32,
) []const lsp.types.Diagnostic {
    const QUERY_PROPS = "(property_name) @propname";
    const QUERY_AT_RULES = "(at_keyword) @atrule";
    const QUERY_PSEUDO_ELEMENT_SELECTORS = "(pseudo_element_selector (tag_name) @pseudoelementname)";
    const QUERY_PSEUDO_CLASS_SELECTORS = "(pseudo_class_selector (class_name) @pseudoelementname)";
    const QUERY_COMMENT = "(comment) @comment";

    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(lang_css) catch return &.{};

    var diagnostics: std.ArrayList(lsp.types.Diagnostic) = .empty;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();

        const root_node = ast.rootNode();

        var error_offset: u32 = 0;
        const query_properties = ts.Query.create(lang_css, QUERY_PROPS, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return &.{};
        };
        defer query_properties.destroy();
        const query_at_rules = ts.Query.create(lang_css, QUERY_AT_RULES, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return &.{};
        };
        defer query_at_rules.destroy();
        const query_pseudo_element_selectors = ts.Query.create(lang_css, QUERY_PSEUDO_ELEMENT_SELECTORS, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return &.{};
        };
        defer query_pseudo_element_selectors.destroy();
        const query_pseudo_class_selectors = ts.Query.create(lang_css, QUERY_PSEUDO_CLASS_SELECTORS, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return &.{};
        };
        defer query_pseudo_class_selectors.destroy();
        const query_comments = ts.Query.create(lang_css, QUERY_COMMENT, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return &.{};
        };
        defer query_comments.destroy();

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        // comments (look for canipls-ignore)
        var ignored_spans: std.ArrayList(Parser.IgnoredSpan) = .empty;
        defer ignored_spans.deinit(allocator);
        var current_ignore_region_start_row: ?usize = null;
        cursor.exec(query_comments, root_node);
        while (cursor.nextMatch()) |match| {
            const comment_node = match.captures[0].node;
            const comment_raw = code[comment_node.startByte()..comment_node.endByte()];

            const comment = std.mem.trim(
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

            if (std.mem.eql(u8, comment, "canipls-ignore-file")) {
                return &.{};
            } else if (std.mem.eql(u8, comment, "canipls-ignore")) {
                ignored_spans.append(allocator, .{ .line = comment_node.startPoint().row }) catch return &.{};
            } else if (std.mem.eql(u8, comment, "canipls-ignore-start")) {
                if (current_ignore_region_start_row) |row_start| {
                    diagnostics.append(allocator, .{
                        .range = .{
                            .start = .{ .character = comment_node.startPoint().column, .line = comment_node.startPoint().row },
                            .end = .{ .character = comment_node.endPoint().column, .line = comment_node.endPoint().row },
                        },
                        .message = std.fmt.allocPrint(allocator, "This ignore-start shadows the one found on line {d}", .{row_start + 1}) catch "ERROR - could not call allocPrint()",
                        .severity = .Warning,
                    }) catch return &.{};
                } else {
                    current_ignore_region_start_row = comment_node.startPoint().row;
                }
            } else if (std.mem.eql(u8, comment, "canipls-ignore-end")) {
                if (current_ignore_region_start_row) |row_start| {
                    ignored_spans.append(
                        allocator,
                        .{
                            .region = .{ .row_start = row_start, .row_end = comment_node.startPoint().row },
                        },
                    ) catch return &.{};
                } else {
                    diagnostics.append(allocator, .{
                        .range = .{
                            .start = .{ .character = comment_node.startPoint().column, .line = comment_node.startPoint().row },
                            .end = .{ .character = comment_node.endPoint().column, .line = comment_node.endPoint().row },
                        },
                        .message = std.fmt.allocPrint(allocator, "This ignore-end has no ignore-start pairing", .{}) catch "ERROR - could not call allocPrint()",
                        .severity = .Warning,
                    }) catch return &.{};
                }
            }
        }

        // properties
        cursor.exec(query_properties, root_node);
        props_loop: while (cursor.nextMatch()) |match| {
            const prop_node = match.captures[0].node;
            const prop_name = code[prop_node.startByte()..prop_node.endByte()];

            // TODO extract this ignore check out somehow - code is not DRY
            // contained in an ignore span?
            for (ignored_spans.items) |span| {
                switch (span) {
                    .line => |ignored_row| {
                        if (prop_node.startPoint().row == ignored_row) continue :props_loop;
                    },
                    .region => |ignored_region| {
                        if (prop_node.startPoint().row > ignored_region.row_start and prop_node.startPoint().row < ignored_region.row_end) continue :props_loop;
                    },
                }
            }

            const maybe_support_percentage = Parser.getSupportPercentageForIdentifierFromBin(prop_name, css_properties_bin);
            if (maybe_support_percentage) |percentage| {
                if (percentage < 90.0) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                    allocator,
                    &prop_node,
                    .CssProp,
                    percentage,
                    start_column,
                    start_row,
                )) catch return &.{};
            }
        }

        // @at-rules
        cursor.exec(query_at_rules, root_node);
        at_rules_loop: while (cursor.nextMatch()) |match| {
            const at_rule_node = match.captures[0].node;
            const at_rule_name = code[at_rule_node.startByte()..at_rule_node.endByte()];

            // TODO extract this ignore check out somehow - code is not DRY
            // contained in an ignore span?
            for (ignored_spans.items) |span| {
                switch (span) {
                    .line => |ignored_row| {
                        if (at_rule_node.startPoint().row == ignored_row) continue :at_rules_loop;
                    },
                    .region => |ignored_region| {
                        if (at_rule_node.startPoint().row > ignored_region.row_start and at_rule_node.startPoint().row < ignored_region.row_end) continue :at_rules_loop;
                    },
                }
            }

            const maybe_support_percentage = Parser.getSupportPercentageForIdentifierFromBin(at_rule_name[1..], css_at_rules_bin);
            if (maybe_support_percentage) |percentage| {
                if (percentage < 90.0) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                    allocator,
                    &at_rule_node,
                    .CssAtRule,
                    percentage,
                    start_column,
                    start_row,
                )) catch return &.{};
            }
        }

        // NOTE: may distinguish between pseudo element selectors (::) and pseudo class selectors (:) using BCD features' `__compat.description`
        // psudeo selctors
        for ([_]*ts.Query{ query_pseudo_element_selectors, query_pseudo_class_selectors }) |query| {
            cursor.exec(query, root_node);
            selectors_loop: while (cursor.nextMatch()) |match| {
                const selector_node = match.captures[0].node;
                const selector_name = code[selector_node.startByte()..selector_node.endByte()];

                // TODO extract this ignore check out somehow - code is not DRY
                // contained in an ignore span?
                for (ignored_spans.items) |span| {
                    switch (span) {
                        .line => |ignored_row| {
                            if (selector_node.startPoint().row == ignored_row) continue :selectors_loop;
                        },
                        .region => |ignored_region| {
                            if (selector_node.startPoint().row > ignored_region.row_start and selector_node.startPoint().row < ignored_region.row_end) continue :selectors_loop;
                        },
                    }
                }

                const maybe_support_percentage = Parser.getSupportPercentageForIdentifierFromBin(selector_name, css_selectors_bin);
                if (maybe_support_percentage) |percentage| {
                    if (percentage < 90.0) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                        allocator,
                        &selector_node,
                        .CssSelector,
                        percentage,
                        start_column,
                        start_row,
                    )) catch return &.{};
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
    const QUERY_PROPS = "(property_name) @propname";
    const QUERY_AT_RULES = "(at_keyword) @atrule";
    const QUERY_PSEUDO_ELEMENT_SELECTORS = "(pseudo_element_selector (tag_name) @pseudoelementname)";
    const QUERY_PSEUDO_CLASS_SELECTORS = "(pseudo_class_selector (class_name) @pseudoelementname)";

    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(lang_css) catch return null;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();

        const root_node = ast.rootNode();

        var error_offset: u32 = 0;
        const query_properties = ts.Query.create(lang_css, QUERY_PROPS, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return null;
        };
        defer query_properties.destroy();
        const query_at_rules = ts.Query.create(lang_css, QUERY_AT_RULES, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return null;
        };
        defer query_at_rules.destroy();
        const query_pseudo_element_selectors = ts.Query.create(lang_css, QUERY_PSEUDO_ELEMENT_SELECTORS, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return null;
        };
        defer query_pseudo_element_selectors.destroy();
        const query_pseudo_class_selectors = ts.Query.create(lang_css, QUERY_PSEUDO_CLASS_SELECTORS, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return null;
        };
        defer query_pseudo_class_selectors.destroy();

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        cursor.setPointRange(
            .{ .column = column, .row = row },
            .{ .column = column, .row = row },
        ) catch return null;

        // properties
        cursor.exec(query_properties, root_node);
        while (cursor.nextMatch()) |match| {
            const prop_node = match.captures[0].node;
            const prop_name = code[prop_node.startByte()..prop_node.endByte()];

            const maybe_support_percentage = Parser.getSupportPercentageForIdentifierFromBin(prop_name, css_properties_bin);
            if (maybe_support_percentage) |percentage| {
                return HoverInfo{
                    .caniuse_id = "html_elements_geolocation", // TEMP
                    .identifier = prop_name,
                    .support_percentage = percentage,
                };
            }
        }

        // @at-rules
        cursor.exec(query_at_rules, root_node);
        while (cursor.nextMatch()) |match| {
            const at_rule_node = match.captures[0].node;
            const at_rule_name = code[at_rule_node.startByte()..at_rule_node.endByte()];

            const maybe_support_percentage = Parser.getSupportPercentageForIdentifierFromBin(at_rule_name[1..], css_at_rules_bin);
            if (maybe_support_percentage) |percentage| {
                return HoverInfo{
                    .caniuse_id = "html_elements_geolocation", // TEMP
                    .identifier = at_rule_name,
                    .support_percentage = percentage,
                };
            }
        }

        // NOTE: may distinguish between pseudo element selectors (::) and pseudo class selectors (:) using BCD features' `__compat.description`
        // psudeo selctors
        for ([_]*ts.Query{ query_pseudo_element_selectors, query_pseudo_class_selectors }) |query| {
            cursor.exec(query, root_node);
            while (cursor.nextMatch()) |match| {
                const selector_node = match.captures[0].node;
                const selector_name = code[selector_node.startByte()..selector_node.endByte()];

                const maybe_support_percentage = Parser.getSupportPercentageForIdentifierFromBin(selector_name, css_selectors_bin);
                if (maybe_support_percentage) |percentage| {
                    return HoverInfo{
                        .caniuse_id = "html_elements_geolocation", // TEMP
                        .identifier = selector_name,
                        .support_percentage = percentage,
                    };
                }
            }
        }
    }

    return null;
}
