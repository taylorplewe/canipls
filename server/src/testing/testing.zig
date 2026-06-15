//! NOTE: I couldn't get the tmp_dir from this file to work
//!
//! Just testing on an embedded bin is probably better anyways

const std = @import("std");

pub var tmp_dir: std.testing.TmpDir = undefined;

var canipls_bins_dir: ?std.Io.Dir = undefined;

pub fn createTmpDir() void {
    tmp_dir = std.testing.tmpDir(.{});
}

pub fn cleanupTmpDir() void {
    tmp_dir.cleanup();
}

pub fn getCaniplsBinsDir() !*std.Io.Dir {
    if (canipls_bins_dir != null) {
        return &canipls_bins_dir.?;
    }

    const canipls_bins_path = try std.fs.path.join(std.testing.allocator, &.{ "canipls", "bins" });
    defer std.testing.allocator.free(canipls_bins_path);

    canipls_bins_dir = try tmp_dir.dir.openDir(std.testing.io, canipls_bins_path, .{ .iterate = true });
    return &canipls_bins_dir.?;
}
