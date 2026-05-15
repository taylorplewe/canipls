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

    return Parser.getHoverDocFromCodeAtPosition(
        lang_css,
        code,
        column,
        row,
        &symbols,
        &.{},
    );
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
