//! `zig build icon`: mac-toolkit's icon, three sliders on the cream tile of
//! nanoview's, nanocaffeinate's and nanolight's icons, on Apple's macOS icon
//! grid (an 824-pixel tile in 1024) with a soft shadow under the tile.
//!
//! Every shape is a signed distance, so its edge is anti-aliased. This draws
//! macos/icon.png, then the Mac's own sips and iconutil make
//! macos/AppIcon.icns from it. Run from the repository's root (build.zig does).
const std = @import("std");
const assert = std.debug.assert;
const flate = std.compress.flate;
const Io = std.Io;

const size = 1024;
const channels = 4;
const Rgb = [3]f64;
const tile_color: Rgb = .{ 0xF0, 0xEB, 0xE0 };
const track_color: Rgb = .{ 0x1E, 0x1E, 0x1E };
const knob_color: Rgb = .{ 0xD8, 0x3A, 0x2B };
const shadow_color: Rgb = .{ 0, 0, 0 };

const center = 512.0;
const tile: Box = .{
    .x = center,
    .y = center,
    .half_width = 412,
    .half_height = 412,
    .radius = 185,
};
/// Three sliders: a track each, and a knob where its utility is set.
const track: Box = .{ .x = center, .y = 0, .half_width = 286, .half_height = 30, .radius = 30 };
const track_ys = [_]f64{ 320, 512, 704 };
const knob_xs = [_]f64{ 356, 668, 470 };
const knob_radius = 54.0;
const shadow_y = 10.0;
const shadow_sigma = 14.0;
const shadow_alpha = 0.30;

comptime {
    // The tile and the reach of its shadow fit the canvas.
    assert(center + tile.half_height + shadow_y + 4 * shadow_sigma < size);
    // The first and last tracks clear the tile's round corners.
    assert(track_ys[0] - track.half_height > center - tile.half_height + tile.radius);
    assert(track_ys[track_ys.len - 1] + track.half_height < center + tile.half_height);
    // Every knob sits on its track, inside the track's ends.
    for (track_ys, knob_xs) |y, knob_x| {
        _ = y;
        assert(knob_x - knob_radius >= center - track.half_width);
        assert(knob_x + knob_radius <= center + track.half_width);
    }
}

extern "c" fn erfc(x: f64) f64;

const icon_path = "macos/icon.png";
const icns_path = "macos/AppIcon.icns";
const iconset = "/tmp/mac-toolkit-icon/AppIcon.iconset";
/// The iconset's sizes, each also at twice the size (`@2x`).
const iconset_sides = [_]u32{ 16, 32, 128, 256, 512 };
const path_bytes_max = 128;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const pixels = try arena.alloc(u8, size * size * channels);
    draw(pixels);
    var out: Io.Writer.Allocating = .init(arena);
    try write_png(arena, &out.writer, pixels);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = icon_path, .data = out.written() });

    try Io.Dir.cwd().createDirPath(io, iconset);
    for (iconset_sides) |side| {
        var one: [path_bytes_max]u8 = undefined;
        const one_path = try std.mem.print(&one, "{s}/icon_{d}x{d}.png", .{ iconset, side, side });
        try resize(io, arena, side, one_path);
        var two: [path_bytes_max]u8 = undefined;
        const two_path = try std.mem.print(&two, "{s}/icon_{d}x{d}@2x.png", .{
            iconset, side, side,
        });
        try resize(io, arena, side * 2, two_path);
    }
    try run(io, arena, &.{ "iconutil", "-c", "icns", "-o", icns_path, iconset });
}

/// macos/icon.png made `side` pixels square by sips, at `to`.
fn resize(io: Io, arena: std.mem.Allocator, side: u32, to: []const u8) !void {
    assert(side > 0 and side <= size);
    var text: [10]u8 = undefined;
    const side_text = try std.mem.print(&text, "{d}", .{side});
    try run(io, arena, &.{ "sips", "-z", side_text, side_text, icon_path, "--out", to });
}

/// Runs `argv`; unless it exits 0, prints what it said and fails.
fn run(io: Io, arena: std.mem.Allocator, argv: []const []const u8) !void {
    assert(argv.len > 0);
    const result = try std.process.run(arena, io, .{ .argv = argv });
    if (result.term.success()) return;
    std.debug.print("{s}: {s}{s}\n", .{ argv[0], result.stdout, result.stderr });
    return error.CommandFailed;
}

/// Writes `pixels` (rows of straight-alpha RGBA, top first) as one PNG, each
/// row unfiltered.
fn write_png(gpa: std.mem.Allocator, writer: *Io.Writer, pixels: []const u8) !void {
    const row_bytes = size * channels;
    assert(pixels.len == row_bytes * size);
    // The compressor asserts that its output already has room.
    var data: Io.Writer.Allocating = try .initCapacity(gpa, pixels.len / 2);
    defer data.deinit();
    const compressor = try gpa.create(flate.Compress);
    defer gpa.destroy(compressor);
    const history = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(history);
    compressor.* = try .init(&data.writer, history, .zlib, .best);
    for (0..size) |row| {
        try compressor.writer.writeByte(0); // filter: none
        try compressor.writer.writeAll(pixels[row * row_bytes ..][0..row_bytes]);
    }
    try compressor.finish();

    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], size, .big);
    std.mem.writeInt(u32, header[4..8], size, .big);
    header[8..].* = .{ 8, 6, 0, 0, 0 }; // 8 bits a channel, RGBA
    try writer.writeAll("\x89PNG\r\n\x1a\n");
    try write_chunk(writer, "IHDR", &header);
    try write_chunk(writer, "IDAT", data.written());
    try write_chunk(writer, "IEND", "");
}

fn write_chunk(writer: *Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try writer.writeInt(u32, @intCast(data.len), .big);
    try writer.writeAll(kind);
    try writer.writeAll(data);
    try writer.writeInt(u32, crc.final(), .big);
}

/// The whole icon, row by row, each pixel sampled at its centre.
fn draw(pixels: []u8) void {
    assert(pixels.len == size * size * channels);
    for (0..size) |row| {
        for (0..size) |column| {
            const x = @as(f64, @floatFromInt(column)) + 0.5;
            const y = @as(f64, @floatFromInt(row)) + 0.5;
            const at = (row * size + column) * channels;
            pixels[at..][0..4].* = straight(pixel(x, y));
        }
    }
}

/// Premultiplied red, green, blue and alpha.
const Premultiplied = [4]f64;

/// Straight alpha, as PNG keeps it.
fn straight(px: Premultiplied) [4]u8 {
    const alpha = px[3];
    if (!(alpha > 0.0)) return .{ 0, 0, 0, 0 };
    return .{
        byte_of(px[0] / alpha),
        byte_of(px[1] / alpha),
        byte_of(px[2] / alpha),
        byte_of(alpha * 255),
    };
}

fn byte_of(value: f64) u8 {
    assert(value >= 0 and value < 255.5);
    return @intFromFloat(@round(value));
}

fn pixel(x: f64, y: f64) Premultiplied {
    var px: Premultiplied = .{ 0, 0, 0, 0 };
    const shadow_distance = tile.distance(x, y - shadow_y);
    if (shadow_distance < 4 * shadow_sigma) {
        const spread = shadow_distance / (shadow_sigma * @sqrt(2.0));
        px = over(px, shadow_color, shadow_alpha * 0.5 * erfc(spread));
    }
    px = over(px, tile_color, cover(tile.distance(x, y)));
    for (track_ys) |y_of_track| {
        var at: Box = track;
        at.y = y_of_track;
        px = over(px, track_color, cover(at.distance(x, y)));
    }
    // The knobs sit over their tracks.
    for (track_ys, knob_xs) |y_of_knob, knob_x| {
        const knob: Ellipse = .{
            .x = knob_x,
            .y = y_of_knob,
            .radius_x = knob_radius,
            .radius_y = knob_radius,
        };
        px = over(px, knob_color, cover(knob.distance(x, y)));
    }
    return px;
}

/// A rounded rectangle.
const Box = struct {
    x: f64,
    y: f64,
    half_width: f64,
    half_height: f64,
    radius: f64,

    fn distance(box: Box, x: f64, y: f64) f64 {
        assert(box.radius <= @min(box.half_width, box.half_height));
        const qx = @abs(x - box.x) - (box.half_width - box.radius);
        const qy = @abs(y - box.y) - (box.half_height - box.radius);
        const outside = std.math.hypot(@max(qx, 0.0), @max(qy, 0.0));
        return outside + @min(@max(qx, qy), 0.0) - box.radius;
    }
};

/// The first-order distance: exact enough at the edge, where it decides the cover.
const Ellipse = struct {
    x: f64,
    y: f64,
    radius_x: f64,
    radius_y: f64,

    fn distance(ellipse: Ellipse, x: f64, y: f64) f64 {
        const dx = x - ellipse.x;
        const dy = y - ellipse.y;
        const reach = std.math.hypot(dx / ellipse.radius_x, dy / ellipse.radius_y);
        if (reach == 0.0) return -@min(ellipse.radius_x, ellipse.radius_y);
        const gradient_x = dx / (ellipse.radius_x * ellipse.radius_x * reach);
        const gradient_y = dy / (ellipse.radius_y * ellipse.radius_y * reach);
        return (reach - 1.0) / std.math.hypot(gradient_x, gradient_y);
    }
};
/// A shape's share of a pixel, from the distance at its centre.
fn cover(distance: f64) f64 {
    return @min(1.0, @max(0.0, 0.5 - distance));
}

/// Paints `rgb` at alpha `alpha` over the premultiplied `px`.
fn over(px: Premultiplied, rgb: Rgb, alpha: f64) Premultiplied {
    if (alpha <= 0.0) return px;
    const keep = 1.0 - alpha;
    return .{
        rgb[0] * alpha + px[0] * keep,
        rgb[1] * alpha + px[1] * keep,
        rgb[2] * alpha + px[2] * keep,
        alpha + px[3] * keep,
    };
}
