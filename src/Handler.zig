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
    self.files.deinit();
}

/// TODO: just pass a *Document to this file
fn parseCodeAndPublishDiagnosticsForFile(
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

    const document_text = try self.allocator.dupe(u8, params.textDocument.text);
    const document_uri = try self.allocator.dupe(u8, params.textDocument.uri);

    const document: Document = .{
        .src = document_text,
        .language = lang: {
            switch (params.textDocument.languageId) {
                .custom_value => |value| {
                    break :lang .{ .custom_value = try self.allocator.dupe(u8, value) };
                },
                else => break :lang params.textDocument.languageId,
            }
        },
    };

    // remove the file from the hash map if it exists
    _ = self.files.remove(document_uri);
    try self.files.put(document_uri, document);

    // TODO just pass a pointer to a Document to this file
    try parseCodeAndPublishDiagnosticsForFile(
        self,
        allocator,
        params.textDocument.languageId,
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
    // since we opted for "full" didChange notifications, we just recieve the entire document's text in the notification.
    // thus, only 1 change object is needed.
    // TODO: once I'm already keeping files' entire text in memory myself (for hover docs), I may change this to only require incremental change notifications
    const document_text = params.contentChanges[0].text_document_content_change_whole_document.text;

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

        try parseCodeAndPublishDiagnosticsForFile(
            self,
            allocator,
            file_lang,
            params.textDocument.uri,
            document_text,
        );
    }
}

/// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didClose
/// we must declare this function since `didOpen` and `didClose` are opted into together
pub fn @"textDocument/didClose"(_: *Handler, _: std.mem.Allocator, _: lsp.types.TextDocument.DidCloseParams) !void {}

pub fn onResponse(_: *Handler, _: std.mem.Allocator, _: lsp.JsonRPCMessage.Response) void {}
