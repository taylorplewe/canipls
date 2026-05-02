//! Interface for each language tree-sitter parser to implement
const std = @import("std");
const lsp = @import("lsp");

init: *const fn () void,
deinit: *const fn () void,
parse: *const fn (allocator: std.mem.Allocator, code: []const u8) []const lsp.types.Diagnostic,
