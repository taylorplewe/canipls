const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try stdout_writer.flush(); // Don't forget to flush!
}
