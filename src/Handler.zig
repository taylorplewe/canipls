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
files_mu: std.Io.Mutex,

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
        .files_mu = .init,
    };
}
pub fn deinit(self: *Handler) void {
    // acquire the mutex
    self.files_mu.lockUncancelable(self.io.*);
    defer self.files_mu.unlock(self.io.*);

    var uri_it = self.files.keyIterator();
    while (uri_it.next()) |uri| {
        self.removeDocument(uri.*);
    }
    self.files.deinit();
}

fn addDocument(
    self: *Handler,
    uri: []const u8,
    lang_kind: lsp.types.TextDocument.LanguageKind,
    content: []const u8,
) !*const Document {
    const owned_document_text = try self.allocator.dupe(u8, content);
    const owned_document_uri = try self.allocator.dupe(u8, uri);

    const document: Document = .{
        .src = owned_document_text,
        .language = lang: {
            switch (lang_kind) {
                .custom_value => |value| {
                    break :lang .{ .custom_value = try self.allocator.dupe(u8, value) };
                },
                else => break :lang lang_kind,
            }
        },
    };

    // remove the file from the hash map if it exists
    self.files_mu.lockUncancelable(self.io.*);
    _ = self.files.remove(owned_document_uri);
    try self.files.put(owned_document_uri, document);
    self.files_mu.unlock(self.io.*);

    return self.files.getPtr(owned_document_uri).?;
}
fn removeDocument(self: *Handler, document_uri: []const u8) void {
    self.files_mu.lockUncancelable(self.io.*);
    defer self.files_mu.unlock(self.io.*);

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
    self.files_mu.lockUncancelable(self.io.*);
    const diagnostics = lsp_to_ts.parseCodeAndGetDiagnostics(
        temp_allocator,
        document.language,
        document.src,
    );
    self.files_mu.unlock(self.io.*);

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

var latest_did_change_thread_id: ?std.Thread.Id = null;
const DIDCHANGE_DEBOUNCE_MS = 200;

/// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didChange
pub fn @"textDocument/didChange"(
    self: *Handler,
    _: std.mem.Allocator,
    params: lsp.types.TextDocument.DidChangeParams,
) !void {
    // replace canipls' version of this document's contents
    self.files_mu.lockUncancelable(self.io.*);
    const document_get = self.files.getPtr(params.textDocument.uri);
    if (document_get) |document| {
        try document.swapSrc(&self.allocator, params.contentChanges[0].text_document_content_change_whole_document.text);
    } else {
        return;
    }
    self.files_mu.unlock(self.io.*);

    if (!config.config.show_low_support_warnings.?) return;

    const uri = try self.allocator.dupe(u8, params.textDocument.uri);
    const thread = try std.Thread.spawn(
        .{},
        handleDidChange,
        .{
            self,
            uri,
        },
    );
    thread.detach();
}

fn handleDidChange(
    self: *Handler,
    text_document_uri: lsp.types.DocumentUri,
) void {
    defer self.allocator.free(text_document_uri);
    latest_did_change_thread_id = std.Thread.getCurrentId();

    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(DIDCHANGE_DEBOUNCE_MS), .clock = .real } };
    timeout.sleep(self.io.*) catch return;

    if (std.Thread.getCurrentId() != latest_did_change_thread_id) return;

    log.info("running didChange!", .{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const document = self.files.getPtr(text_document_uri).?; // already confirmed the document exists before creating this thread
    self.parseCodeAndPublishDiagnosticsForFile(
        arena.allocator(),
        text_document_uri,
        document,
    ) catch |err| {
        log.err("could not parse code and publish diagnostics on didChange event: {}", .{err});
        return;
    };
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
    self.files_mu.lockUncancelable(self.io.*);
    defer self.files_mu.unlock(self.io.*);

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
