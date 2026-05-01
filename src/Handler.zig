const std = @import("std");
const lsp = @import("lsp");

const parsers = @import("parsers.zig");

const log = std.log.scoped(.caniuse_ls);

const Handler = @This();

io: *const std.Io,
transport: *lsp.Transport,

pub fn init(io: *const std.Io, transport: *lsp.Transport) Handler {
    return .{
        .io = io,
        .transport = transport,
    };
}

pub fn initialize(
    _: *Handler,
    _: std.mem.Allocator,
    _: lsp.types.InitializeParams,
) lsp.types.InitializeResult {
    const capabilities: lsp.types.ServerCapabilities = .{
        .textDocumentSync = .{
            .text_document_sync_options = .{
                .change = .Full,
                .save = .{ .bool = true },
                .openClose = true,
            },
        },
    };

    lsp.basic_server.validateServerCapabilities(Handler, capabilities);

    log.info("initialize", .{});
    return .{ .capabilities = capabilities };
}

/// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didOpen
pub fn @"textDocument/didOpen"(
    self: *Handler,
    _: std.mem.Allocator,
    params: lsp.types.TextDocument.DidOpenParams,
) !void {
    const document_text = params.textDocument.text;

    // TEMP
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const diagnostics = parsers.parseCodeAndGetDiagnostics(arena.allocator(), document_text) catch &.{};

    const publish_diagnostics_params: lsp.types.publish_diagnostics.Params = .{
        .uri = params.textDocument.uri,
        .diagnostics = diagnostics,
    };
    try self.transport.writeNotification(
        self.io.*,
        arena.allocator(),
        "textDocument/publishDiagnostics",
        lsp.types.publish_diagnostics.Params,
        publish_diagnostics_params,
        .{},
    );

    log.info("textDocument/didOpen", .{});
}

/// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didChange
pub fn @"textDocument/didChange"(
    _: *Handler,
    _: std.mem.Allocator,
    _: lsp.types.TextDocument.DidChangeParams,
) !void {
    log.info("textDocument/didChange", .{});
}

/// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didSave
pub fn @"textDocument/didSave"(
    _: *Handler,
    _: std.mem.Allocator,
    _: lsp.types.TextDocument.DidSaveParams,
) !void {
    log.info("textDocument/didSave", .{});
}

/// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didClose
pub fn @"textDocument/didClose"(
    _: *Handler,
    _: std.mem.Allocator,
    _: lsp.types.TextDocument.DidCloseParams,
) !void {
    log.info("textDocument/didClose", .{});
}

pub fn onResponse(_: *Handler, _: std.mem.Allocator, _: lsp.JsonRPCMessage.Response) void {}
