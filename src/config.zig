//! Generate a config struct after using the following three config file sources, in order:
//! 1. defaults
//! 2. a global config file
//! 3. a project config file
//!
//! Config file name: `.canipls.config`
//!
//! The config file is simply a newline-separated list of config options, there's not many.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.canipls);

/// The fields in the user's config file should be formatted the exact same way as the fields in this struct:
const Config = struct {
    support_threshold: f32 = 90.0,
    show_low_support_warnings: bool = true,
};
pub var config: Config = .{};

const CONFIG_FILE_NAME = "canipls.cfg";
const SetConfigError = error{
    NoAppDataEnv,
    NoHomeEnv,
};

/// Set the app-wide config based on defaults, global config file and a project config file, in that order
pub fn set(io: std.Io, environ_map: *std.process.Environ.Map) !void {
    global_config_file: {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        var config_path: []const u8 = undefined;
        if (builtin.os.tag == .windows) {
            config_path = try arena.allocator().dupe(u8, environ_map.get("APPDATA") orelse return SetConfigError.NoAppDataEnv);
        } else {
            // TODO: test this on raspberry pi
            const home_path = environ_map.get("HOME") orelse return SetConfigError.NoHomeEnv;
            config_path = try std.fs.path.join(arena.allocator(), &.{ home_path, ".config" });
        }
        const canipls_config_path = try std.fs.path.join(arena.allocator(), &.{ config_path, "canipls", CONFIG_FILE_NAME });

        const config_bytes = std.Io.Dir.cwd().readFileAlloc(io, canipls_config_path, arena.allocator(), .unlimited) catch |err| {
            switch (err) {
                std.Io.File.OpenError.FileNotFound => break :global_config_file,
                else => return err,
            }
        };
        applyConfigFileToGlobalConfig(config_bytes);
    }
    project_config_file: {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const config_bytes = std.Io.Dir.cwd().readFileAlloc(io, "." ++ CONFIG_FILE_NAME, arena.allocator(), .unlimited) catch |err| {
            switch (err) {
                std.Io.File.OpenError.FileNotFound => break :project_config_file,
                else => return err,
            }
        };
        applyConfigFileToGlobalConfig(config_bytes);
    }
    log.info("support threshold: {d}", .{config.support_threshold});
}
pub fn applyConfigFileToGlobalConfig(file_bytes: []const u8) void {
    var lines_it = std.mem.tokenizeAny(u8, file_bytes, "\r\n");
    var line_index: usize = 1;
    line_loop: while (lines_it.next()) |line| : (line_index += 1) {
        var key_value_it = std.mem.tokenizeAny(u8, line, " \t");
        const key = key_value_it.next() orelse {
            log.warn("no key found on line {d} of config file", .{line_index});
            continue :line_loop;
        };
        const value = key_value_it.next() orelse {
            log.warn("no value found on line {d} of config file", .{line_index});
            continue :line_loop;
        };

        inline for (@typeInfo(Config).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, key)) {
                switch (field.type) {
                    f32 => {
                        const f32_val = std.fmt.parseFloat(f32, value) catch |err| {
                            log.warn("value on line {d} is not a valid float; ignoring line. Error: {}", .{ line_index, err });
                            continue :line_loop;
                        };
                        @field(config, field.name) = f32_val;
                    },
                    bool => {
                        const bool_val = if (std.mem.eql(u8, value, "true"))
                            true
                        else if (std.mem.eql(u8, value, "false"))
                            false
                        else {
                            log.warn("value on line {d} is not 'true' or 'false'; ignoring line.", .{line_index});
                            continue :line_loop;
                        };
                        @field(config, field.name) = bool_val;
                    },
                    else => {},
                }
                continue :line_loop;
            }
        }
        log.warn("no config field called '{s}' -- ignoring", .{key});
    }
}
