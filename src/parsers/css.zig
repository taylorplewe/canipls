const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const Parser = @import("Parser.zig");

const log = std.log.scoped(.caniuse_ls);

extern fn tree_sitter_css() callconv(.c) *ts.Language;
var lang_css: *ts.Language = undefined;

pub fn CssParser() Parser {
    return .{
        .init = init,
        .deinit = deinit,
        .parse = parse,
    };
}

fn init() void {
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

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        // properties
        cursor.exec(query_properties, root_node);
        while (cursor.nextMatch()) |match| {
            const prop_node = match.captures[0].node;
            const prop_name = code[prop_node.startByte()..prop_node.endByte()];

            // TEMP
            if (std.mem.eql(u8, prop_name, "interpolate-size")) {
                diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                    allocator,
                    &prop_node,
                    .CssProp,
                    71.83,
                    start_column,
                    start_row,
                )) catch return &.{};
            }
        }

        // @at-rules
        cursor.exec(query_at_rules, root_node);
        while (cursor.nextMatch()) |match| {
            const at_rule_node = match.captures[0].node;
            const at_rule_name = code[at_rule_node.startByte()..at_rule_node.endByte()];

            // TEMP
            if (std.mem.eql(u8, at_rule_name, "@view-transition")) {
                diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                    allocator,
                    &at_rule_node,
                    .CssAtRule,
                    86.99,
                    start_column,
                    start_row,
                )) catch return &.{};
            }
        }

        // ::pseudo-element selectors
        cursor.exec(query_pseudo_element_selectors, root_node);
        while (cursor.nextMatch()) |match| {
            const selector_node = match.captures[0].node;
            const selector_name = code[selector_node.startByte()..selector_node.endByte()];

            // TEMP
            if (std.mem.eql(u8, selector_name, "column")) {
                diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                    allocator,
                    &selector_node,
                    .CssPseudoElementSelector,
                    71.17,
                    start_column,
                    start_row,
                )) catch return &.{};
            }
        }

        // :pseudo-class selectors
        cursor.exec(query_pseudo_class_selectors, root_node);
        while (cursor.nextMatch()) |match| {
            const selector_node = match.captures[0].node;
            const selector_name = code[selector_node.startByte()..selector_node.endByte()];

            // TEMP
            if (std.mem.eql(u8, selector_name, "picker")) {
                diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                    allocator,
                    &selector_node,
                    .CssPseudoClassSelector,
                    71.17,
                    start_column,
                    start_row,
                )) catch return &.{};
            }
        }
    }

    return diagnostics.items;
}
