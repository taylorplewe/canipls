/// Internal type representing all necessary information to build an LSP `Hover` instance
pub const HoverInfo = struct {
    /// The actual textual representation of the hovered symbol
    identifier: []const u8,
    /// Global support % according to caniuse.com
    support_percentage: f32,
    /// This gets appended to "https://caniuse.com/mdn-" to form a visitable link
    caniuse_id: []const u8,
};

/// Represents a span in the code where no diagnostics should be published
pub const IgnoredSpan = union(enum) {
    region: struct {
        row_start: usize,
        row_end: usize,
    },
    line: usize,
};
