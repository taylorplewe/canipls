const std = @import("std");
const lsp = @import("lsp");

const Document = @This();

src: []const u8,
language: lsp.types.TextDocument.LanguageKind,

/// Frees current `src` and assigns `src` to `new_src` - meaning caller must have already allocated `new_src`, and the value therein must live as long as this `Document`
///
/// `allocator` must be the same one that was used to allocate this `Document`'s previous `src`.
pub fn swapSrc(
    self: *Document,
    allocator: *const std.mem.Allocator,
    new_src: []const u8,
) void {
    allocator.free(self.src);
    self.src = new_src;
}
