//! Interface for each language tree-sitter parser to implement

const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const config = @import("../config.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");
const HoverInfo = types.HoverInfo;
const ElementKind = types.ElementKind;
const IgnoredSpan = types.IgnoredSpan;
const SymbolInfo = types.SymbolInfo;
const InjectionParseInfo = types.InjectionParseInfo;
const InjectionHoverInfo = types.InjectionHoverInfo;

const log = std.log.scoped(.canipls);

const BIN_FILE_STRING_WIDTH = 32;

init: *const fn () void,
deinit: *const fn () void,
parse: *const fn (
    allocator: std.mem.Allocator,
    code: []const u8,
    start_column: u32,
    start_row: u32,
) []const lsp.types.Diagnostic,
getHoverInfoAtPosition: *const fn (
    code: []const u8,
    column: u32,
    row: u32,
) ?HoverInfo,

pub fn getLspDiagnosticFromTsNode(
    allocator: std.mem.Allocator,
    node: *const ts.Node,
    element_kind: ElementKind,
    global_support_percentage: f32,
    start_column: u32,
    start_row: u32,
) lsp.types.Diagnostic {
    const column_to_add = if (node.startPoint().row == 0) start_column else 0;
    return .{
        .range = .{
            .start = .{ .character = node.startPoint().column + column_to_add, .line = node.startPoint().row + start_row },
            .end = .{ .character = node.endPoint().column + column_to_add, .line = node.endPoint().row + start_row },
        },
        .message = getDiagnosticPhraseFromElement(
            allocator,
            element_kind,
            global_support_percentage,
        ),
        .severity = .Warning,
    };
}
fn getDiagnosticPhraseFromElement(allocator: std.mem.Allocator, element_kind: ElementKind, global_support_percentage: f32) []u8 {
    const kind_word = element_kind.getWord();
    return std.fmt.allocPrint(
        allocator,
        "This {s} only has {d:.2}% global support on caniuse.com",
        .{ kind_word, global_support_percentage },
    ) catch |err| {
        log.err("could not allocPrint diagnostic message: {}", .{err});
        return "";
    };
}
var identifier_buf: [256]u8 = undefined;
pub fn getSupportPercentageAndCiuIdForIdentifierFromBin(
    identifier_name: []const u8,
    bin: []const u8,
) ?struct { f32, []const u8 } {
    const num_features_in_bin = std.mem.readInt(u32, bin[0..4], .little);

    // make identifier name in question 32-chars wide, padded with 0's
    @memcpy(identifier_buf[0..identifier_name.len], identifier_name);
    @memset(identifier_buf[identifier_name.len..], 0);

    const sizeof_support_section = num_features_in_bin * @sizeOf(f32);
    const sizeof_identifier_section = num_features_in_bin * BIN_FILE_STRING_WIDTH;

    var next_identifier_offset = sizeof_support_section + @sizeOf(u32);
    var next_ciu_id_addr_offset = next_identifier_offset + sizeof_identifier_section;

    // search for feature
    for (0..num_features_in_bin) |i| {
        const name = bin[next_identifier_offset..][0..BIN_FILE_STRING_WIDTH];
        // const ciu_id_addr = std.mem.readInt(u32, bin[next_ciu_id_addr_offset..][0..@sizeOf(u32)], .little);
        const ciu_id_addr = utils.getValueFromData(u32, bin[next_ciu_id_addr_offset..]);
        const ciu_id_len = bin[ciu_id_addr];
        const ciu_id = bin[ciu_id_addr + 1 ..][0..ciu_id_len];

        // TODO: simd vector search
        if (std.mem.eql(u8, &identifier_buf, name)) {
            const support_percentage_offset = (@sizeOf(f32) * i) + @sizeOf(u32);
            const support_percentage: f32 = utils.getValueFromData(f32, bin[support_percentage_offset..]);
            return .{ support_percentage, ciu_id };
        }
        next_identifier_offset += BIN_FILE_STRING_WIDTH;
        next_ciu_id_addr_offset += @sizeOf(u32);
    }
    return null;
}

pub fn getDiagnosticsFromCode(
    /// This should be the temporary allocator provided by the LSP handler function; the allocated memory is *NOT* freed in this code.
    allocator: std.mem.Allocator,
    lang: *ts.Language,
    code: []const u8,
    code_offset_column: u32,
    code_offset_row: u32,
    /// A function used to extract the actual comment text from the whole comment syntax (e.g. remove leading "<!-- " and trailing " -->")
    comment_trim_fn: *const fn (in: []const u8) []const u8,
    symbols: []const SymbolInfo,
    injections: []const InjectionParseInfo,
) []const lsp.types.Diagnostic {
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
            const comment = comment_trim_fn(comment_raw);

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

        for (symbols) |symbol_info| {
            const query = ts.Query.create(lang, symbol_info.ts_query_text, &error_offset) catch |err| {
                log.err("could not create tree-sitter query: {}", .{err});
                return diagnostics.items;
            };
            defer query.destroy();

            cursor.exec(query, root_node);
            match_loop: while (cursor.nextMatch()) |match| {
                const node = match.captures[0].node;
                const name = code[node.startByte()..node.endByte()][symbol_info.name_trim_start..];

                // contained in an ignore span? if so, skip
                for (ignored_spans.items) |span| {
                    switch (span) {
                        .row => |ignored_row| {
                            if (node.startPoint().row == ignored_row) continue :match_loop;
                        },
                        .region => |ignored_region| {
                            if (node.startPoint().row > ignored_region.row_start and node.startPoint().row < ignored_region.row_end) continue :match_loop;
                        },
                    }
                }

                // look up this symbol in the appropriate support bin file
                const maybe_feature_info = getSupportPercentageAndCiuIdForIdentifierFromBin(name, symbol_info.support_bin);
                if (maybe_feature_info) |feature_info| {
                    const percentage, const ciu_id = feature_info;
                    _ = ciu_id; // autofix
                    if (percentage < config.config.support_threshold) diagnostics.append(allocator, getLspDiagnosticFromTsNode(
                        allocator,
                        &node,
                        symbol_info.element_kind,
                        percentage,
                        code_offset_column,
                        code_offset_row,
                    )) catch |err| {
                        log.err("could not add diagnostic to `diagnostics` ArrayList: {}", .{err});
                        return diagnostics.items;
                    };
                }
            }
        }

        for (injections) |injection_info| {
            const query = ts.Query.create(lang, injection_info.ts_query_text, &error_offset) catch |err| {
                log.err("could not create tree-sitter query: {}", .{err});
                return &.{};
            };
            defer query.destroy();

            // injection languages inside this language
            cursor.exec(query, root_node);
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
}

pub fn getHoverDocFromCodeAtPosition(
    lang: *ts.Language,
    code: []const u8,
    column: u32,
    row: u32,
    symbols: []const SymbolInfo,
    injections: []const InjectionHoverInfo,
) ?HoverInfo {
    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(lang) catch return null;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();

        const root_node = ast.rootNode();

        var error_offset: u32 = 0;

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        cursor.setPointRange(
            .{ .column = column, .row = row },
            .{ .column = column, .row = row },
        ) catch return null;

        for (symbols) |symbol_info| {
            const query = ts.Query.create(lang, symbol_info.ts_query_text, &error_offset) catch |err| {
                log.err("could not create tree-sitter query: {}", .{err});
                return null;
            };
            defer query.destroy();

            cursor.exec(query, root_node);
            while (cursor.nextMatch()) |match| {
                const node = match.captures[0].node;
                const name = code[node.startByte()..node.endByte()][symbol_info.name_trim_start..];

                // look up this symbol in the appropriate support bin file
                const maybe_feature_info = getSupportPercentageAndCiuIdForIdentifierFromBin(name, symbol_info.support_bin);
                if (maybe_feature_info) |feature_info| {
                    const percentage, const ciu_id = feature_info;
                    return HoverInfo{
                        .caniuse_id = ciu_id,
                        .identifier = name,
                        .support_percentage = percentage,
                    };
                }
            }
        }

        for (injections) |injection_info| {
            const query = ts.Query.create(lang, injection_info.ts_query_text, &error_offset) catch |err| {
                log.err("could not create tree-sitter query: {}", .{err});
                return null;
            };
            defer query.destroy();

            // injection languages inside this language
            cursor.exec(query, root_node);
            while (cursor.nextMatch()) |match| {
                const injection_node = match.captures[0].node;
                const injection_code = code[injection_node.startByte()..injection_node.endByte()];

                const injection_row = row - injection_node.startPoint().row;
                if (injection_row == 0 and column < injection_node.startPoint().column)
                    continue;
                const injection_column = if (injection_row == 0) column - injection_node.startPoint().column else column;

                return injection_info.injection_hover_fn(
                    injection_code,
                    injection_column,
                    injection_row,
                );
            }
        }
    }
    return null;
}
