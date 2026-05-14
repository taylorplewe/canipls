const std = @import("std");
const lsp = @import("lsp");
const ts = @import("tree-sitter");

const types = @import("../types.zig");
const HoverInfo = types.HoverInfo;
const Parser = @import("Parser.zig");

const log = std.log.scoped(.canipls);

extern fn tree_sitter_javascript() callconv(.c) *ts.Language;
var lang_javascript: *ts.Language = undefined;
const js_identifiers_bin: []const u8 = @embedFile("js_identifiers.bin"); // TEMP
const html_tags_bin: []const u8 = @embedFile("html_tags.bin"); // TEMP
const html_attributes_bin: []const u8 = @embedFile("html_attributes.bin"); // TEMP

pub fn JavascriptParser() Parser {
    return .{
        .init = init,
        .deinit = deinit,
        .parse = parse,
        .getHoverInfoAtPosition = getHoverInfoAtPosition,
    };
}

fn init(io: std.Io) void {
    _ = io; // autofix
    lang_javascript = tree_sitter_javascript();
}
fn deinit() void {
    lang_javascript.destroy();
}
fn parse(
    allocator: std.mem.Allocator,
    code: []const u8,
    start_column: u32,
    start_row: u32,
) []const lsp.types.Diagnostic {
    const QUERY_IDENTIFIERS = "(identifier) @name";
    const QUERY_TAG_NAME_AND_ATTRS =
        \\(jsx_opening_element
        \\  (identifier) @tagname
        \\  (jsx_attribute
        \\    (property_identifier) @attrname
        \\  )*
        \\)
    ;
    const QUERY_COMMENT = "(comment) @comment";

    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(lang_javascript) catch return &.{};

    var diagnostics: std.ArrayList(lsp.types.Diagnostic) = .empty;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();

        const root_node = ast.rootNode();

        var error_offset: u32 = 0;
        const query_identifiers = ts.Query.create(lang_javascript, QUERY_IDENTIFIERS, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return &.{};
        };
        defer query_identifiers.destroy();
        const query_jsx_tags_and_attrs = ts.Query.create(lang_javascript, QUERY_TAG_NAME_AND_ATTRS, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return &.{};
        };
        defer query_jsx_tags_and_attrs.destroy();
        const query_comments = ts.Query.create(lang_javascript, QUERY_COMMENT, &error_offset) catch |err| {
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

            const comment = blk: {
                if (std.mem.startsWith(u8, comment_raw, "/*")) {
                    // remove leading "/* **" and trailing "** */"
                    break :blk std.mem.trim(
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
                    break :blk std.mem.trim(
                        u8,
                        std.mem.cutPrefix(u8, comment_raw, "//").?,
                        " \t",
                    );
                } else break :blk "";
            };

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

        // identifiers
        cursor.exec(query_identifiers, root_node);
        idents_loop: while (cursor.nextMatch()) |match| {
            const identifier_node = match.captures[0].node;
            const identifier_name = code[identifier_node.startByte()..identifier_node.endByte()];

            // TODO extract this ignore check out somehow - code is not DRY
            // contained in an ignore span?
            for (ignored_spans.items) |span| {
                switch (span) {
                    .line => |ignored_row| {
                        if (identifier_node.startPoint().row == ignored_row) continue :idents_loop;
                    },
                    .region => |ignored_region| {
                        if (identifier_node.startPoint().row > ignored_region.row_start and identifier_node.startPoint().row < ignored_region.row_end) continue :idents_loop;
                    },
                }
            }

            const maybe_tag_support_percentage = Parser.getSupportPercentageForIdentifierFromBin(identifier_name, js_identifiers_bin);
            if (maybe_tag_support_percentage) |percentage| {
                if (percentage < 90.0) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                    allocator,
                    &identifier_node,
                    .JsApi, // TODO: distinguish between API and builtin?
                    percentage,
                    start_column,
                    start_row,
                )) catch return &.{};
            }
        }

        // JSX elements and attributes
        cursor.exec(query_jsx_tags_and_attrs, root_node);
        jsx_loop: while (cursor.nextMatch()) |match| {
            const tag_node = match.captures[0].node;
            const tag_name = code[tag_node.startByte()..tag_node.endByte()];

            // TODO extract this ignore check out somehow - code is not DRY
            // contained in an ignore span?
            for (ignored_spans.items) |span| {
                switch (span) {
                    .line => |ignored_row| {
                        if (tag_node.startPoint().row == ignored_row) continue :jsx_loop;
                    },
                    .region => |ignored_region| {
                        if (tag_node.startPoint().row > ignored_region.row_start and tag_node.startPoint().row < ignored_region.row_end) continue :jsx_loop;
                    },
                }
            }

            const maybe_tag_support_percentage = Parser.getSupportPercentageForIdentifierFromBin(tag_name, html_tags_bin);
            if (maybe_tag_support_percentage) |percentage| {
                if (percentage < 90.0) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                    allocator,
                    &tag_node,
                    .HtmlElement,
                    percentage,
                    start_column,
                    start_row,
                )) catch return &.{};
            }

            for (match.captures[1..]) |capture| {
                const attr_node = capture.node;
                const attr_name = code[attr_node.startByte()..attr_node.endByte()];

                // NOTE: no ignore check needed since comments could not appear alongside individual attributes

                const maybe_attr_support_percentage = Parser.getSupportPercentageForIdentifierFromBin(attr_name, html_attributes_bin);
                if (maybe_attr_support_percentage) |percentage| {
                    if (percentage < 90.0) diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                        allocator,
                        &attr_node,
                        .HtmlAttribute,
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
    const QUERY_IDENTIFIERS = "(identifier) @name";
    const QUERY_JSX_TAGS =
        \\[
        \\  (jsx_opening_element
        \\    (identifier) @tagname
        \\  )
        \\  (jsx_closing_element
        \\    (identifier) @tagname
        \\  )
        \\]
    ;
    const QUERY_JSX_ATTRS =
        \\(jsx_attribute
        \\  (property_identifier) @attrname
        \\)
    ;

    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(lang_javascript) catch return null;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();

        const root_node = ast.rootNode();

        var error_offset: u32 = 0;
        const query_identifiers = ts.Query.create(lang_javascript, QUERY_IDENTIFIERS, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return null;
        };
        defer query_identifiers.destroy();
        const query_jsx_tags = ts.Query.create(lang_javascript, QUERY_JSX_TAGS, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return null;
        };
        defer query_jsx_tags.destroy();
        const query_jsx_attrs = ts.Query.create(lang_javascript, QUERY_JSX_ATTRS, &error_offset) catch |err| {
            log.err("could not create tree-sitter query: {}", .{err});
            return null;
        };
        defer query_jsx_attrs.destroy();

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();

        cursor.setPointRange(
            .{ .column = column, .row = row },
            .{ .column = column, .row = row },
        ) catch return null;

        // identifiers
        cursor.exec(query_identifiers, root_node);
        while (cursor.nextMatch()) |match| {
            const identifier_node = match.captures[0].node;
            const identifier_name = code[identifier_node.startByte()..identifier_node.endByte()];

            const maybe_attr_support_percentage = Parser.getSupportPercentageForIdentifierFromBin(identifier_name, js_identifiers_bin);
            if (maybe_attr_support_percentage) |percentage| {
                return HoverInfo{
                    .caniuse_id = "html_elements_geolocation", // TEMP
                    .identifier = identifier_name,
                    .support_percentage = percentage,
                };
            }
        }

        // JSX attributes
        cursor.exec(query_jsx_tags, root_node);
        while (cursor.nextMatch()) |match| {
            const attr_node = match.captures[0].node;
            const attr_name = code[attr_node.startByte()..attr_node.endByte()];

            const maybe_attr_support_percentage = Parser.getSupportPercentageForIdentifierFromBin(attr_name, html_attributes_bin);
            if (maybe_attr_support_percentage) |percentage| {
                return HoverInfo{
                    .caniuse_id = "html_elements_geolocation", // TEMP
                    .identifier = attr_name,
                    .support_percentage = percentage,
                };
            }
        }

        // JSX elements
        cursor.exec(query_jsx_tags, root_node);
        while (cursor.nextMatch()) |match| {
            const tag_node = match.captures[0].node;
            const tag_name = code[tag_node.startByte()..tag_node.endByte()];

            const maybe_tag_support_percentage = Parser.getSupportPercentageForIdentifierFromBin(tag_name, html_tags_bin);
            if (maybe_tag_support_percentage) |percentage| {
                return HoverInfo{
                    .caniuse_id = "html_elements_geolocation", // TEMP
                    .identifier = tag_name,
                    .support_percentage = percentage,
                };
            }
        }

        //     for (match.captures[1..]) |capture| {
        //         const attr_node = capture.node;
        //         const attr_name = code[attr_node.startByte()..attr_node.endByte()];

        //         const maybe_attr_support_percentage = Parser.getSupportPercentageForIdentifierFromBin(attr_name, html_attributes_bin);
        //         if (maybe_attr_support_percentage) |percentage| {
        //             return HoverInfo{
        //                 .caniuse_id = "html_elements_geolocation", // TEMP
        //                 .identifier = attr_name,
        //                 .support_percentage = percentage,
        //             };
        //         }
        //     }
        // }
    }

    return null;
}
