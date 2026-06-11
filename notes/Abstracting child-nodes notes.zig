// SAME

    // (define queries)

    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(lang) catch return &.{};

    var diagnostics: std.ArrayList(lsp.types.Diagnostic) = .empty;

    const parse_res = parser.parseString(code, null);
    if (parse_res) |ast| {
        defer ast.destroy();
        var root_node = ast.rootNode();

        const ignored_spans = Parser.getIgnoreSpansFromCode(
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

        // (create a query object)

        cursor.exec(query_at_rules, root_node);
        match_loop: while (cursor.nextMatch()) |match| {
            const toplevel_node = match.captures[0].node;
            const toplevel_name = code[toplevel_node.startByte() + 1 .. toplevel_node.endByte()];

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
                .{ .name = at_rule_name, .node_kind = .MyKind },
            })) |feature_info| {
                if (feature_info.support < config.config.support_threshold)
                    diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                        allocator,
                        &toplevel_node,
                        .MyKind,
                        feature_info.support,
                        start_column,
                        start_row,
                    )) catch |err| {
                        log.err("could not add diagnostic for toplevel feature '{s}' to `diagnostics` ArrayList: {}", .{ toplevel_name, err });
                    };
            }

            // the way each parser handles child nodes is slightly different.
            // might handle this via a callback function, which takes in a *Cursor?
        }

    // CSS fires off separate ones for selectors, at-rules, properties

    // HTML does funky stuff based on tag, tag -> attr, attr -> attrval or tag -> attr -> attrval ordering

// I just need to know how to map capture order -> symbol_stack


/// Function that will be called on each node in order after parsing some code with a tree-sitter query. Will return a list of symbol stacks to search the bin files for, in order of precedence.
fn nodeCallback(node: *ts.Node, is_first_node: bool) []const []const BinSearchSymbolInfo {}

// params needed for abstracted Parser function:
    // temp_allocator: std.mem.Allocator,
    // lang: *ts.Language,
    // code: []const u8,
    // code_offset_column: u32,
    // code_offset_row: u32,
    // comment_trim_fn: *const fn (in: []const u8) []const u8,
    // injections: []const InjectionParseInfo,
    // queries
    // callbacks

// the abstracted Parser function could do the following for every single node:

    var node = match.captures[0].node;

    // contained in an ignore span? if so, skip
    for (ignored_spans) |span| {
        switch (span) {
            .row => |ignored_row| {
                if (node.startPoint().row == ignored_row) continue :match_loop;
            },
            .region => |ignored_region| {
                if (node.startPoint().row > ignored_region.row_start and node.startPoint().row < ignored_region.row_end) continue :match_loop;
            },
        }
    }

    const symbol_stacks = nodeCallback(&node);


    for (symbol_stacks) |symbol_stack| {
        if (bins.getSymbolSupportInfoFromBin(symbol_stack)) |feature_info| {
            if (feature_info.support < config.config.support_threshold) {
                // already found one as a child of one of the previous queries? those take precedence
                // TODO: see if this is the most efficient way of checking this
                // this effectively moves parsing a file & adding diagnostics from O(n) -> O(n log n)
                for (diagnostics.items) |diagnostic| {
                    if (diagnostic.range.start.line == node.startPoint().row and diagnostic.range.start.character == node.startPoint().column)
                        continue :match_loop;
                }
                diagnostics.append(allocator, Parser.getLspDiagnosticFromTsNode(
                    allocator,
                    &prop_node,
                    symbol_stack[symbol_stack.len - 1].node_kind,
                    feature_info.support,
                    start_column,
                    start_row,
                )) catch |err| {
                    log.err("could not add diagnostic for CSS property '{s}' to `diagnostics` ArrayList: {}", .{ symbol_stack[symbol_stack.len - 1].name, err });
                };
            }
            break;
        }
    }
