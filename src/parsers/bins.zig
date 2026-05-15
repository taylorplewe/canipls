const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.canipls);

pub const BinKind = enum {
    HtmlTags,
    HtmlAttributes,
    CssProps,
    CssSelectors,
    CssAtRules,
    JsIdentifiers,
};

const bin_kind_to_file_path_map: std.EnumMap(BinKind, []const u8) = .initFull(.{
    .{ .HtmlTags, "html_tags.bin" },
    .{ .HtmlAttributes, "html_attributes.bin" },
    .{ .CssProps, "css_props.bin" },
    .{ .CssSelectors, "css_selectors.bin" },
    .{ .CssAtRules, "css_at_rules.bin" },
    .{ .JsIdentifiers, "js_identifiers.bin" },
});
pub var bin_map: std.EnumMap(BinKind, []const u8) = .init(.{});

const InitBinsError = error{
    NoLocalAppDataEnv,
    NoHomeEnv,
};

const CANIPLS_BINS_URL = "https://whencaniuse.com/canipls-bins.tar.gz";

pub fn init(allocator: std.mem.Allocator, io: std.Io, environ_map: *std.process.Environ.Map) !void {
    // build path to canipls bins
    var user_local_path: []const u8 = undefined;
    defer allocator.free(user_local_path);
    if (builtin.os.tag == .windows) {
        // TODO: there doesn't need to be an allocation here, but there *does* in the UNIX path below; how do I only free *that* memory, and not *this* one, at the end of the function?
        // luckily this string isn't very long so it is essentially inconsequential
        user_local_path = try allocator.dupe(u8, environ_map.get("LOCALAPPDATA") orelse return InitBinsError.NoLocalAppDataEnv);
    } else {
        // TODO: test this on raspberry pi
        const home_path = environ_map.get("HOME") orelse return InitBinsError.NoHomeEnv;
        user_local_path = try std.fs.path.join(allocator, &.{ home_path, ".cache" });
    }
    const canipls_bins_path = try std.fs.path.join(allocator, &.{ user_local_path, "canipls", "bins" });
    defer allocator.free(canipls_bins_path);

    // create that path if it doesn't exist
    const canipls_bins_dir = try std.Io.Dir.cwd().createDirPathOpen(io, canipls_bins_path, .{ .open_options = .{ .iterate = true } });

    // calculate the last 12:30 or 1:30 AM MDT?
    // NOTE: I'm not taking into account DST, just doing 7:30 AM UTC--translating to either 12:30 AM or 1:30 AM MDT.
    // This time isn't terribly important, but will be *roughly* soon after the data on my server updates (midnight MDT).
    const now = std.Io.Timestamp.now(io, .real);
    const now_ms = now.toMilliseconds();
    const last_midnight_utc_ms = now_ms - (@mod(now_ms, std.time.ms_per_day));
    const last_seven_thirty_am_utc_ms = last_midnight_utc_ms + (std.time.ms_per_hour * 7) + (std.time.ms_per_min * 30);

    // stat any file inside that dir to see when we last fetched
    fetch_new_tarball_if_out_of_date: {
        var canipls_bins_dir_iterator = canipls_bins_dir.iterate();
        if (try canipls_bins_dir_iterator.next(io)) |entry| {
            if (entry.kind == .file) {
                const stat = try canipls_bins_dir.statFile(io, entry.name, .{});
                const last_modification_time = stat.mtime;
                // if (last_modification_time.toMilliseconds() >= last_seven_thirty_am_utc_ms) break :fetch_new_tarball_if_out_of_date;
                // DEBUG: (just to force it to fetch every time)
                if (last_modification_time.toMilliseconds() < last_seven_thirty_am_utc_ms) break :fetch_new_tarball_if_out_of_date;

                // get latest archive from url
                var bins_tarball_buf: [std.math.maxInt(u16)]u8 = undefined; // NOTE: only allows a tarball up to 65,536 bytes! Will need to expand when necessary!
                var fetch_response_writer = std.Io.Writer.fixed(&bins_tarball_buf);
                var client: std.http.Client = .{ .allocator = allocator, .io = io };
                defer client.deinit();
                const fetch_res = try client.fetch(.{
                    .location = .{ .url = CANIPLS_BINS_URL },
                    .method = .GET,
                    .response_writer = &fetch_response_writer,
                });
                if (fetch_res.status.class() == .success) {
                    log.info("bin files tarball fetch success! Num bytes received: {d}", .{fetch_response_writer.end});

                    const bins_tarball = bins_tarball_buf[0..fetch_response_writer.end];
                    var bins_tarball_reader = std.Io.Reader.fixed(bins_tarball);
                    var bins_tarball_decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
                    var bins_tarball_decompress = std.compress.flate.Decompress.init(&bins_tarball_reader, .gzip, &bins_tarball_decompress_buf);
                    try std.tar.extract(io, canipls_bins_dir, &bins_tarball_decompress.reader, .{});
                } else {
                    log.err("could not fetch canipls-bins tarball. fetch error class: {}", .{fetch_res.status.class()});
                    if (fetch_res.status.phrase()) |phrase| {
                        log.info("fetch error phrase: {s}", .{phrase});
                    }
                    // TODO: calculate just how out of date the data is; either quit the whole program if it's like > 2 weeks, otherwise explicitly say how out of date it is
                    log.warn("canipls will continue to function on existing data, which may be at least a day out of date.", .{});
                    break :fetch_new_tarball_if_out_of_date;
                }
            }
        }
    }

    // stat any file in AppData/Local/canipls/bins/
    // check its date
    // is it older than the most recent 12:30 AM MDT?
    // if so:
    //   clear the contents of AppData/Local/canipls/bins
    //   fetch the new archive from https://whencaniuse.com/canipls-bins.tar.gz
    //   extract the archive into AppData/Local/canipls/bins
    //   delete the archive
    // open and read all bins' contents into `bin_map` data structure
    // close all files
    //
    // std.tar.extract()
}

pub fn deinit(
    /// Must be the same allocator passed into `init()`.
    allocator: std.mem.Allocator,
) void {
    for (bin_map.values) |bin| {
        allocator.free(bin);
    }
}
