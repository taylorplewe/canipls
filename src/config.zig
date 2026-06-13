//! Generate a config struct after using the following three config file sources, in order:
//! 1. defaults
//! 2. a global config file
//! 3. a project config file
//!
//! Config file name: `.canipls.json`
//!
//! The config file is simply a newline-separated list of config options, there's not many.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.canipls);

const CONFIG_FILE_NAME = "canipls.json";

/// The fields in the user's config file should be formatted the exact same way as the fields in this struct:
const Config = struct {
    support_threshold: ?f32 = null,
    show_low_support_warnings: ?bool = null,
    ignored_feature_ids: ?[][]const u8 = null,
};
pub var config: Config = .{
    .support_threshold = 90.0,
    .show_low_support_warnings = true,
    .ignored_feature_ids = &.{},
};

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
    log.info("support threshold: {d}", .{config.support_threshold.?});
}
pub fn applyConfigFileToGlobalConfig(file_bytes: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const parsed_config = std.json.parseFromSliceLeaky(
        Config,
        arena.allocator(),
        file_bytes,
        .{
            .duplicate_field_behavior = .use_last,
        },
    ) catch |err| {
        log.err("could not apply config file to global config: {}", .{err});
        return;
    };

    // apply parsed JSON config to global config object
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        const val = @field(parsed_config, field.name);
        if (val != null) {
            @field(config, field.name) = val;
        }
    }
}
