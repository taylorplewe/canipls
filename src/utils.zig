/// Interpret the value at index 0 of `data` as an instance of `T`. Little-endian.
///
/// Like `(std.Io.Reader).takeInt()` or `std.mem.readInt()`, but no reader needed, and works with any type. Generates less machine code.
///
/// Unsafe? Very
pub inline fn getValueFromData(comptime T: type, data: []const u8) T {
    return @as(*T, @ptrCast(@alignCast(@constCast(data)))).*;
}
