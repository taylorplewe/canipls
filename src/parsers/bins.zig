const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const utils = @import("../utils.zig");
const types = @import("../types.zig");

const log = std.log.scoped(.canipls);

const BIN_FILE_STRING_WIDTH = 32;

const Bin = struct {
    data: []const u8,
    sizeof_section: std.EnumArray(BinSection, usize),
    section_addr: std.EnumArray(BinSection, usize),

    /// Search this bin file from feature index `index_start` (inclusive) to `index_end` (exclusive) for `identifier_buf`; return index of feature if found
    fn searchRangeForSymbol(
        self: *const Bin,
        index_start: usize,
        index_end: usize,
        name_padded: []const u8,
    ) ?usize {
        for (index_start..index_end) |i| {
            const next_identifier_offset = self.section_addr.get(.Identifier) + (i * sizeof_entry_per_bin_section.get(.Identifier));
            const name_in_bin = self.data[next_identifier_offset..][0..BIN_FILE_STRING_WIDTH];

            // TODO: simd vector search
            if (std.mem.eql(u8, name_padded, name_in_bin)) return i;
        }
        return null;
    }

    fn getAlignedValueByIndex(
        self: *const Bin,
        index: usize,
        comptime S: BinSection,
    ) typeof_entry_per_section.get(S) {
        const val_addr = self.section_addr.get(S) + (index * sizeof_entry_per_bin_section.get(S));
        return utils.getValueFromDataAligned(typeof_entry_per_section.get(S), self.data[val_addr..]);
    }
};

const BinSection = enum {
    Support,
    CiuIdAddr,
    Reserved,
    FirstChildIndex,
    NumChildren,
    TreeSitterSyntaxNodeType,
    Identifier,
};
const typeof_entry_per_section: std.EnumArray(BinSection, type) = .init(.{
    .Support = f32,
    .CiuIdAddr = u32,
    .Reserved = u32,
    .FirstChildIndex = u32,
    .NumChildren = u16,
    .TreeSitterSyntaxNodeType = u8,
    .Identifier = [BIN_FILE_STRING_WIDTH]u8,
});

var bin_kind_to_file_path_map: std.EnumMap(types.TsNodeKind, []const u8) = .init(.{
    .HtmlTag = "html_tags.bin",
    .HtmlAttribute = "html_attributes.bin",
    .CssProperty = "css_props.bin",
    .CssSelector = "css_selectors.bin",
    .CssAtRule = "css_at_rules.bin",
    .JsIdentifier = "js_identifiers.bin",
});
fn getBinKindFromPath(path_to_check: []const u8) ?types.TsNodeKind {
    var it = bin_kind_to_file_path_map.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, path_to_check, entry.value.*)) return entry.key;
    }
    return null;
}
pub var bin_map: std.EnumMap(types.TsNodeKind, []const u8) = .init(.{});

const InitBinsError = error{
    NoLocalAppDataEnv,
    NoHomeEnv,
    IncompatibleCaniplsVersion,
};

// const CANIPLS_BINS_URL = "https://whencaniuse.com/canipls-bins.tar.gz";
const CANIPLS_BINS_URL = "https://whencaniuse.com/canipls-bins-new.tar.gz"; // TEMP !

pub fn init(server_allocator: std.mem.Allocator, io: std.Io, environ_map: *std.process.Environ.Map) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // build path to canipls bins
    var user_local_path: []const u8 = undefined;
    if (builtin.os.tag == .windows) {
        user_local_path = environ_map.get("LOCALAPPDATA") orelse return InitBinsError.NoLocalAppDataEnv;
    } else {
        const home_path = environ_map.get("HOME") orelse return InitBinsError.NoHomeEnv;
        user_local_path = try std.fs.path.join(arena.allocator(), &.{ home_path, ".cache" });
    }
    const canipls_bins_path = try std.fs.path.join(arena.allocator(), &.{ user_local_path, "canipls", "bins" });

    // create that path if it doesn't exist
    const canipls_bins_dir = try std.Io.Dir.cwd().createDirPathOpen(io, canipls_bins_path, .{ .open_options = .{ .iterate = true } });
    defer canipls_bins_dir.close(io);

    // calculate the last 12:30 or 1:30 AM MDT?
    // NOTE: I'm not taking into account DST, just doing 7:30 AM UTC--translating to either 12:30 AM or 1:30 AM MDT.
    // This time isn't terribly important, but will be *roughly* soon after the data on my server updates (midnight MDT).
    const now = std.Io.Timestamp.now(io, .real);
    const now_ms = now.toMilliseconds();
    const last_midnight_utc_ms = now_ms - (@mod(now_ms, std.time.ms_per_day));
    const last_seven_thirty_am_utc_ms = last_midnight_utc_ms + (std.time.ms_per_hour * 7) + (std.time.ms_per_min * 30);

    // stat any file inside that dir to see when we last fetched
    fetch_new_tarball_if_out_of_date: {
        // check to make sure we have all necessary files, and none are out of date
        var checked_files: std.EnumMap(types.TsNodeKind, bool) = .init(.{});
        var oldest_timestamp_ms: i64 = now_ms;
        var canipls_bins_dir_iterator = canipls_bins_dir.iterateAssumeFirstIteration();
        while (try canipls_bins_dir_iterator.next(io)) |entry| {
            const stat = try canipls_bins_dir.statFile(io, entry.name, .{});
            const last_modification_time_ms = stat.mtime.toMilliseconds();
            if (last_modification_time_ms < oldest_timestamp_ms) oldest_timestamp_ms = last_modification_time_ms;
            if (getBinKindFromPath(entry.name)) |kind| checked_files.put(kind, true);
        }
        var are_all_files_present = true;
        var bin_kind_map = bin_kind_to_file_path_map.iterator();
        while (bin_kind_map.next()) |entry| {
            if (checked_files.get(entry.key)) |checked_file| {
                if (checked_file) {
                    are_all_files_present = false;
                    break;
                }
            } else {
                are_all_files_present = false;
                break;
            }
        }

        log.info("all files here!", .{});

        var checked_files_it = checked_files.iterator();
        while (checked_files_it.next()) |entry| {
            if (entry.value.* == false) are_all_files_present = false;
        }

        // don't need to fetch new tarball?
        if (false and are_all_files_present and oldest_timestamp_ms >= last_seven_thirty_am_utc_ms) break :fetch_new_tarball_if_out_of_date;

        log.info("fetching new canipls bin files tarball...", .{});

        // clear out directory
        canipls_bins_dir_iterator = canipls_bins_dir.iterate();
        while (try canipls_bins_dir_iterator.next(io)) |entry| {
            try canipls_bins_dir.deleteFile(io, entry.name);
        }

        // get latest archive from url
        const SIZEOF_FETCH_BUF = 400_000; // as of May 31, 2026, the tarball is only 216,704 B
        var bins_tarball_buf: [SIZEOF_FETCH_BUF]u8 = undefined; // NOTE: only allows a tarball up to 65,536 bytes! Will need to expand when necessary!
        var fetch_response_writer = std.Io.Writer.fixed(&bins_tarball_buf);
        var client: std.http.Client = .{ .allocator = arena.allocator(), .io = io };
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

    // load bin files' contents into bin map
    errdefer deinit(server_allocator);
    var canipls_bins_dir_it = canipls_bins_dir.iterate();
    while (try canipls_bins_dir_it.next(io)) |entry| {
        const bin = try canipls_bins_dir.readFileAlloc(io, entry.name, server_allocator, .unlimited);
        const bin_kind = getBinKindFromPath(entry.name).?;
        bin_map.put(bin_kind, bin);

        // check that this version of canipls is compatible with every bin file
        const min_compatible_canipls_version = utils.getValueFromDataAligned(u32, bin[0..]);
        _ = min_compatible_canipls_version;
        const is_canipls_version_compatible =
            if (bin[0] > build_options.version.major)
                false
            else if (bin[1] > build_options.version.minor)
                false
            else if (bin[2] > build_options.version.patch)
                false
            else
                true;
        if (!is_canipls_version_compatible) {
            log.err("out-of-date canipls version {d}.{d}.{d} is incompatible with binary file, which requires >= v{d}.{d}.{d}", .{
                build_options.version.major,
                build_options.version.minor,
                build_options.version.patch,
                bin[0],
                bin[1],
                bin[2],
            });
            log.err("exiting", .{});
            return InitBinsError.IncompatibleCaniplsVersion;
        }
    }
}

pub fn deinit(
    /// Must be the same allocator passed into `init()`.
    server_allocator: std.mem.Allocator,
) void {
    for (bin_map.values) |bin| {
        server_allocator.free(bin);
    }
}

var sizeof_entry_per_bin_section: std.EnumArray(BinSection, usize) = blk: {
    var sizes: std.EnumArray(BinSection, usize) = .initFill(0);
    for (typeof_entry_per_section.values, 0..) |T, i| {
        sizes.set(@enumFromInt(i), @sizeOf(T));
    }
    break :blk sizes;
};
var identifier_buf: [BIN_FILE_STRING_WIDTH]u8 = undefined;
pub fn getSupportPercentageAndCiuIdForIdentifierFromBin(
    identifier_name: []const u8,
    bin: []const u8,
) ?struct { f32, []const u8 } {
    if (identifier_name.len > BIN_FILE_STRING_WIDTH) return null;

    // make identifier name in question 32-chars wide, padded with 0's
    @memcpy(identifier_buf[0..identifier_name.len], identifier_name);
    if (identifier_name.len < 32)
        @memset(identifier_buf[identifier_name.len..], 0);

    const num_features_total = utils.getValueFromDataAligned(u32, bin[4..]);
    const num_features_toplevel = utils.getValueFromDataAligned(u32, bin[8..]);

    const sizeof_bin_sections: std.EnumArray(BinSection, usize) = blk: {
        var sizes: std.EnumArray(BinSection, usize) = .initFill(0);
        for (sizeof_entry_per_bin_section.values, 0..) |size, i| {
            sizes.set(@enumFromInt(i), size * num_features_total);
        }
        break :blk sizes;
    };

    const section_addrs: std.EnumArray(BinSection, usize) = blk: {
        var addrs: std.EnumArray(BinSection, usize) = .initFill(0);
        var current_pos: usize = sizeof_header;
        for (sizeof_bin_sections.values, 0..) |size, i| {
            addrs.set(@enumFromInt(i), current_pos);
            current_pos += size;
        }
        break :blk addrs;
    };

    const my_bin: Bin = .{
        .data = bin,
        .sizeof_section = sizeof_bin_sections,
        .section_addr = section_addrs,
    };

    const feature_index = my_bin.searchRangeForSymbol(0, num_features_toplevel, &identifier_buf) orelse return null;
    const ciu_id_addr = my_bin.getAlignedValueByIndex(feature_index, .CiuIdAddr);
    const ciu_id_len = bin[ciu_id_addr];
    const ciu_id = bin[ciu_id_addr + 1 ..][0..ciu_id_len];
    const support_percentage = my_bin.getAlignedValueByIndex(feature_index, .Support);
    return .{ support_percentage, ciu_id };
}

pub const BinSearchSymbolInfo = struct {
    name: []const u8,
    node_kind: types.TsNodeKind,
};
pub const BinSearchResult = struct {
    support: f32,
    ciu_id: []const u8,
};
const sizeof_header = @sizeOf(u32) * 4;
/// Given a syntactic stack of symbols, search a canipls bin file for the bottom-most symbol in the stack
pub fn getSymbolSupportInfoFromBin(symbol_stack: []BinSearchSymbolInfo) ?BinSearchResult {
    // get target bin file from top-level symbol
    const bin = bin_map.get(symbol_stack[0].node_kind) orelse return null;
    const num_features_total = utils.getValueFromDataAligned(u32, bin[4..]);
    const num_features_toplevel = utils.getValueFromDataAligned(u32, bin[8..]);

    const sizeof_bin_sections: std.EnumArray(BinSection, usize) = blk: {
        var sizes: std.EnumArray(BinSection, usize) = .initFill(0);
        for (sizeof_entry_per_bin_section.values, 0..) |size, i|
            sizes.set(@enumFromInt(i), size * num_features_total);
        break :blk sizes;
    };

    const section_addrs: std.EnumArray(BinSection, usize) = blk: {
        var addrs: std.EnumArray(BinSection, usize) = .initFill(0);
        var current_pos: usize = sizeof_header;
        for (sizeof_bin_sections.values, 0..) |size, i| {
            addrs.set(@enumFromInt(i), current_pos);
            current_pos += size.value.*;
        }
        break :blk addrs;
    };

    const my_bin: Bin = .{
        .data = bin,
        .sizeof_section = sizeof_bin_sections,
        .section_addr = section_addrs,
    };

    var parent_feature_index: ?usize = null;
    for (symbol_stack, 0..) |symbol_info, symbol_stack_index| {
        const name = symbol_info.name;
        if (name.len > BIN_FILE_STRING_WIDTH) return null;

        // make identifier name in question 32-chars wide, padded with 0's
        @memcpy(identifier_buf[0..name.len], name);
        if (name.len < 32)
            @memset(identifier_buf[name.len..], 0);

        // toplevel feature?
        if (parent_feature_index == null) {
            parent_feature_index = searchBinRangeForSymbol(
                bin,
                &section_addrs,
                0,
                num_features_toplevel,
            ) orelse return null;
        } else {
            // const first_child_index_addr = section_addrs.get(.FirstChildIndex) + (parent_feature_index.? * sizeof_bin_sections.get(.FirstChildIndex));
            const num_children_addr = section_addrs.get(.NumChildren) + (parent_feature_index.? * sizeof_bin_sections.get(.NumChildren));
            // const first_child_index = utils.getValueFromDataAligned(u32, bin[first_child_index_addr..]);
            const num_children = utils.getValueFromDataAligned(u16, bin[num_children_addr..]);
            const first_child_index = my_bin.getAlignedValueByIndex(parent_feature_index.?, .FirstChildIndex);

            parent_feature_index = searchBinRangeForSymbol(
                bin,
                &section_addrs,
                first_child_index,
                first_child_index + num_children,
            ) orelse return null;
        }
        // feature we're looking for? (bottom of stack)
        if (symbol_stack_index == symbol_stack.len - 1) {
            const support_addr = section_addrs.get(.Support) + (parent_feature_index.? * sizeof_bin_sections.get(.Support));
            const support = utils.getValueFromDataAligned(f32, bin[support_addr..]);
            const ciu_id_addr = section_addrs.get(.CiuIdAddr) + (parent_feature_index.? * sizeof_bin_sections.get(.CiuIdAddr));
            const ciu_id_len = bin[ciu_id_addr];
            const ciu_id = bin[ciu_id_addr + 1 .. ciu_id_addr + 1 + ciu_id_len];
            return .{ .support = support, .ciu_id = ciu_id };
        }
    }

    return null;
}

/// Search `bin` from feature index `index_start` (inclusive) to `index_end` (exclusive) for `identifier_buf`; return index of feature if found
fn searchBinRangeForSymbol(
    bin: []const u8,
    section_addrs: *std.EnumArray(BinSection, usize),
    index_start: usize,
    index_end: usize,
) ?usize {
    for (index_start..index_end) |i| {
        const next_identifier_offset = section_addrs.get(.Identifier) + (i * sizeof_entry_per_bin_section.get(.Identifier));
        const name_in_bin = bin[next_identifier_offset..][0..BIN_FILE_STRING_WIDTH];

        // TODO: simd vector search
        if (std.mem.eql(u8, &identifier_buf, name_in_bin)) return i;
    }
    return null;
}
