const std = @import("std");
const lsp = @import("lsp");

const config = @import("config.zig");
const Document = @import("Document.zig");
const lsp_to_ts = @import("lsp_to_ts.zig");

const log = std.log.scoped(.canipls);

const Handler = @This();

allocator: std.mem.Allocator,
io: *const std.Io,
transport: *lsp.Transport,
files: std.StringHashMap(Document),

// helper functions
pub fn init(
    allocator: std.mem.Allocator,
    io: *const std.Io,
    transport: *lsp.Transport,
) Handler {
    return .{
        .allocator = allocator,
        .io = io,
        .transport = transport,
        .files = .init(allocator),
    };
}
pub fn deinit(self: *Handler) void {
    var uri_it = self.files.keyIterator();
    while (uri_it.next()) |uri| {
        self.removeDocument(uri.*);
    }
    self.files.deinit();
}

fn addDocument(
    self: *Handler,
    document_uri: []const u8,
    document_lang_kind: lsp.types.TextDocument.LanguageKind,
    document_text: []const u8,
) !*const Document {
    const owned_document_text = try self.allocator.dupe(u8, document_text);
    const owned_document_uri = try self.allocator.dupe(u8, document_uri);

    const document: Document = .{
        .src = owned_document_text,
        .language = lang: {
            switch (document_lang_kind) {
                .custom_value => |value| {
                    break :lang .{ .custom_value = try self.allocator.dupe(u8, value) };
                },
                else => break :lang document_lang_kind,
            }
        },
    };

    // remove the file from the hash map if it exists
    _ = self.files.remove(owned_document_uri);
    try self.files.put(owned_document_uri, document);

    return self.files.getPtr(owned_document_uri).?;
}
fn removeDocument(self: *Handler, document_uri: []const u8) void {
    const document_get = self.files.get(document_uri);
    if (document_get) |document| {
        switch (document.language) {
            .custom_value => |value| {
                self.allocator.free(value);
            },
            else => {},
        }
        self.allocator.free(document.src);
    }
    _ = self.files.remove(document_uri);
}
// DEBUG
fn printDocuments(self: *Handler) void {
    log.info("self.files:", .{});
    var it_keys = self.files.keyIterator();
    while (it_keys.next()) |uri| {
        log.info(" {s}", .{uri.*});
    }
}

fn parseCodeAndPublishDiagnosticsForFile(
    self: *Handler,
    temp_allocator: std.mem.Allocator,
    file_uri: []const u8,
    document: *const Document,
) !void {
    const diagnostics = lsp_to_ts.parseCodeAndGetDiagnostics(
        temp_allocator,
        document.language,
        document.src,
    );

    const publish_diagnostics_params: lsp.types.publish_diagnostics.Params = .{
        .uri = file_uri,
        .diagnostics = diagnostics,
    };
    try self.transport.writeNotification(
        self.io.*,
        temp_allocator,
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
        .hoverProvider = .{ .bool = true },
    };

    lsp.basic_server.validateServerCapabilities(Handler, capabilities);

    return .{ .capabilities = capabilities };
}

/// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didOpen
pub fn @"textDocument/didOpen"(
    self: *Handler,
    temp_allocator: std.mem.Allocator,
    params: lsp.types.TextDocument.DidOpenParams,
) !void {
    const doc = try self.addDocument(
        params.textDocument.uri,
        params.textDocument.languageId,
        params.textDocument.text,
    );

    if (config.config.show_low_support_warnings.?) {
        try self.parseCodeAndPublishDiagnosticsForFile(
            temp_allocator,
            params.textDocument.uri,
            doc,
        );
    }
}

/// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didChange
pub fn @"textDocument/didChange"(
    self: *Handler,
    temp_allocator: std.mem.Allocator,
    params: lsp.types.TextDocument.DidChangeParams,
) !void {
    const new_src = try self.allocator.dupe(u8, params.contentChanges[0].text_document_content_change_whole_document.text);

    const document_get = self.files.getPtr(params.textDocument.uri);
    if (document_get) |document| {
        document.swapSrc(&self.allocator, new_src);

        if (config.config.show_low_support_warnings.?) {
            try self.parseCodeAndPublishDiagnosticsForFile(
                temp_allocator,
                params.textDocument.uri,
                document,
            );
        }
    }
}

/// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didClose
pub fn @"textDocument/didClose"(
    self: *Handler,
    _: std.mem.Allocator,
    params: lsp.types.TextDocument.DidCloseParams,
) !void {
    self.removeDocument(params.textDocument.uri);
}

pub fn @"textDocument/hover"(
    self: *Handler,
    temp_allocator: std.mem.Allocator,
    params: lsp.types.Hover.Params,
) !?lsp.types.Hover {
    const document_get = self.files.getPtr(params.textDocument.uri);
    if (document_get) |document|
        return lsp_to_ts.getHoverDocAtPosition(
            temp_allocator,
            params.position,
            document,
        ) orelse null;

    return null;
}

pub fn onResponse(_: *Handler, _: std.mem.Allocator, _: lsp.JsonRPCMessage.Response) void {}
