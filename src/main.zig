const std = @import("std");
const lsp = @import("lsp");
const log = std.log.scoped(.caniuse_ls);

const Handler = @import("Handler.zig");
const parsers = @import("parse.zig");

pub fn main(init: std.process.Init) !void {
    var read_buf: [2048]u8 = undefined;
    var stdio_transport: lsp.Transport.Stdio = .init(&read_buf, .stdin(), .stdout());
    const transport: *lsp.Transport = &stdio_transport.transport;

    var handler: Handler = .init(&init.io, transport);

    parsers.init();
    defer parsers.deinit();

    std.log.info("running caniuse-ls server...", .{});
    try lsp.basic_server.run(
        init.io,
        init.gpa,
        transport,
        &handler,
        log.err,
    );
}
