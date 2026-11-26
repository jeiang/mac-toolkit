//! The one menu bar icon and its menu: three small utilities behind one icon.
//! Keep Awake runs `/usr/bin/caffeinate` with the flags and duration chosen in
//! its submenu; Keep Media Loud exempts the output device from the ducking a
//! call asks for; Natural Scrolling reverses a mouse wheel and leaves the
//! trackpad with the direction System Settings chose.
//!
//! One timer passes over all three: it reaps a caffeinate that ended on its
//! own, repeats the duck write, and starts the tap once macOS allows it.
const std = @import("std");
const assert = std.debug.assert;
const nanoui = @import("nanoui");
const caffeinate = @import("caffeinate.zig");
const duck = @import("duck.zig");
const scroll = @import("scroll.zig");
const Keeper = @import("keeper.zig").Keeper;
const Timer = @import("timer.zig").Timer;

pub const app_name = "mac-toolkit";

const MenuItem = nanoui.menu.MenuItem;
const Item = nanoui.menu.Item;

/// SF Symbols: the toolkit's sliders in the menu bar, whatever the state.
const symbol = "slider.horizontal.3";
/// macOS re-ducks for as long as a call lasts, so the write repeats; Unduck
/// Pro's 500 ms stays ahead of it. The same pass reaps caffeinate and starts a
/// tap macOS had refused.
const pass_ms = 500;
const awake_id = "awake";
const duck_id = "duck";
const scroll_id = "scroll";
const settings_key = "settings";
const duck_key = "duck";
const scroll_key = "scroll";
const tooltip_bytes_max = 128;
const duration_count = @typeInfo(caffeinate.Duration).@"enum".field_names.len;

/// What the last pass found of macOS's ducking.
const Media = enum { loud, ducks, stuck, no_device, no_property, read_only, failed };

pub const Menu = struct {
    app: *nanoui.App,
    keeper: Keeper,
    kv: nanoui.kv.Store,
    settings: caffeinate.Settings = .{},
    /// Keep Media Loud, on until turned off.
    ducking: bool = true,
    guard: duck.Guard = .{},
    reverser: scroll.Reverser = .{},
    media: Media = .loud,
    /// caffeinate would not start, until it starts or is turned off.
    awake_failed: bool = false,
    tray: ?*nanoui.Tray = null,
    tick: Timer = .{},
    tooltip_buffer: [tooltip_bytes_max]u8 = undefined,

    pub fn start(menu: *Menu) !void {
        assert(menu.tray == null);
        menu.settings = load_settings(menu.kv);
        menu.ducking = load_flag(menu.kv, duck_key, true);
        menu.reverser.enabled = load_flag(menu.kv, scroll_key, true);
        var flags: [caffeinate.flag_count]MenuItem = undefined;
        for (std.enums.values(caffeinate.Flag), &flags) |flag, *item| item.* = .{
            .label = flag.label(),
            .id = @tagName(flag),
            .kind = .checkbox,
            .checked = menu.settings.flags.contains(flag),
            .click = .of(menu, flag_clicked),
        };
        var durations: [duration_count]MenuItem = undefined;
        for (std.enums.values(caffeinate.Duration), &durations) |duration, *item| item.* = .{
            .label = duration.label(),
            .id = @tagName(duration),
            .kind = .radio,
            .checked = menu.settings.duration == duration,
            .click = .of(menu, duration_clicked),
        };
        const options = [_]MenuItem{} ++ flags ++ [_]MenuItem{.separator} ++ durations;
        const items = [_]MenuItem{
            .{
                .label = "Keep Awake",
                .id = awake_id,
                .kind = .checkbox,
                .click = .of(menu, awake_clicked),
            },
            .{ .label = "Keep Awake Options", .submenu = &options },
            .separator,
            .{
                .label = "Keep Media Loud",
                .id = duck_id,
                .kind = .checkbox,
                .checked = menu.ducking,
                .click = .of(menu, duck_clicked),
            },
            .separator,
            .{
                .label = "Natural Scrolling",
                .id = scroll_id,
                .kind = .checkbox,
                .checked = menu.reverser.enabled,
                .tooltip = "A mouse wheel scrolls the classic way; the trackpad keeps macOS's natural direction",
                .click = .of(menu, scroll_clicked),
            },
            .separator,
            .{ .label = "Quit " ++ app_name, .accelerator = "Cmd+Q", .role = .quit },
        };
        menu.tray = try menu.app.newTray(.{ .symbol = symbol, .menu = &items });
        menu.apply();
        // Only macOS can ask for the tap's grant, and one dialog a launch is
        // enough: a switch that is on with nothing behind it is worse.
        if (menu.reverser.enabled and !menu.reverser.running()) scroll.prompt();
    }

    /// Ends what the menu started: the tick, caffeinate, the tap, and the
    /// exemption, which would outlive all three.
    pub fn stop(menu: *Menu) void {
        menu.tick.stop();
        if (menu.keeper.running()) menu.keeper.stop();
        if (menu.reverser.running()) menu.reverser.stop();
        _ = menu.guard.release();
    }

    /// One pass: reap caffeinate if it ended on its own, hold the media loud,
    /// start the tap macOS may have started allowing, and keep the tick only
    /// while something still needs it.
    fn apply(menu: *Menu) void {
        if (menu.keeper.reap()) menu.show_awake();
        menu.media = if (!menu.ducking) blk: {
            break :blk if (menu.guard.release()) |_| Media.stuck else .ducks;
        } else switch (menu.guard.hold()) {
            .held => .loud,
            .no_device => .no_device,
            .no_property => .no_property,
            .read_only => .read_only,
            .failed => .failed,
        };
        if (menu.reverser.enabled and !menu.reverser.running() and scroll.trusted()) {
            _ = menu.reverser.start();
        }
        menu.show_tooltip();
        menu.tick_while_needed();
    }

    fn awake_clicked(menu: *Menu, item: *Item) void {
        if (item.checked) menu.start_caffeinate() else menu.stop_caffeinate();
    }

    fn flag_clicked(menu: *Menu, item: *Item) void {
        const flag = std.meta.stringToEnum(caffeinate.Flag, item.id).?;
        menu.settings.flags.setPresent(flag, item.checked);
        menu.settings_changed();
    }

    fn duration_clicked(menu: *Menu, item: *Item) void {
        menu.settings.duration = std.meta.stringToEnum(caffeinate.Duration, item.id).?;
        menu.settings_changed();
    }

    fn duck_clicked(menu: *Menu, item: *Item) void {
        menu.ducking = item.checked;
        keep_flag(menu.kv, duck_key, menu.ducking);
        menu.apply();
    }

    fn scroll_clicked(menu: *Menu, item: *Item) void {
        menu.reverser.enabled = item.checked;
        keep_flag(menu.kv, scroll_key, menu.reverser.enabled);
        if (!menu.reverser.enabled) {
            if (menu.reverser.running()) menu.reverser.stop();
        } else if (!menu.reverser.running()) {
            // A tap that changes events needs the grant; macOS shows its
            // prompt, and the next pass starts the tap once it is given.
            if (!scroll.trusted()) scroll.prompt();
            _ = menu.reverser.start();
        }
        menu.apply();
    }

    fn settings_changed(menu: *Menu) void {
        var buffer: [caffeinate.Settings.text_bytes_max]u8 = undefined;
        menu.kv.set(settings_key, menu.settings.encode(&buffer)) catch |err| {
            std.log.warn("the settings are kept for this run only: {t}", .{err});
        };
        if (!menu.keeper.running()) return;
        menu.keeper.stop();
        menu.start_caffeinate();
    }

    fn start_caffeinate(menu: *Menu) void {
        assert(!menu.keeper.running());
        menu.keeper.start(menu.settings) catch |err| {
            std.log.err("{s} did not start: {t}", .{ caffeinate.program, err });
            menu.awake_failed = true;
            menu.show_awake();
            return;
        };
        menu.awake_failed = false;
        menu.show_awake();
    }

    fn stop_caffeinate(menu: *Menu) void {
        menu.keeper.stop();
        menu.awake_failed = false;
        menu.show_awake();
    }

    /// The Keep Awake check and the tooltip, as caffeinate now is.
    fn show_awake(menu: *Menu) void {
        const on = menu.keeper.running();
        assert(!(on and menu.awake_failed));
        if (menu.tray.?.menuItem(awake_id)) |item| item.setChecked(on);
        menu.show_tooltip();
        menu.tick_while_needed();
    }

    fn show_tooltip(menu: *Menu) void {
        const media: []const u8 = switch (menu.media) {
            .loud => "loud",
            .ducks => "ducks",
            .stuck => "exemption stuck",
            .no_device => "no output device",
            .no_property => "no duck exemption",
            .read_only => "exemption refused",
            .failed => "write failed",
        };
        const pointer: []const u8 = if (!menu.reverser.enabled)
            "mouse as set"
        else if (menu.reverser.running())
            "mouse reversed"
        else
            "mouse needs Accessibility";
        const awake: []const u8 = if (menu.awake_failed)
            "caffeinate did not start"
        else if (menu.keeper.running())
            "awake"
        else
            "asleep";
        const text = std.mem.print(
            &menu.tooltip_buffer,
            "{s} · media {s} · {s}",
            .{ awake, media, pointer },
        ) catch "mac-toolkit";
        menu.tray.?.setTooltip(text);
    }

    /// The tick runs while any of the three needs it: caffeinate to notice its
    /// end, the duck write to repeat, or the tap to come back.
    fn tick_while_needed(menu: *Menu) void {
        const needed = menu.keeper.running() or menu.ducking or menu.reverser.enabled;
        if (!needed) {
            if (menu.tick.running()) menu.tick.stop();
            return;
        }
        if (menu.tick.running()) return;
        if (!menu.tick.start(pass_ms, menu, pass)) {
            std.log.warn("no timer: media ducks during calls and caffeinate's end goes unseen", .{});
        }
    }
};

/// The kept settings, or the defaults when none are kept or they do not read.
fn load_settings(kv: nanoui.kv.Store) caffeinate.Settings {
    // Twice the longest text: a longer value is not one `encode` wrote.
    var buffer: [2 * caffeinate.Settings.text_bytes_max]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const text = kv.get(fixed.allocator(), settings_key) catch return .{};
    return caffeinate.Settings.decode(text orelse return .{}) orelse .{};
}

/// A kept switch, or `fallback` when none is kept.
fn load_flag(kv: nanoui.kv.Store, key: []const u8, fallback: bool) bool {
    var buffer: [8]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const text = kv.get(fixed.allocator(), key) catch return fallback;
    const kept = text orelse return fallback;
    if (kept.len != 1) return fallback;
    return switch (kept[0]) {
        '1' => true,
        '0' => false,
        else => fallback,
    };
}

fn keep_flag(kv: nanoui.kv.Store, key: []const u8, value: bool) void {
    kv.set(key, if (value) "1" else "0") catch |err| {
        std.log.warn("the {s} switch is kept for this run only: {t}", .{ key, err });
    };
}

fn pass(_: *anyopaque, context: ?*anyopaque) callconv(.c) void {
    const menu: *Menu = @ptrCast(@alignCast(context.?));
    assert(menu.tick.running());
    menu.apply();
}

const testing = std.testing;

test "a kept switch reads back, and anything else is the fallback" {
    var memory: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer memory.deinit();
    const kv = memory.store();
    try testing.expectEqual(true, load_flag(kv, "duck", true));
    keep_flag(kv, "duck", false);
    try testing.expectEqual(false, load_flag(kv, "duck", true));
    try testing.expectEqual(false, load_flag(kv, "duck", false));
    keep_flag(kv, "scroll", true);
    try testing.expectEqual(true, load_flag(kv, "scroll", false));
}
