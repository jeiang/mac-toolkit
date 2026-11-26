//! A repeating timer on the main run loop, in every mode, so it also fires
//! while the tray's menu is open (`App.after`'s GCD main queue waits until
//! the menu closes).
const std = @import("std");
const assert = std.debug.assert;

const cf = struct {
    const Context = extern struct {
        version: isize = 0,
        info: ?*anyopaque,
        retain: ?*const anyopaque = null,
        release: ?*const anyopaque = null,
        copy_description: ?*const anyopaque = null,
    };
    extern "c" fn CFRunLoopTimerCreate(
        allocator: ?*anyopaque,
        fire_date: f64,
        interval: f64,
        flags: usize,
        order: isize,
        callout: Callout,
        context: *Context,
    ) ?*anyopaque;
    extern "c" fn CFRunLoopAddTimer(loop: *anyopaque, timer: *anyopaque, mode: *anyopaque) void;
    extern "c" fn CFRunLoopTimerInvalidate(timer: *anyopaque) void;
    extern "c" fn CFRelease(object: *anyopaque) void;
    extern "c" fn CFRunLoopGetMain() *anyopaque;
    extern "c" fn CFAbsoluteTimeGetCurrent() f64;
    extern "c" const kCFRunLoopCommonModes: *anyopaque;
};

pub const Callout = *const fn (timer: *anyopaque, info: ?*anyopaque) callconv(.c) void;

pub const Timer = struct {
    handle: ?*anyopaque = null,

    pub fn running(timer: *const Timer) bool {
        return timer.handle != null;
    }

    /// Calls `callout(timer, context)` every `interval_ms` from now on; false
    /// when CoreFoundation could not make the timer.
    pub fn start(timer: *Timer, interval_ms: u32, context: *anyopaque, callout: Callout) bool {
        assert(timer.handle == null);
        assert(interval_ms > 0);
        const interval = @as(f64, @floatFromInt(interval_ms)) / std.time.ms_per_s;
        // CFRunLoopTimerCreate copies the context.
        var timer_context: cf.Context = .{ .info = context };
        const fire_date = cf.CFAbsoluteTimeGetCurrent() + interval;
        const handle = cf.CFRunLoopTimerCreate(
            null,
            fire_date,
            interval,
            0,
            0,
            callout,
            &timer_context,
        ) orelse return false;
        cf.CFRunLoopAddTimer(cf.CFRunLoopGetMain(), handle, cf.kCFRunLoopCommonModes);
        timer.handle = handle;
        return true;
    }

    pub fn stop(timer: *Timer) void {
        const handle = timer.handle orelse return;
        cf.CFRunLoopTimerInvalidate(handle);
        cf.CFRelease(handle);
        timer.handle = null;
    }
};
