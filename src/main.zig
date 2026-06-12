const std = @import("std");
const lsp = @import("lsp");
const log = std.log.scoped(.canipls);

const config = @import("config.zig");
const Handler = @import("Handler.zig");
const lsp_to_ts = @import("lsp_to_ts.zig");
const bins = @import("parsers/bins.zig");

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

    config.set(init.io, init.environ_map) catch |err| {
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

test {
    std.testing.refAllDecls(@This());
}
