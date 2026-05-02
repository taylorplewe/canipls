const std = @import("std");
const lsp = @import("lsp");

const parse = @import("parse.zig");

const log = std.log.scoped(.caniuse_ls);

const Handler = @This();

io: *const std.Io,
transport: *lsp.Transport,

// helper functions
pub fn init(io: *const std.Io, transport: *lsp.Transport) Handler {
    return .{
        .io = io,
        .transport = transport,
    };
}
fn parseCodeAndPublishDiagnostics(
    self: *Handler,
    allocator: std.mem.Allocator,
    file_lang: lsp.types.TextDocument.LanguageKind,
    file_uri: []const u8,
    code: []const u8,
) !void {
    const diagnostics = parse.parseCodeAndGetDiagnostics(allocator, file_lang, code);

    const publish_diagnostics_params: lsp.types.publish_diagnostics.Params = .{
        .uri = file_uri,
        .diagnostics = diagnostics,
    };
    try self.transport.writeNotification(
        self.io.*,
        allocator,
        "textDocument/publishDiagnostics",
        lsp.types.publish_diagnostics.Params,
        publish_diagnostics_params,
        .{},
    );
}

// LSP handlers
pub fn initialize(
    _: *Handler,
    _: std.mem.Allocator,
    _: lsp.types.InitializeParams,
) lsp.types.InitializeResult {
    const capabilities: lsp.types.ServerCapabilities = .{
        .textDocumentSync = .{
            .text_document_sync_options = .{
                .change = .Full,
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
    allocator: std.mem.Allocator,
    params: lsp.types.TextDocument.DidOpenParams,
) !void {
    log.info("textDocument/didOpen", .{});

    const document_text = params.textDocument.text;

    try parseCodeAndPublishDiagnostics(
        self,
        allocator,
        .html,
        params.textDocument.uri,
        document_text,
    );
}

/// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didChange
pub fn @"textDocument/didChange"(
    self: *Handler,
    allocator: std.mem.Allocator,
    params: lsp.types.TextDocument.DidChangeParams,
) !void {
    log.info("textDocument/didChange", .{});

    // since we opted for "full" didChange notifications, we just recieve the entire document's text in the notification.
    // thus, only 1 change object is needed.
    const document_text = params.contentChanges[0].text_document_content_change_whole_document.text;

    try parseCodeAndPublishDiagnostics(
        self,
        allocator,
        .html,
        params.textDocument.uri,
        document_text,
    );
}

/// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didClose
/// we must declare this function since `didOpen` and `didClose` are opted into together
pub fn @"textDocument/didClose"(_: *Handler, _: std.mem.Allocator, _: lsp.types.TextDocument.DidCloseParams) !void {}

pub fn onResponse(_: *Handler, _: std.mem.Allocator, _: lsp.JsonRPCMessage.Response) void {}
