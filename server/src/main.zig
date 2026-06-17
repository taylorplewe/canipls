const std = @import("std");
const builtin = @import("builtin");
const lsp = @import("lsp");
const log = std.log.scoped(.canipls);

const config = @import("config.zig");
const Handler = @import("Handler.zig");
const lsp_to_ts = @import("lsp_to_ts.zig");
const bins = @import("parsers/bins.zig");
const testing = @import("testing/testing.zig");

pub fn main(init: std.process.Init) !void {
    var read_buf: [2048]u8 = undefined;
    var stdio_transport: lsp.Transport.Stdio = .init(&read_buf, .stdin(), .stdout());
    const transport: *lsp.Transport = &stdio_transport.transport;

    var handler: Handler = .init(
        init.gpa,
        &init.io,
        transport,
    );
    defer handler.deinit();

    config.set(init.arena.allocator(), init.io, init.environ_map) catch |err| {
        log.err("could not set config: {}", .{err});
    };

    bins.init(
        init.gpa,
        init.io,
        init.environ_map,
    ) catch |err| {
        log.err("could not init bin files: {}", .{err});
        // choosing to continue; the user might have previously-downloaded versions and can still use those.
        // when searching for a bin, in the `getSymbolSupportInfoFromBin()` function in `bins.zig`, it just returns silently if it can't find a bin file
    };
    defer bins.deinit(init.gpa);

    lsp_to_ts.init();
    defer lsp_to_ts.deinit();

    try lsp.basic_server.run(
        init.io,
        init.gpa,
        transport,
        &handler,
        log.err,
    );
}

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

    // css
    const css = @import("parsers/css.zig");
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const code =
            \\::scroll-button(*) {
            \\    color: white;
            \\}
            \\::scroll-button(right) {
            \\}
        ;
        const diagnostics = css.CssParser().parse(arena.allocator(), code, 0, 0);
        try std.testing.expectEqual(5, diagnostics.len);
        try std.testing.expectEqual(0, diagnostics[0].range.start.line);
        try std.testing.expectEqual(2, diagnostics[0].range.start.character);
        try std.testing.expectEqual(15, diagnostics[0].range.end.character);
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
    }

    // html
    const html = @import("parsers/html.zig");
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
    }
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const code =
            \\<style>
            \\::scroll-button(*) {
            \\    color: white;
            \\}
            \\</style>
        ;
        const diagnostics = html.HtmlParser().parse(arena.allocator(), code, 0, 0);
        try std.testing.expectEqual(4, diagnostics.len);
        try std.testing.expectEqual(1, diagnostics[1].range.start.line);
        try std.testing.expectEqual(2, diagnostics[1].range.start.character);
        try std.testing.expectEqual(15, diagnostics[1].range.end.character);
    }

    // std.testing.refAllDecls(@This());
}
