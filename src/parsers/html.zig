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

pub fn parseHtmlAndReturnDiagnostics(
    allocator: std.mem.Allocator,
    code: []const u8,
    start_column: u32,
    start_row: u32,
    lang: *ts.Language,
) []const lsp.types.Diagnostic {
    // const QUERY_TAGS = "(start_tag (tag_name) @tagname)";
    // const QUERY_ATTRS = "(attribute_name) @attrname";
    const QUERY_STYLE_BLOCKS = "(style_element (raw_text) @css)";
    const QUERY_SCRIPT_BLOCKS = "(script_element (raw_text) @js)";

    const NEW_QUERY_TAGS_AND_ATTRS =
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

    const injections = [_]types.InjectionParseInfo{
        .{
            .injection_parse_fn = js.JavascriptParser().parse,
            .ts_query_text = QUERY_SCRIPT_BLOCKS,
        },
        .{
            .injection_parse_fn = css.CssParser().parse,
            .ts_query_text = QUERY_STYLE_BLOCKS,
        },
    };

    const QUERY_COMMENT = "(comment) @comment"; // this is the same for all 3 TS parsers; HTML, CSS and JS.

    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(lang) catch return &.{};

    var diagnostics: std.ArrayList(lsp.types.Diagnostic) = .empty;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();

        const root_node = ast.rootNode();

        var error_offset: u32 = 0;

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        const comment_query = ts.Query.create(lang, QUERY_COMMENT, &error_offset) catch |err| {
            log.err("could not create tree-sitter comment query: {}", .{err});
            return &.{};
        };
        defer comment_query.destroy();

        // comments (look for canipls-ignore)
        var ignored_spans: std.ArrayList(IgnoredSpan) = .empty;
        defer ignored_spans.deinit(allocator);
        var current_ignore_region_start_row: ?usize = null;
        cursor.exec(comment_query, root_node);
        while (cursor.nextMatch()) |match| {
            const comment_node = match.captures[0].node;
            const comment_raw = code[comment_node.startByte()..comment_node.endByte()];
            const comment = trimComment(comment_raw);

            // gather up all the canipls-ignore spans, for later
            if (std.mem.eql(u8, comment, "canipls-ignore-file")) {
                return &.{};
            } else if (std.mem.eql(u8, comment, "canipls-ignore")) {
                ignored_spans.append(allocator, .{ .row = comment_node.startPoint().row }) catch return &.{};
            } else if (std.mem.eql(u8, comment, "canipls-ignore-nextline")) {
                ignored_spans.append(allocator, .{ .row = comment_node.startPoint().row + 1 }) catch return &.{};
            } else if (std.mem.eql(u8, comment, "canipls-ignore-start")) {
                if (current_ignore_region_start_row) |row_start| {
                    diagnostics.append(allocator, .{
                        .range = .{
                            .start = .{ .character = comment_node.startPoint().column, .line = comment_node.startPoint().row },
                            .end = .{ .character = comment_node.endPoint().column, .line = comment_node.endPoint().row },
                        },
                        .message = std.fmt.allocPrint(allocator, "This ignore-start shadows the one found on line {d}", .{row_start + 1}) catch |err| {
                            log.err("could not call allocPrint() when appending comment diagnostic: {}", .{err});
                            return diagnostics.items;
                        },
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
                        .message = std.fmt.allocPrint(allocator, "This ignore-end has no ignore-start pairing", .{}) catch |err| {
                            log.err("could not call allocPrint() when appending comment diagnostic: {}", .{err});
                            return diagnostics.items;
                        },
                        .severity = .Warning,
                    }) catch return &.{};
                }
            }
        }

        const query = ts.Query.create(lang, NEW_QUERY_TAGS_AND_ATTRS, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return diagnostics.items;
        };
        defer query.destroy();

        cursor.exec(query, root_node);
        match_loop: while (cursor.nextMatch()) |match| {
            const tag_node = match.captures[0].node;
            const tag_name = code[tag_node.startByte()..tag_node.endByte()];

            // log.info("grammarKind: {s}", .{match.captures[0].node.kind()});

            // contained in an ignore span? if so, skip
            for (ignored_spans.items) |span| {
                switch (span) {
                    .row => |ignored_row| {
                        if (tag_node.startPoint().row == ignored_row) continue :match_loop;
                    },
                    .region => |ignored_region| {
                        if (tag_node.startPoint().row > ignored_region.row_start and tag_node.startPoint().row < ignored_region.row_end) continue :match_loop;
                    },
                }
            }

            // look up this symbol in the appropriate support bin file
            // const maybe_feature_info = bins.getSupportPercentageAndCiuIdForIdentifierFromBin(name, symbol_info.support_bin);

            // TODO: the following block is VERY TEMPORARY, please don't allow in prod code
            const bin = bins.bin_map.get(.HtmlTag).?;

            const maybe_feature_info = percentage: {
                if (tag_name.len > 32) break :percentage null;

                // make identifier name in question 32-chars wide, padded with 0's
                @memcpy(identifier_buf[0..tag_name.len], tag_name);
                if (tag_name.len < 32)
                    @memset(identifier_buf[tag_name.len..], 0);

                const num_features_total = utils.getValueFromDataAligned(u32, bin[4..]);
                const num_features_toplevel = utils.getValueFromDataAligned(u32, bin[8..]);
                const sizeof_header = @sizeOf(u32) * 4;

                var sizeof_bin_sections: std.EnumArray(BinSection, usize) = blk: {
                    var ea: std.EnumArray(BinSection, usize) = .initFill(0);
                    var it = sizeof_entry_per_bin_section.iterator();
                    var index: usize = 0;
                    while (it.next()) |sizeof_entry| {
                        ea.set(@enumFromInt(index), sizeof_entry.value.* * num_features_total);
                        index += 1;
                    }
                    break :blk ea;
                };

                const section_addrs: std.EnumArray(BinSection, usize) = blk: {
                    var ea: std.EnumArray(BinSection, usize) = .initFill(0);
                    var current_pos: usize = sizeof_header;
                    var it = sizeof_bin_sections.iterator();
                    var index: usize = 0;
                    while (it.next()) |sizeof_entry| {
                        ea.set(@enumFromInt(index), current_pos);
                        current_pos += sizeof_entry.value.*;
                        index += 1;
                    }
                    break :blk ea;
                };

                // search for feature
                for (0..num_features_toplevel) |i| {
                    const next_support_offset = section_addrs.get(.Support) + (i * sizeof_entry_per_bin_section.get(.Support));
                    const next_identifier_offset = section_addrs.get(.Identifier) + (i * sizeof_entry_per_bin_section.get(.Identifier));
                    const next_ciu_id_addr_offset = section_addrs.get(.CiuIdAddr) + (i * sizeof_entry_per_bin_section.get(.CiuIdAddr));

                    const my_name = bin[next_identifier_offset..][0..32];
                    const ciu_id_addr = utils.getValueFromDataAligned(u32, bin[next_ciu_id_addr_offset..]);
                    const ciu_id_len = bin[ciu_id_addr];
                    const ciu_id = bin[ciu_id_addr + 1 ..][0..ciu_id_len];

                    // TODO: simd vector search
                    if (std.mem.eql(u8, &identifier_buf, my_name)) {
                        const support_percentage: f32 = utils.getValueFromDataAligned(f32, bin[next_support_offset..]);
                        break :percentage .{ support_percentage, ciu_id };
                    }
                }
                break :percentage null;
            };

            if (maybe_feature_info) |feature_info| {
                const percentage, _ = feature_info;
                if (percentage < config.config.support_threshold) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                    allocator,
                    &tag_node,
                    types.ElementKind.HtmlElement,
                    percentage,
                    start_column,
                    start_row,
                )) catch |err| {
                    log.err("could not add diagnostic to `diagnostics` ArrayList: {}", .{err});
                    return diagnostics.items;
                };
            }
        }

        for (injections) |injection_info| {
            const inj_query = ts.Query.create(lang, injection_info.ts_query_text, &error_offset) catch |err| {
                log.err("could not create tree-sitter query: {}", .{err});
                return &.{};
            };
            defer inj_query.destroy();

            // injection languages inside this language
            cursor.exec(inj_query, root_node);
            while (cursor.nextMatch()) |match| {
                const injection_node = match.captures[0].node;
                const injection_code = code[injection_node.startByte()..injection_node.endByte()];

                const injection_diagnostics = injection_info.injection_parse_fn(
                    allocator,
                    injection_code,
                    injection_node.startPoint().column,
                    injection_node.startPoint().row,
                );

                diagnostics.appendSlice(allocator, injection_diagnostics) catch |err| {
                    log.err("could not add injection diagnostics to `diagnostics` ArrayList: {}", .{err});
                    return diagnostics.items;
                };
            }
        }
    }

    return diagnostics.items;

    // return Parser.getDiagnosticsFromCode(
    //     allocator,
    //     lang,
    //     code,
    //     start_column,
    //     start_row,
    //     trimComment,
    //     &symbols,
    //     &injections,
    // );
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
    code: []const u8,
    column: u32,
    row: u32,
    lang: *ts.Language,
) ?HoverInfo {
    const QUERY_TAGS = "(tag_name) @tagname";
    const QUERY_ATTRS = "(attribute_name) @attrname";
    const QUERY_STYLE_BLOCKS = "(style_element (raw_text) @css)";
    const QUERY_SCRIPT_BLOCKS = "(script_element (raw_text) @js)";

    const symbols = [_]types.SymbolInfo{
        .{
            .element_kind = .HtmlAttribute,
            .support_bin = bins.bin_map.get(.HtmlAttribute).?,
            .ts_query_text = QUERY_ATTRS,
        },
        .{
            .element_kind = .HtmlElement,
            .support_bin = bins.bin_map.get(.HtmlTag).?,
            .ts_query_text = QUERY_TAGS,
        },
    };

    const injections = [_]types.InjectionHoverInfo{
        .{
            .injection_hover_fn = js.JavascriptParser().getHoverInfoAtPosition,
            .ts_query_text = QUERY_SCRIPT_BLOCKS,
        },
        .{
            .injection_hover_fn = css.CssParser().getHoverInfoAtPosition,
            .ts_query_text = QUERY_STYLE_BLOCKS,
        },
    };

    return Parser.getHoverDocFromCodeAtPosition(
        lang,
        code,
        column,
        row,
        &symbols,
        &injections,
    );
}

/// TODO: most of this code is copy-pasted from the parse function (same goes for other parsers), abstract the code out somehow
fn getHoverInfoAtPosition(
    code: []const u8,
    column: u32,
    row: u32,
) ?HoverInfo {
    return getHoverInfoFromHtmlAtPosition(
        code,
        column,
        row,
        lang_html,
    );
}
