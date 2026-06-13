//! Interface for each language tree-sitter parser to implement

const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const config = @import("../config.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");
const bins = @import("bins.zig");

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
    temp_allocator: std.mem.Allocator,
    code: []const u8,
    column: u32,
    row: u32,
) ?types.HoverInfo,

pub fn getLspDiagnosticFromTsNode(
    allocator: std.mem.Allocator,
    node: *const ts.Node,
    node_kind: types.TsNodeKind,
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
            node_kind,
            global_support_percentage,
        ),
        .severity = .Warning,
    };
}
fn getDiagnosticPhraseFromElement(allocator: std.mem.Allocator, node_kind: types.TsNodeKind, global_support_percentage: f32) []u8 {
    const kind_word = node_kind.getDisplayName();
    return std.fmt.allocPrint(
        allocator,
        "This {s} only has {d:.2}% global support on caniuse.com",
        .{ kind_word, global_support_percentage },
    ) catch |err| {
        log.err("could not allocPrint diagnostic message: {}", .{err});
        return "";
    };
}

pub fn getDiagnosticsFromCode(
    /// This should be the temporary allocator provided by the LSP handler function; the allocated memory is *NOT* freed in this code.
    allocator: std.mem.Allocator,
    lang: *ts.Language,
    code: []const u8,
    /// Used for injection languages (e.g. JavaScript inside of an HTML `<script>` element)
    code_offset_column: u32,
    /// Used for injection languages (e.g. JavaScript inside of an HTML `<script>` element)
    code_offset_row: u32,
    /// A function used to extract the actual comment text from the whole comment syntax (e.g. remove leading "<!-- " and trailing " -->" in HTML)
    trimComment: *const fn (in: []const u8) []const u8,
    queries: []const types.QueryInfo,
    injections: []const types.InjectionParseInfo,
) ![]lsp.types.Diagnostic {
    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(lang);

    var diagnostics: std.ArrayList(lsp.types.Diagnostic) = .empty;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();
        var root_node = ast.rootNode();

        const ignored_spans = getIgnoreSpansFromCode(
            allocator,
            lang,
            &root_node,
            trimComment,
            &diagnostics,
            code,
        );
        defer allocator.free(ignored_spans);

        var error_offset: u32 = 0;
        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        for (queries) |query_info| {
            const query = try ts.Query.create(lang, query_info.ts_query_text, &error_offset);
            defer query.destroy();

            cursor.exec(query, root_node);
            while (cursor.nextMatch()) |match| {
                capture_loop: for (match.captures, 0..) |capture, capture_index| {
                    const node = capture.node;

                    // contained in an ignore span? if so, skip
                    for (ignored_spans) |span| {
                        switch (span) {
                            .row => |ignored_row| {
                                if (node.startPoint().row == ignored_row) continue :capture_loop;
                            },
                            .region => |ignored_region| {
                                if (node.startPoint().row > ignored_region.row_start and node.startPoint().row < ignored_region.row_end) continue :capture_loop;
                            },
                        }
                    }

                    // each syntax type looks for symbols differently; this is done through callbacks provided to this function
                    const symbol_stacks = query_info.perNodeCallback(
                        &node,
                        capture_index == 0,
                        code,
                        allocator,
                    ) catch |err| {
                        log.err("could not get symbol stack: {}", .{err});
                        continue :capture_loop;
                    };
                    defer {
                        for (symbol_stacks) |stack| {
                            allocator.free(stack);
                        }
                        allocator.free(symbol_stacks);
                    }

                    // take the symbol stacks and search the bin files for support info
                    symbol_stack_loop: for (symbol_stacks) |symbol_stack| {
                        const maybe_feature_info = bins.getSymbolSupportInfoFromBin(symbol_stack);
                        if (maybe_feature_info) |feature_info| {
                            if (feature_info.support < config.config.support_threshold.?) {
                                // already found one as a child of one of the previous queries? those take precedence
                                // TODO: see if this is the most efficient way of checking this
                                // this effectively moves parsing a file & adding diagnostics from O(n) -> O(n log n)
                                for (diagnostics.items) |diagnostic| {
                                    if (diagnostic.range.start.line == node.startPoint().row and diagnostic.range.start.character == node.startPoint().column)
                                        continue :symbol_stack_loop;
                                }

                                // is this feature in the config ignore list?
                                for (config.config.ignored_feature_ids.?) |feature_id| {
                                    if (std.mem.eql(u8, feature_id, feature_info.ciu_id)) continue :symbol_stack_loop;
                                }

                                diagnostics.append(allocator, getLspDiagnosticFromTsNode(
                                    allocator,
                                    &node,
                                    symbol_stack[symbol_stack.len - 1].node_kind,
                                    feature_info.support,
                                    code_offset_column,
                                    code_offset_row,
                                )) catch |err| {
                                    log.err("could not add diagnostic for symbol {s} to `diagnostics` ArrayList: {}", .{ symbol_stack[symbol_stack.len - 1].name, err });
                                };
                            }
                            break :symbol_stack_loop;
                        }
                    }
                }
            }
        }

        for (injections) |injection_info| {
            const inj_query = try ts.Query.create(lang, injection_info.ts_query_text, &error_offset);
            defer inj_query.destroy();

            // injection languages inside this language
            cursor.exec(inj_query, root_node);
            while (cursor.nextMatch()) |match| {
                const injection_node = match.captures[0].node;
                const injection_code = code[injection_node.startByte()..injection_node.endByte()];

                const injection_diagnostics = injection_info.injectionParseFn(
                    allocator,
                    injection_code,
                    injection_node.startPoint().column,
                    injection_node.startPoint().row,
                );

                try diagnostics.appendSlice(allocator, injection_diagnostics);
            }
        }
    }

    return try diagnostics.toOwnedSlice(allocator);
}

pub fn getHoverInfoFromCodeAtPosition(
    /// This should be the temporary allocator provided by the LSP handler function; the allocated memory is *NOT* freed in this code.
    allocator: std.mem.Allocator,
    lang: *ts.Language,
    code: []const u8,
    /// Used for injection languages (e.g. JavaScript inside of an HTML `<script>` element)
    column: u32,
    /// Used for injection languages (e.g. JavaScript inside of an HTML `<script>` element)
    row: u32,
    queries: []const types.QueryInfo,
    injections: []const types.InjectionHoverInfo,
) !?types.HoverInfo {
    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(lang);

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();
        const root_node = ast.rootNode();

        var error_offset: u32 = 0;
        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        try cursor.setPointRange(
            .{ .column = column, .row = row },
            .{ .column = column, .row = row },
        );

        for (queries) |query_info| {
            const query = try ts.Query.create(lang, query_info.ts_query_text, &error_offset);
            defer query.destroy();

            cursor.exec(query, root_node);
            while (cursor.nextMatch()) |match| {
                capture_loop: for (match.captures, 0..) |capture, capture_index| {
                    const node = capture.node;

                    // each syntax type looks for symbols & child symbols differently; this is done through callbacks provided to this function
                    const symbol_stacks = query_info.perNodeCallback(
                        &node,
                        capture_index == 0,
                        code,
                        allocator,
                    ) catch |err| {
                        log.err("could not get symbol stack: {}", .{err});
                        continue :capture_loop;
                    };
                    defer {
                        for (symbol_stacks) |stack| {
                            allocator.free(stack);
                        }
                        allocator.free(symbol_stacks);
                    }

                    // is this the node being hovered over?
                    if (node.startPoint().row != row or column < node.startPoint().column or column > node.endPoint().column)
                        continue :capture_loop;

                    // take the symbol stacks and search the bin files for support info
                    for (symbol_stacks) |symbol_stack| {
                        const maybe_feature_info = bins.getSymbolSupportInfoFromBin(symbol_stack);
                        if (maybe_feature_info) |feature_info| {
                            return types.HoverInfo{
                                .caniuse_id = feature_info.ciu_id,
                                .identifier = symbol_stack[symbol_stack.len - 1].name,
                                .support_percentage = feature_info.support,
                            };
                        }
                    }
                }
            }
        }

        for (injections) |injection_info| {
            const inj_query = try ts.Query.create(lang, injection_info.ts_query_text, &error_offset);
            defer inj_query.destroy();

            // injection languages inside this language
            cursor.exec(inj_query, root_node);
            while (cursor.nextMatch()) |match| {
                const injection_node = match.captures[0].node;
                const injection_code = code[injection_node.startByte()..injection_node.endByte()];

                const injection_row = row - injection_node.startPoint().row;
                if (injection_row == 0 and column < injection_node.startPoint().column)
                    continue;
                const injection_column = if (injection_row == 0) column - injection_node.startPoint().column else column;

                return injection_info.injectionHoverFn(
                    allocator,
                    injection_code,
                    injection_column,
                    injection_row,
                );
            }
        }
    }

    return null; // symbol not found
}

const QUERY_COMMENT = "(comment) @comment"; // this is the same for all 3 TS parsers; HTML, CSS and JS.
/// Get a list of canipls-ignore ranges in a piece of code
///
/// Caller owns returned memory
fn getIgnoreSpansFromCode(
    allocator: std.mem.Allocator,
    lang: *ts.Language,
    root_node: *ts.Node,
    trimComment: *const fn (in: []const u8) []const u8,
    diagnostics: *std.ArrayList(lsp.types.Diagnostic),
    code: []const u8,
) []types.IgnoredSpan {
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();

    var error_offset: u32 = 0;
    const comment_query = ts.Query.create(lang, QUERY_COMMENT, &error_offset) catch |err| {
        log.err("could not create tree-sitter comment query: {}", .{err});
        return &.{};
    };
    defer comment_query.destroy();

    var ignored_spans: std.ArrayList(types.IgnoredSpan) = .empty;
    var current_ignore_region_start_row: ?usize = null;
    cursor.exec(comment_query, root_node.*);
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
                        return ignored_spans.toOwnedSlice(allocator) catch &.{};
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
                        return ignored_spans.toOwnedSlice(allocator) catch &.{};
                    },
                    .severity = .Warning,
                }) catch return &.{};
            }
        }
    }

    return ignored_spans.toOwnedSlice(allocator) catch &.{};
}
