/// Interpret the value at index 0 of `data` as an instance of `T`. Little-endian. Must be aligned according to `T`'s natural alignment.
///
/// Like `(std.Io.Reader).takeInt()` or `std.mem.readInt()`, but no reader needed, works with any type, generates less machine code.
///
/// Unsafe? Very
pub inline fn getValueFromDataAligned(comptime T: type, data: []const u8) T {
    return @as(*T, @ptrCast(@alignCast(@constCast(data)))).*;
}
