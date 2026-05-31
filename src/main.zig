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

    try config.set(init.io, init.environ_map);

    bins.init(
        init.gpa,
        init.io,
        init.environ_map,
    ) catch return;
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
