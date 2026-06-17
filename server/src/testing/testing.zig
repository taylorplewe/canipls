const std = @import("std");
const builtin = @import("builtin");

const config = @import("../config.zig");
const lsp_to_ts = @import("../lsp_to_ts.zig");
const bins = @import("../parsers/bins.zig");
const js = @import("../parsers/js.zig");
const css = @import("../parsers/css.zig");
const html = @import("../parsers/html.zig");
const astro = @import("../parsers/astro.zig");
const svelte = @import("../parsers/svelte.zig");

// The default Zig test runner runs every `test` block one after the other. There is not one overarching process code (other than the test runner) where you can set up and tear down stuff for the whole testing process.
//
// Because of this, for now I'm just putting the entire program's test code into one `test` block. I think the solution is to write my own test runner.
test {
    // init tree-sitter parsers
    lsp_to_ts.init();
    defer lsp_to_ts.deinit();

    // init bin files

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_dir_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer {
        std.testing.allocator.free(tmp_dir_path);
    }

    var environ_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ_map.deinit();
    if (builtin.os.tag == .windows)
        try environ_map.put("LOCALAPPDATA", tmp_dir_path)
    else
        try environ_map.put("HOME", tmp_dir_path);

    try bins.init(std.testing.allocator, std.testing.io, &environ_map);
    defer bins.deinit(std.testing.allocator);

    config.config.support_threshold = 99.0;

    // actual tests

    // bin files check

    const canipls_bins_path = try std.fs.path.join(std.testing.allocator, &.{ "canipls", "bins" });
    defer std.testing.allocator.free(canipls_bins_path);

    const canipls_bins_dir = try tmp_dir.dir.openDir(std.testing.io, canipls_bins_path, .{ .iterate = true });
    const unneeded_timestamp = try bins.checkAllBinFilesPresentAndGetOldestTimestamp(std.testing.io, &canipls_bins_dir, 0);

    try std.testing.expect(unneeded_timestamp != null);

    var bin_kind_map = bins.bin_kind_to_file_path_map.iterator();
    while (bin_kind_map.next()) |entry| {
        try std.testing.expect(bins.bin_map.get(entry.key) != null);
    }

    // js
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const code =
            \\const _1 = Temporal.Now.instant();
            \\const _2 = XMLSerializer.prototype.serializeToString;
            \\Intl.Collator.prototype.compare;
            \\const o = {
            \\  idk: Array.prototype.every,
            \\}
        ;
        const diagnostics = js.JavascriptParser().parse(arena.allocator(), code, 0, 0);
        try std.testing.expectEqual(10, diagnostics.len);
        try std.testing.expectEqual(0, diagnostics[0].range.start.line);
        try std.testing.expectEqual(11, diagnostics[0].range.start.character);
        try std.testing.expectEqual(19, diagnostics[0].range.end.character);

        const hover_info = js.JavascriptParser().getHoverInfoAtPosition(arena.allocator(), code, 1, 2);
        try std.testing.expectEqualStrings("Intl", hover_info.?.identifier);
        try std.testing.expectEqualStrings("javascript_builtins_intl", hover_info.?.caniuse_id);
        try std.testing.expect(hover_info.?.support_percentage > 95.0);
    }
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const code =
            \\export function List() {
            \\    return <li>
            \\        <button commandfor="idk" command="request-close">hello</button>
            \\    </li>;
            \\}
        ;
        const diagnostics = js.JavascriptParser().parse(arena.allocator(), code, 0, 0);
        try std.testing.expectEqual(5, diagnostics.len);
        try std.testing.expectEqual(1, diagnostics[0].range.start.line);
        try std.testing.expectEqual(12, diagnostics[0].range.start.character);
        try std.testing.expectEqual(14, diagnostics[0].range.end.character);

        const hover_info = js.JavascriptParser().getHoverInfoAtPosition(arena.allocator(), code, 12, 1);
        try std.testing.expectEqualStrings("li", hover_info.?.identifier);
        try std.testing.expectEqualStrings("html_elements_li", hover_info.?.caniuse_id);
        try std.testing.expect(hover_info.?.support_percentage > 95.0);
    }

    // css
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const code =
            \\::scroll-button(*) {
            \\    color: white;
            \\}
            \\:root {
            \\}
        ;
        const diagnostics = css.CssParser().parse(arena.allocator(), code, 0, 0);
        try std.testing.expectEqual(4, diagnostics.len);
        try std.testing.expectEqual(0, diagnostics[0].range.start.line);
        try std.testing.expectEqual(2, diagnostics[0].range.start.character);
        try std.testing.expectEqual(15, diagnostics[0].range.end.character);

        const hover_info = css.CssParser().getHoverInfoAtPosition(arena.allocator(), code, 1, 3);
        try std.testing.expectEqualStrings("root", hover_info.?.identifier);
        try std.testing.expectEqualStrings("css_selectors_root", hover_info.?.caniuse_id);
        try std.testing.expect(hover_info.?.support_percentage > 95.0);
    }
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const code =
            \\@starting-style {
            \\    color: white;
            \\}
            \\@page {
            \\    @top-left {
            \\        interpolate-size: allow-keywords;
            \\    }
            \\}
        ;
        const diagnostics = css.CssParser().parse(arena.allocator(), code, 0, 0);
        try std.testing.expectEqual(6, diagnostics.len);
        try std.testing.expectEqual(0, diagnostics[0].range.start.line);
        try std.testing.expectEqual(0, diagnostics[0].range.start.character);
        try std.testing.expectEqual(15, diagnostics[0].range.end.character);

        const hover_info = css.CssParser().getHoverInfoAtPosition(arena.allocator(), code, 0, 3);
        try std.testing.expectEqualStrings("page", hover_info.?.identifier);
        try std.testing.expectEqualStrings("css_at-rules_page", hover_info.?.caniuse_id);
        try std.testing.expect(hover_info.?.support_percentage > 93.0);
    }

    // html
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const code =
            \\<textarea contenteditable="plaintext-only">
            \\<button commandfor="someid" command="request-close">hello</button>
        ;
        const diagnostics = html.HtmlParser().parse(arena.allocator(), code, 0, 0);
        try std.testing.expectEqual(7, diagnostics.len);
        try std.testing.expectEqual(0, diagnostics[0].range.start.line);
        try std.testing.expectEqual(1, diagnostics[0].range.start.character);
        try std.testing.expectEqual(9, diagnostics[0].range.end.character);

        const hover_info = html.HtmlParser().getHoverInfoAtPosition(arena.allocator(), code, 1, 0);
        try std.testing.expectEqualStrings("textarea", hover_info.?.identifier);
        try std.testing.expectEqualStrings("html_elements_textarea", hover_info.?.caniuse_id);
        try std.testing.expect(hover_info.?.support_percentage > 95.0);
    }
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const code =
            \\<style>
            \\:root {
            \\    color: white;
            \\}
            \\</style>
        ;
        const diagnostics = html.HtmlParser().parse(arena.allocator(), code, 0, 0);
        try std.testing.expectEqual(3, diagnostics.len);
        try std.testing.expectEqual(1, diagnostics[1].range.start.line);
        try std.testing.expectEqual(1, diagnostics[1].range.start.character);
        try std.testing.expectEqual(5, diagnostics[1].range.end.character);

        const hover_info = html.HtmlParser().getHoverInfoAtPosition(arena.allocator(), code, 1, 1);
        try std.testing.expectEqualStrings("root", hover_info.?.identifier);
        try std.testing.expectEqualStrings("css_selectors_root", hover_info.?.caniuse_id);
        try std.testing.expect(hover_info.?.support_percentage > 95.0);
    }
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const code =
            \\<script>
            \\const _1 = Intl.DateTimeFormat;
            \\</script>
        ;
        const diagnostics = html.HtmlParser().parse(arena.allocator(), code, 0, 0);
        try std.testing.expectEqual(3, diagnostics.len);
        try std.testing.expectEqual(1, diagnostics[1].range.start.line);
        try std.testing.expectEqual(11, diagnostics[1].range.start.character);
        try std.testing.expectEqual(15, diagnostics[1].range.end.character);

        const hover_info = html.HtmlParser().getHoverInfoAtPosition(arena.allocator(), code, 16, 1);
        try std.testing.expectEqualStrings("DateTimeFormat", hover_info.?.identifier);
        try std.testing.expectEqualStrings("javascript_builtins_intl_datetimeformat", hover_info.?.caniuse_id);
        try std.testing.expect(hover_info.?.support_percentage > 95.0);
    }

    // astro
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const code =
            \\---
            \\const _1 = Temporal.Now.instant();
            \\Intl.DateTimeFormat
            \\---
            \\
            \\<button commandfor="idk" command="request-close">hello</button>
        ;
        const diagnostics = astro.AstroParser().parse(arena.allocator(), code, 0, 0);
        try std.testing.expectEqual(9, diagnostics.len);
        try std.testing.expectEqual(1, diagnostics[4].range.start.line);
        try std.testing.expectEqual(11, diagnostics[4].range.start.character);
        try std.testing.expectEqual(19, diagnostics[4].range.end.character);

        const hover_info = astro.AstroParser().getHoverInfoAtPosition(arena.allocator(), code, 5, 2);
        try std.testing.expectEqualStrings("DateTimeFormat", hover_info.?.identifier);
        try std.testing.expectEqualStrings("javascript_builtins_intl_datetimeformat", hover_info.?.caniuse_id);
        try std.testing.expect(hover_info.?.support_percentage > 95.0);
    }

    // svelte
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const code =
            \\<script lang="ts">
            \\const _1 = Temporal.Now.instant();
            \\Intl.DateTimeFormat
            \\</script>
            \\
            \\{#if true}
            \\    <button commandfor="idk" command="request-close">hello</button>
            \\{:else}
            \\    <button>click me</button>
            \\{/if}
        ;
        const diagnostics = svelte.SvelteParser().parse(arena.allocator(), code, 0, 0);
        try std.testing.expectEqual(12, diagnostics.len);
        try std.testing.expectEqual(1, diagnostics[7].range.start.line);
        try std.testing.expectEqual(11, diagnostics[7].range.start.character);
        try std.testing.expectEqual(19, diagnostics[7].range.end.character);

        const hover_info = svelte.SvelteParser().getHoverInfoAtPosition(arena.allocator(), code, 5, 2);
        try std.testing.expectEqualStrings("DateTimeFormat", hover_info.?.identifier);
        try std.testing.expectEqualStrings("javascript_builtins_intl_datetimeformat", hover_info.?.caniuse_id);
        try std.testing.expect(hover_info.?.support_percentage > 95.0);
    }

    // canipls-ignore comments
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const code_1 =
            \\<textarea contenteditable="plaintext-only"> <!-- canipls-ignore -->
            \\<button commandfor="someid" command="request-close">hello</button>
        ;
        var diagnostics = html.HtmlParser().parse(arena.allocator(), code_1, 0, 0);
        try std.testing.expectEqual(4, diagnostics.len);

        // hover should still work
        const hover_info = html.HtmlParser().getHoverInfoAtPosition(arena.allocator(), code_1, 1, 0);
        try std.testing.expectEqualStrings("textarea", hover_info.?.identifier);

        const code_2 =
            \\<!-- canipls-ignore-start -->
            \\<textarea contenteditable="plaintext-only">
            \\<button commandfor="someid" command="request-close">hello</button>
            \\<!-- canipls-ignore-end -->
        ;
        diagnostics = html.HtmlParser().parse(arena.allocator(), code_2, 0, 0);
        try std.testing.expectEqual(0, diagnostics.len);

        const code_3 =
            \\<textarea contenteditable="plaintext-only">
            \\<button commandfor="someid" command="request-close">hello</button>
            \\<!-- canipls-ignore-end -->
        ;
        diagnostics = html.HtmlParser().parse(arena.allocator(), code_3, 0, 0);
        try std.testing.expectEqual(8, diagnostics.len);

        const code_4 =
            \\<!-- canipls-ignore-file -->
            \\<textarea contenteditable="plaintext-only">
            \\<button commandfor="someid" command="request-close">hello</button>
        ;
        diagnostics = html.HtmlParser().parse(arena.allocator(), code_4, 0, 0);
        try std.testing.expectEqual(0, diagnostics.len);

        const code_5 =
            \\<!-- canipls-ignore-nextline -->
            \\<textarea contenteditable="plaintext-only">
            \\<button commandfor="someid" command="request-close">hello</button>
        ;
        diagnostics = html.HtmlParser().parse(arena.allocator(), code_5, 0, 0);
        try std.testing.expectEqual(4, diagnostics.len);
    }

    // config options
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const code =
            \\<textarea contenteditable="plaintext-only">
            \\<button commandfor="someid" command="request-close">hello</button>
        ;

        config.config.support_threshold = 0;

        var diagnostics = html.HtmlParser().parse(arena.allocator(), code, 0, 0);
        try std.testing.expectEqual(0, diagnostics.len);

        // hover should still work
        const hover_info = html.HtmlParser().getHoverInfoAtPosition(arena.allocator(), code, 1, 0);
        try std.testing.expectEqualStrings("textarea", hover_info.?.identifier);

        // ignored features
        config.config.support_threshold = 99.0;
        var ignored_feature_ids = [_][]const u8{
            "html_elements_textarea",
        };
        config.config.ignored_feature_ids = &ignored_feature_ids;
        diagnostics = html.HtmlParser().parse(arena.allocator(), code, 0, 0);
        try std.testing.expectEqual(6, diagnostics.len);

        // * wildcard
        ignored_feature_ids = [_][]const u8{
            "html_elements_button*",
        };
        diagnostics = html.HtmlParser().parse(arena.allocator(), code, 0, 0);
        try std.testing.expectEqual(3, diagnostics.len);
    }
}
