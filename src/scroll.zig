//! macOS applies one scroll direction to every pointing device. A wheel mouse
//! sends discrete, line-based scroll events and a trackpad sends continuous,
//! pixel-based ones (`kCGScrollWheelEventIsContinuous`), so an event tap can
//! reverse the wheel and leave the trackpad with the direction System Settings
//! chose.
//!
//! A tap that changes events needs the Accessibility permission; without it
//! `CGEventTapCreate` returns null and no event is ever seen, so nothing is
//! left reversed. A mouse that scrolls smoothly, as Apple's and Logitech's do,
//! sends pixel-based events, which this leaves alone with the trackpad.
const std = @import("std");
const assert = std.debug.assert;

/// `kCGEventScrollWheel`, and the two types a tap reports instead of an event
/// when macOS has turned it off: it was too slow, or the user asked.
const event_scroll_wheel: u32 = 22;
const event_disabled_by_timeout: u32 = 0xffff_fffe;
const event_disabled_by_user_input: u32 = 0xffff_ffff;

/// `kCGHIDEventTap`: the wheel reaches the tap before the window server or any
/// app sees it. `kCGHeadInsertEventTap`, and `kCGEventTapOptionDefault`, which
/// changes the events the tap is given.
const location_hid: u32 = 0;
const placement_head: u32 = 0;
const option_default: u32 = 0;

/// `CGEventField` numbers, as CoreGraphics's CGEventTypes.h declares them. The
/// line count, the fixed-point 16.16 value and the pixel count are separate
/// fields, and an app reads whichever it knows.
const field_delta_axis1: u32 = 11;
const field_delta_axis2: u32 = 12;
const field_fixed_pt_delta_axis1: u32 = 93;
const field_fixed_pt_delta_axis2: u32 = 94;
const field_point_delta_axis1: u32 = 96;
const field_point_delta_axis2: u32 = 97;
/// Zero for a wheel's line-based events, nonzero for a trackpad's pixel-based
/// ones.
const field_is_continuous: u32 = 88;

/// An IOHIDEvent's scroll fields, from IOKit's IOHIDEvent.h:
/// `IOHIDEventFieldBase(kIOHIDEventTypeScroll)` is 6 << 16, plus the axis.
const hid_field_scroll_x: u32 = 6 << 16;
const hid_field_scroll_y: u32 = (6 << 16) | 1;

const core_graphics = struct {
    const Callback = *const fn (
        proxy: *anyopaque,
        kind: u32,
        event: ?*anyopaque,
        context: ?*anyopaque,
    ) callconv(.c) ?*anyopaque;

    extern "c" fn CGEventTapCreate(
        location: u32,
        placement: u32,
        option: u32,
        events: u64,
        callback: Callback,
        context: ?*anyopaque,
    ) ?*anyopaque;
    extern "c" fn CGEventTapEnable(tap: *anyopaque, enable: u8) void;
    extern "c" fn CGEventCreateScrollWheelEvent2(
        source: ?*anyopaque,
        units: u32,
        wheel_count: u32,
        wheel1: i32,
        wheel2: i32,
        wheel3: i32,
    ) ?*anyopaque;
    extern "c" fn CGEventGetIntegerValueField(event: *anyopaque, field: u32) i64;
    extern "c" fn CGEventSetIntegerValueField(event: *anyopaque, field: u32, value: i64) void;
    extern "c" fn CGEventGetDoubleValueField(event: *anyopaque, field: u32) f64;
    extern "c" fn CGEventSetDoubleValueField(event: *anyopaque, field: u32, value: f64) void;
    /// A Core Graphics SPI: the HID event the window server built this event
    /// from, or null for an event that had none. Chromium scrolls from it.
    extern "c" fn CGEventCopyIOHIDEvent(event: *anyopaque) ?*anyopaque;
    extern "c" fn AXIsProcessTrusted() u8;
    extern "c" fn AXIsProcessTrustedWithOptions(options: ?*anyopaque) u8;
    extern "c" const kAXTrustedCheckOptionPrompt: *anyopaque;
};

const iokit = struct {
    extern "c" fn IOHIDEventGetFloatValue(event: *anyopaque, field: u32) f64;
    extern "c" fn IOHIDEventSetFloatValue(event: *anyopaque, field: u32, value: f64) void;
};

const core_foundation = struct {
    extern "c" fn CFMachPortCreateRunLoopSource(
        allocator: ?*anyopaque,
        port: *anyopaque,
        order: isize,
    ) *anyopaque;
    extern "c" fn CFRunLoopAddSource(loop: *anyopaque, source: *anyopaque, mode: *anyopaque) void;
    extern "c" fn CFRunLoopRemoveSource(loop: *anyopaque, source: *anyopaque, mode: *anyopaque) void;
    extern "c" fn CFRunLoopGetMain() *anyopaque;
    extern "c" fn CFRelease(object: *anyopaque) void;
    extern "c" fn CFDictionaryCreate(
        allocator: ?*anyopaque,
        keys: [*]const ?*const anyopaque,
        values: [*]const ?*const anyopaque,
        count: isize,
        key_callbacks: ?*const anyopaque,
        value_callbacks: ?*const anyopaque,
    ) ?*anyopaque;
    extern "c" const kCFRunLoopCommonModes: *anyopaque;
    extern "c" const kCFBooleanTrue: *anyopaque;
    extern "c" const kCFTypeDictionaryKeyCallBacks: anyopaque;
    extern "c" const kCFTypeDictionaryValueCallBacks: anyopaque;
};

/// Whether macOS lets this process change input events. A tap that only
/// listens needs nothing; this one changes the wheel, so it does.
pub fn trusted() bool {
    return core_graphics.AXIsProcessTrusted() != 0;
}

/// Asks macOS to show the Accessibility prompt, which also lists this app in
/// System Settings for the user to grant.
pub fn prompt() void {
    const keys = [_]?*const anyopaque{core_graphics.kAXTrustedCheckOptionPrompt};
    const values = [_]?*const anyopaque{core_foundation.kCFBooleanTrue};
    const dictionary = core_foundation.CFDictionaryCreate(
        null,
        &keys,
        &values,
        keys.len,
        &core_foundation.kCFTypeDictionaryKeyCallBacks,
        &core_foundation.kCFTypeDictionaryValueCallBacks,
    ) orelse return;
    _ = core_graphics.AXIsProcessTrustedWithOptions(dictionary);
    core_foundation.CFRelease(dictionary);
}

/// The tap, and whether it reverses the wheel. Kept between launches.
pub const Reverser = struct {
    tap: ?*anyopaque = null,
    source: ?*anyopaque = null,
    enabled: bool = true,

    pub fn running(reverser: *const Reverser) bool {
        assert(reverser.tap == null or reverser.source != null);
        return reverser.tap != null;
    }

    /// Starts reversing the wheel; false when macOS refused the tap, which is
    /// what a process without the Accessibility permission gets.
    pub fn start(reverser: *Reverser) bool {
        assert(reverser.tap == null);
        const tap = core_graphics.CGEventTapCreate(
            location_hid,
            placement_head,
            option_default,
            @as(u64, 1) << @intCast(event_scroll_wheel),
            callback,
            reverser,
        ) orelse return false;
        const source = core_foundation.CFMachPortCreateRunLoopSource(null, tap, 0);
        core_foundation.CFRunLoopAddSource(
            core_foundation.CFRunLoopGetMain(),
            source,
            core_foundation.kCFRunLoopCommonModes,
        );
        reverser.tap = tap;
        reverser.source = source;
        return true;
    }

    /// Stops the tap. Every event it saw has been passed on already, so there
    /// is nothing to put back.
    pub fn stop(reverser: *Reverser) void {
        assert(reverser.running());
        const tap = reverser.tap.?;
        const source = reverser.source.?;
        core_foundation.CFRunLoopRemoveSource(
            core_foundation.CFRunLoopGetMain(),
            source,
            core_foundation.kCFRunLoopCommonModes,
        );
        core_graphics.CGEventTapEnable(tap, 0);
        core_foundation.CFRelease(source);
        core_foundation.CFRelease(tap);
        reverser.tap = null;
        reverser.source = null;
    }
};

fn callback(
    proxy: *anyopaque,
    kind: u32,
    event: ?*anyopaque,
    context: ?*anyopaque,
) callconv(.c) ?*anyopaque {
    _ = proxy;
    const reverser: *Reverser = @ptrCast(@alignCast(context.?));
    const passed = event.?;
    switch (kind) {
        event_disabled_by_timeout, event_disabled_by_user_input => {
            // macOS turns a slow tap off; it is still ours, and it works again
            // once it is enabled.
            core_graphics.CGEventTapEnable(reverser.tap.?, 1);
        },
        event_scroll_wheel => {
            if (reverser.enabled and is_wheel(passed)) reverse(passed);
        },
        else => {},
    }
    return passed;
}

/// Whether the event came from a wheel rather than a trackpad or a mouse that
/// scrolls smoothly, which sends pixel-based events.
fn is_wheel(event: *anyopaque) bool {
    return core_graphics.CGEventGetIntegerValueField(event, field_is_continuous) == 0;
}

/// Turns the event's scroll, in every unit it carries. macOS recomputes the
/// pixel and fixed-point deltas from the line delta whenever it is set, with
/// accelerations of its own, so they are written after it, each reversed from
/// the value the event arrived with: reversing the line delta alone would
/// change how far a step scrolls, not just which way.
fn reverse(event: *anyopaque) void {
    const delta1 = core_graphics.CGEventGetIntegerValueField(event, field_delta_axis1);
    const delta2 = core_graphics.CGEventGetIntegerValueField(event, field_delta_axis2);
    const fixed1 = core_graphics.CGEventGetDoubleValueField(event, field_fixed_pt_delta_axis1);
    const fixed2 = core_graphics.CGEventGetDoubleValueField(event, field_fixed_pt_delta_axis2);
    const point1 = core_graphics.CGEventGetIntegerValueField(event, field_point_delta_axis1);
    const point2 = core_graphics.CGEventGetIntegerValueField(event, field_point_delta_axis2);
    core_graphics.CGEventSetIntegerValueField(event, field_delta_axis1, -delta1);
    core_graphics.CGEventSetDoubleValueField(event, field_fixed_pt_delta_axis1, -fixed1);
    core_graphics.CGEventSetIntegerValueField(event, field_point_delta_axis1, -point1);
    core_graphics.CGEventSetIntegerValueField(event, field_delta_axis2, -delta2);
    core_graphics.CGEventSetDoubleValueField(event, field_fixed_pt_delta_axis2, -fixed2);
    core_graphics.CGEventSetIntegerValueField(event, field_point_delta_axis2, -point2);
    const hid = core_graphics.CGEventCopyIOHIDEvent(event) orelse return;
    defer core_foundation.CFRelease(hid);
    const hid_x = iokit.IOHIDEventGetFloatValue(hid, hid_field_scroll_x);
    const hid_y = iokit.IOHIDEventGetFloatValue(hid, hid_field_scroll_y);
    iokit.IOHIDEventSetFloatValue(hid, hid_field_scroll_x, -hid_x);
    iokit.IOHIDEventSetFloatValue(hid, hid_field_scroll_y, -hid_y);
}

const testing = std.testing;

/// A scroll event as the system makes one, for the tests: the units are
/// CGScrollEventUnit's line, 1, or pixel, 0.
fn make_event(units: u32, wheel1: i32, wheel2: i32) ?*anyopaque {
    return core_graphics.CGEventCreateScrollWheelEvent2(null, units, 2, wheel1, wheel2, 0);
}

test "the fields are the numbers CGEventTypes.h gives them" {
    try testing.expectEqual(@as(u32, 88), field_is_continuous);
    try testing.expectEqual(@as(u32, 0x60000), hid_field_scroll_x);
    try testing.expectEqual(@as(u32, 0x60001), hid_field_scroll_y);
}

test "the tap asks for wheel events and nothing else" {
    const mask = @as(u64, 1) << @intCast(event_scroll_wheel);
    try testing.expectEqual(@as(u32, 22), event_scroll_wheel);
    try testing.expectEqual(@as(u64, 0x40_0000), mask);
}

test "a wheel's event is discrete, a trackpad's is continuous" {
    const wheel = make_event(1, 3, 0) orelse return error.NoEvent;
    defer core_foundation.CFRelease(wheel);
    try testing.expect(is_wheel(wheel));
    const smooth = make_event(0, 3, 0) orelse return error.NoEvent;
    defer core_foundation.CFRelease(smooth);
    try testing.expect(!is_wheel(smooth));
}

test "reversing a wheel turns every delta it carries, on both axes" {
    const event = make_event(1, 3, -5) orelse return error.NoEvent;
    defer core_foundation.CFRelease(event);
    reverse(event);
    try testing.expectEqual(@as(i64, -3), field_int(event, field_delta_axis1));
    try testing.expectEqual(@as(i64, 5), field_int(event, field_delta_axis2));
    try testing.expectEqual(@as(f64, -3.0), field_double(event, field_fixed_pt_delta_axis1));
    try testing.expectEqual(@as(f64, 5.0), field_double(event, field_fixed_pt_delta_axis2));
    // Ten pixels to the line, and they still are.
    try testing.expectEqual(@as(i64, -30), field_int(event, field_point_delta_axis1));
    try testing.expectEqual(@as(i64, 50), field_int(event, field_point_delta_axis2));
}

fn field_int(event: *anyopaque, field: u32) i64 {
    return core_graphics.CGEventGetIntegerValueField(event, field);
}

fn field_double(event: *anyopaque, field: u32) f64 {
    return core_graphics.CGEventGetDoubleValueField(event, field);
}
