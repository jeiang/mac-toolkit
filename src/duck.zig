//! macOS's Call Guard ducks the default output device while a call runs, and
//! `'nodk'`, an undocumented property that every output device carries, opts
//! that device out of it. This sets the exemption and, once per device, ramps
//! the level back up in case the call ducked before the exemption was on.
//!
//! `AudioDeviceDuck(device, 1.0, nil, 0.5)` is Chromium's `UndoDucking`: the
//! level is the linear gain to restore, ramped over half a second, and calling
//! it over and over ticks audibly, so it is called once.
//!
//! The exemption is device state, not this process's: it outlives a crash, so
//! the switch going off and the app quitting both put the device back to
//! ducking, and the first pass of a launch does too if the setting is off.
const std = @import("std");
const assert = std.debug.assert;

/// A Core Audio object: a device, or the system object that owns the default
/// output device.
pub const Device = u32;

pub const Object = struct {
    pub const system: Device = 1;
    pub const unknown: Device = 0;
};

/// Four ASCII bytes as Core Audio reads them: big-endian, so "nodk" is
/// 0x6e6f646b.
pub fn fourcc(text: *const [4]u8) u32 {
    return @as(u32, text[0]) << 24 |
        @as(u32, text[1]) << 16 |
        @as(u32, text[2]) << 8 |
        @as(u32, text[3]);
}

const scope_global = fourcc("glob");
const scope_output = fourcc("outp");
const selector_default_output = fourcc("dOut");
/// The Call Guard exemption, as SoundU names it.
pub const selector_no_duck = fourcc("nodk");

/// A device's first, or only, channel group.
pub const element_main: u32 = 0;

/// A Core Audio property address.
pub const Address = extern struct {
    selector: u32,
    scope: u32,
    element: u32,

    /// `'nodk'` is an output-scope property; the global scope has none.
    pub fn no_duck() Address {
        return .{ .selector = selector_no_duck, .scope = scope_output, .element = element_main };
    }

    /// The address of the system object's name for the default output device.
    pub fn default_output() Address {
        return .{ .selector = selector_default_output, .scope = scope_global, .element = element_main };
    }
};

/// The exemption's payload: one UInt32, 1 to leave the device unducked for the
/// length of a call, 0 to let macOS duck it again.
pub const exempt: u32 = 1;
pub const ducking: u32 = 0;
const payload_bytes = @sizeOf(u32);

/// The level a device is restored to, and how long the ramp takes. Unity is
/// no attenuation; Chromium unducks with the same two values.
const unity: f32 = 1.0;
const ramp_seconds: f32 = 0.5;

pub const Outcome = union(enum) {
    /// The device is exempt from ducking.
    held,
    /// macOS has no default output device: nothing is playing.
    no_device,
    /// The device has no exemption property.
    no_property,
    /// The property exists but macOS will not let it be set.
    read_only,
    /// Core Audio refused a call; `status` is its OSStatus.
    failed: i32,
};

/// `noErr`.
const success: i32 = 0;

/// Core Audio's C entry points, as CoreAudio.framework and its SPI declare
/// them.
const core_audio = struct {
    const boolean = u8;

    extern "c" fn AudioObjectHasProperty(object: Device, address: *const Address) boolean;
    extern "c" fn AudioObjectIsPropertySettable(
        object: Device,
        address: *const Address,
        settable: *boolean,
    ) i32;
    extern "c" fn AudioObjectGetPropertyData(
        object: Device,
        address: *const Address,
        qualifier_size: u32,
        qualifier: ?*const anyopaque,
        size: *u32,
        data: *anyopaque,
    ) i32;
    extern "c" fn AudioObjectSetPropertyData(
        object: Device,
        address: *const Address,
        qualifier_size: u32,
        qualifier: ?*const anyopaque,
        size: u32,
        data: *const anyopaque,
    ) i32;
    extern "c" fn AudioDeviceDuck(
        device: Device,
        level: f32,
        start_time: ?*const anyopaque,
        ramp_duration: f32,
    ) i32;
};

/// The default output device, or null when macOS names none.
fn default_device() ?Device {
    var address: Address = .default_output();
    var device: Device = Object.unknown;
    var size: u32 = @sizeOf(Device);
    const status = core_audio.AudioObjectGetPropertyData(
        Object.system,
        &address,
        0,
        null,
        &size,
        &device,
    );
    if (status != success) return null;
    if (device == Object.unknown) return null;
    return device;
}

const Read = union(enum) {
    value: u32,
    absent,
    read_only,
    failed: i32,
};

fn read(device: Device, address: Address) Read {
    var mutable_address = address;
    if (core_audio.AudioObjectHasProperty(device, &mutable_address) == 0) return .absent;
    var settable: core_audio.boolean = 0;
    const settable_status = core_audio.AudioObjectIsPropertySettable(
        device,
        &mutable_address,
        &settable,
    );
    if (settable_status != success) return .{ .failed = settable_status };
    if (settable == 0) return .read_only;
    var value: u32 = 0;
    var size: u32 = payload_bytes;
    const status = core_audio.AudioObjectGetPropertyData(
        device,
        &mutable_address,
        0,
        null,
        &size,
        &value,
    );
    if (status != success) return .{ .failed = status };
    assert(size == payload_bytes);
    return .{ .value = value };
}

fn write(device: Device, address: Address, value: u32) i32 {
    var mutable_address = address;
    var payload = value;
    return core_audio.AudioObjectSetPropertyData(
        device,
        &mutable_address,
        0,
        null,
        payload_bytes,
        &payload,
    );
}

/// The device whose exemption is on, and whether its level has been ramped
/// back up since this pass started caring about it.
pub const Guard = struct {
    device: Device = Object.unknown,
    ramped: bool = false,

    /// Exempts the default output device from ducking. Nothing is written when
    /// it is already exempt, and the ramp happens once per device.
    pub fn hold(guard: *Guard) Outcome {
        const device = default_device() orelse return .no_device;
        if (device != guard.device) {
            // Another device is playing now: this one is not ours to touch.
            if (guard.device != Object.unknown) _ = write(guard.device, .no_duck(), ducking);
            guard.device = device;
            guard.ramped = false;
        }
        switch (read(device, .no_duck())) {
            .absent => return .no_property,
            .read_only => return .read_only,
            .failed => |status| return .{ .failed = status },
            .value => |value| if (value != exempt) {
                const status = write(device, .no_duck(), exempt);
                if (status != success) return .{ .failed = status };
            },
        }
        if (!guard.ramped) {
            // A call may have ducked the device before the exemption was on;
            // one ramp up undoes it. Nothing depends on its status: the
            // exemption is what keeps the level, and this may be missing on a
            // macOS that never had Call Guard.
            _ = core_audio.AudioDeviceDuck(device, unity, null, ramp_seconds);
            guard.ramped = true;
        }
        return .held;
    }

    /// Lets the device duck again. Called when the switch goes off and when the
    /// app quits, because the exemption outlives both.
    pub fn release(guard: *Guard) void {
        if (guard.device == Object.unknown) return;
        _ = write(guard.device, .no_duck(), ducking);
        guard.device = Object.unknown;
        guard.ramped = false;
    }
};

const testing = std.testing;

test "the exemption selector is the four bytes Core Audio reads" {
    try testing.expectEqual(@as(u32, 0x6e6f_646b), selector_no_duck);
    try testing.expectEqual(@as(u32, 0x6e6f_646b), fourcc("nodk"));
    try testing.expectEqual(@as(u32, 0x644f_7574), fourcc("dOut"));
    try testing.expectEqual(@as(u32, 0x6f75_7470), scope_output);
}

test "the exemption is one UInt32 on the output scope of the main element" {
    const address: Address = .no_duck();
    try testing.expectEqual(selector_no_duck, address.selector);
    try testing.expectEqual(scope_output, address.scope);
    try testing.expectEqual(element_main, address.element);
    try testing.expectEqual(@as(usize, 12), @sizeOf(Address));
    try testing.expectEqual(@as(u32, 4), payload_bytes);
    try testing.expectEqual(@as(u32, 1), exempt);
    try testing.expectEqual(@as(u32, 0), ducking);
}

test "the level a ramp restores is unity, over half a second" {
    try testing.expectEqual(@as(f32, 1.0), unity);
    try testing.expectEqual(@as(f32, 0.5), ramp_seconds);
    assert(@as(f32, 0.0) != unity);
}
