//! mac-toolkit: small utilities behind one menu bar icon. It has no window and
//! no Dock icon; the icon's menu starts caffeinate, holds media loud through a
//! call, and reverses a mouse wheel while the trackpad stays natural.
//! `zig build run`, or `zig build app` and open zig-out/mac-toolkit.app.
const std = @import("std");
const nanoui = @import("nanoui");
const Menu = @import("menu.zig").Menu;
const app_name = @import("menu.zig").app_name;

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{
        .name = app_name,
        .quit_on_last_window_closed = false,
        .activation = .accessory,
    });
    defer app.destroy();
    var menu: Menu = .{ .app = app, .keeper = .{ .io = init.io }, .kv = nanoui.kv.standard() };
    // caffeinate's `-w` ends it with the app too; this ends it before the app
    // is gone, stops the tick, and takes the tap out of the event stream.
    defer menu.stop();
    try menu.start();
    try app.run();
}

test {
    _ = @import("caffeinate.zig");
    _ = @import("duck.zig");
    _ = @import("menu.zig");
    _ = @import("scroll.zig");
}
