const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const types = @import("../types.zig");
const HoverInfo = types.HoverInfo;
const IgnoredSpan = types.IgnoredSpan;
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

    const symbols = [_]types.SymbolInfo{
        .{
            .element_kind = .CssProp,
            .support_bin = css_properties_bin,
            .ts_query_text = QUERY_PROPS,
        },
        .{
            .element_kind = .CssAtRule,
            .support_bin = css_at_rules_bin,
            .ts_query_text = QUERY_AT_RULES,
            .name_trim_start = 1,
        },
        .{
            .element_kind = .CssSelector,
            .support_bin = css_selectors_bin,
            .ts_query_text = QUERY_PSEUDO_CLASS_SELECTORS,
        },
        .{
            .element_kind = .CssSelector,
            .support_bin = css_selectors_bin,
            .ts_query_text = QUERY_PSEUDO_ELEMENT_SELECTORS,
        },
    };

    return Parser.getDiagnosticsFromCode(
        allocator,
        lang_css,
        code,
        start_column,
        start_row,
        trimComment,
        &symbols,
        &.{},
    );
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
