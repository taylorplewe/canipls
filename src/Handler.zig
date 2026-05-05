const std = @import("std");
const lsp = @import("lsp");

const Document = @import("Document.zig");
const parse = @import("parse.zig");

const log = std.log.scoped(.caniuse_ls);

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

    return &document;
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
    const diagnostics = parse.parseCodeAndGetDiagnostics(
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

    const doc = try self.addDocument(
        params.textDocument.uri,
        params.textDocument.languageId,
        params.textDocument.text,
    );

    try parseCodeAndPublishDiagnosticsForFile(
        self,
        allocator,
        params.textDocument.uri,
        doc,
    );

    self.printDocuments();
}

/// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didChange
pub fn @"textDocument/didChange"(
    self: *Handler,
    allocator: std.mem.Allocator,
    params: lsp.types.TextDocument.DidChangeParams,
) !void {
    _ = self; // autofix
    _ = allocator; // autofix
    // since we opted for "full" didChange notifications, we just recieve the entire document's text in the notification.
    // thus, only 1 change object is needed.
    // TODO: once I'm already keeping files' entire text in memory myself (for hover docs), I may change this to only require incremental change notifications
    const document_text = params.contentChanges[0].text_document_content_change_whole_document.text;
    _ = document_text; // autofix

    // TEMP: this is a terrible way to check file type. There's like fifty different extensions that JavaScript source files can have.
    // Unfortunately, didChange notifications do not send file language type
    // I may need to keep track of my own list of files and their types...
    const file_lang_str: ?[]const u8 = blk: {
        const uri = params.textDocument.uri;
        const last_index_of_period = std.mem.findScalarLast(u8, uri, '.');
        if (last_index_of_period) |index| {
            break :blk uri[index + 1 ..];
        }
        break :blk null;
    };
    if (file_lang_str) |lang_str| {
        const file_lang: lsp.types.TextDocument.LanguageKind =
            if (std.mem.eql(u8, lang_str, "html"))
                .html
            else if (std.mem.eql(u8, lang_str, "css"))
                .css
            else if (std.mem.eql(u8, lang_str, "js"))
                .javascript
            else if (std.mem.eql(u8, lang_str, "ts"))
                .typescript
            else if (std.mem.eql(u8, lang_str, "jsx"))
                .javascriptreact
            else if (std.mem.eql(u8, lang_str, "tsx"))
                .typescriptreact
            else if (std.mem.eql(u8, lang_str, "vue"))
                .{ .custom_value = "vue" }
            else if (std.mem.eql(u8, lang_str, "svelte"))
                .{ .custom_value = "svelte" }
            else if (std.mem.eql(u8, lang_str, "astro"))
                .{ .custom_value = "astro" }
            else
                return;
        _ = file_lang; // autofix

        // try parseCodeAndPublishDiagnosticsForFile(
        //     self,
        //     allocator,
        //     file_lang,
        //     params.textDocument.uri,
        //     document_text,
        // );
    }
}

/// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didClose
pub fn @"textDocument/didClose"(
    self: *Handler,
    _: std.mem.Allocator,
    params: lsp.types.TextDocument.DidCloseParams,
) !void {
    log.info("textDocument/didClose", .{});

    self.removeDocument(params.textDocument.uri);

    self.printDocuments();
}

pub fn onResponse(_: *Handler, _: std.mem.Allocator, _: lsp.JsonRPCMessage.Response) void {}
