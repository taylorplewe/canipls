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

            const num_features_in_bin = std.mem.readInt(u32, css_properties_bin[0..4], .little);
            // search for feature
            var identifier_buf: [32]u8 = undefined;
            @memset(&identifier_buf, 0);
            _ = std.fmt.bufPrint(&identifier_buf, "{s}", .{prop_name[0..]}) catch return diagnostics.items; // remove leading @
            var next_name_offset = (num_features_in_bin * @sizeOf(f32)) + @sizeOf(u32);
            for (0..num_features_in_bin) |i| {
                const name = css_properties_bin[next_name_offset..][0..32];
                if (std.mem.eql(u8, &identifier_buf, name)) {
                    const support_percentage_offset = (@sizeOf(f32) * i) + @sizeOf(u32);
                    const support_percentage: *f32 = @ptrCast(@alignCast(@constCast(css_properties_bin[support_percentage_offset..][0..4])));
                    diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                        allocator,
                        &prop_node,
                        .CssProp,
                        support_percentage.*,
                        start_column,
                        start_row,
                    )) catch return &.{};
                    break;
                }
                next_name_offset += 32;
            }
        }

        // @at-rules
        cursor.exec(query_at_rules, root_node);
        while (cursor.nextMatch()) |match| {
            const at_rule_node = match.captures[0].node;
            const at_rule_name = code[at_rule_node.startByte()..at_rule_node.endByte()];

            const num_features_in_bin = std.mem.readInt(u32, css_at_rules_bin[0..4], .little);
            // search for feature
            var identifier_buf: [32]u8 = undefined;
            @memset(&identifier_buf, 0);
            _ = std.fmt.bufPrint(&identifier_buf, "{s}", .{at_rule_name[1..]}) catch return diagnostics.items; // remove leading @
            var next_name_offset = (num_features_in_bin * @sizeOf(f32)) + @sizeOf(u32);
            for (0..num_features_in_bin) |i| {
                const name = css_at_rules_bin[next_name_offset..][0..32];
                if (std.mem.eql(u8, &identifier_buf, name)) {
                    const support_percentage_offset = (@sizeOf(f32) * i) + @sizeOf(u32);
                    const support_percentage: *f32 = @ptrCast(@alignCast(@constCast(css_at_rules_bin[support_percentage_offset..][0..4])));
                    diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                        allocator,
                        &at_rule_node,
                        .CssAtRule,
                        support_percentage.*,
                        start_column,
                        start_row,
                    )) catch return &.{};
                    break;
                }
                next_name_offset += 32;
            }
        }

        // ::pseudo-element selectors
        cursor.exec(query_pseudo_element_selectors, root_node);
        while (cursor.nextMatch()) |match| {
            const selector_node = match.captures[0].node;
            const selector_name = code[selector_node.startByte()..selector_node.endByte()];

            const num_features_in_bin = std.mem.readInt(u32, css_selectors_bin[0..4], .little);
            // search for feature
            var identifier_buf: [32]u8 = undefined;
            @memset(&identifier_buf, 0);
            _ = std.fmt.bufPrint(&identifier_buf, "{s}", .{selector_name[0..]}) catch return diagnostics.items; // remove leading @
            var next_name_offset = (num_features_in_bin * @sizeOf(f32)) + @sizeOf(u32);
            for (0..num_features_in_bin) |i| {
                const name = css_selectors_bin[next_name_offset..][0..32];
                if (std.mem.eql(u8, &identifier_buf, name)) {
                    const support_percentage_offset = (@sizeOf(f32) * i) + @sizeOf(u32);
                    const support_percentage: *f32 = @ptrCast(@alignCast(@constCast(css_selectors_bin[support_percentage_offset..][0..4])));
                    diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                        allocator,
                        &selector_node,
                        .CssProp,
                        support_percentage.*,
                        start_column,
                        start_row,
                    )) catch return &.{};
                    break;
                }
                next_name_offset += 32;
            }
        }

        // :pseudo-class selectors
        cursor.exec(query_pseudo_class_selectors, root_node);
        while (cursor.nextMatch()) |match| {
            const selector_node = match.captures[0].node;
            const selector_name = code[selector_node.startByte()..selector_node.endByte()];

            const num_features_in_bin = std.mem.readInt(u32, css_selectors_bin[0..4], .little);
            // search for feature
            var identifier_buf: [32]u8 = undefined;
            @memset(&identifier_buf, 0);
            _ = std.fmt.bufPrint(&identifier_buf, "{s}", .{selector_name[0..]}) catch return diagnostics.items; // remove leading @
            var next_name_offset = (num_features_in_bin * @sizeOf(f32)) + @sizeOf(u32);
            for (0..num_features_in_bin) |i| {
                const name = css_selectors_bin[next_name_offset..][0..32];
                if (std.mem.eql(u8, &identifier_buf, name)) {
                    const support_percentage_offset = (@sizeOf(f32) * i) + @sizeOf(u32);
                    const support_percentage: *f32 = @ptrCast(@alignCast(@constCast(css_selectors_bin[support_percentage_offset..][0..4])));
                    diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                        allocator,
                        &selector_node,
                        .CssProp,
                        support_percentage.*,
                        start_column,
                        start_row,
                    )) catch return &.{};
                    break;
                }
                next_name_offset += 32;
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

    return null;
}
