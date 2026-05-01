const std = @import("std");
const lsp = @import("lsp");
const log = std.log.scoped(.caniuse_ls);

const Handler = @This();

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
    _: *Handler,
    _: std.mem.Allocator,
    params: lsp.types.TextDocument.DidOpenParams,
) !void {
    const document_text = params.textDocument.text;

    // TODO parse HTML with tree sitter and publish diagnostic

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
