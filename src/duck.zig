//! macOS's duck property. While a call runs, macOS writes into the default
//! output device's `duck` property, and every other app's media gets quieter.
//! Writing the value macOS leaves when nothing is ducking holds the media at
//! the volume it was set to, with no boost and no virtual device.
//!
//! The property is 16 bytes on the output scope, and it reads all zeros while
//! nothing is ducking. The first Float32 is the attenuation macOS adds, not a
//! gain it multiplies by: writing 1.0 into it silences every app, with or
//! without a call. So the value that un-ducks is the zeros macOS itself
//! leaves, and the write repeats because macOS re-ducks for as long as the
//! call lasts.
const std = @import("std");
const assert = std.debug.assert;

/// A Core Audio object: a device, or the system object that owns the default
/// output device.
pub const Device = u32;

pub const Object = struct {
    pub const system: Device = 1;
    pub const unknown: Device = 0;
};

/// Four ASCII bytes as Core Audio reads them: big-endian, so "duck" is
/// 0x6475636b.
pub fn fourcc(text: *const [4]u8) u32 {
    return @as(u32, text[0]) << 24 |
        @as(u32, text[1]) << 16 |
        @as(u32, text[2]) << 8 |
        @as(u32, text[3]);
}

const scope_global = fourcc("glob");
const scope_output = fourcc("outp");
const selector_default_output = fourcc("dOut");
pub const selector_duck = fourcc("duck");

/// A device's first, or only, channel group.
pub const element_main: u32 = 0;

/// A Core Audio property address.
pub const Address = extern struct {
    selector: u32,
    scope: u32,
    element: u32,

    pub fn duck(scope: u32) Address {
        return .{ .selector = selector_duck, .scope = scope, .element = element_main };
    }
};

/// What the property holds when nothing ducks: no attenuation on any of the
/// four Float32. The output scope carries it; the global scope has no duck
/// property on this Mac.
pub const unduck_payload = [4]f32{ 0.0, 0.0, 0.0, 0.0 };

pub const Outcome = union(enum) {
    /// The duck attenuation was cleared; media stays loud through the call.
    held,
    /// macOS has no default output device: nothing is playing.
    no_device,
    /// The device has no duck property: macOS does not duck it.
    no_property,
    /// The property exists but macOS will not let it be set.
    read_only,
    /// Core Audio refused a call; `status` is its OSStatus.
    failed: i32,
};

/// `noErr`.
const success: i32 = 0;

/// Core Audio's C entry points, as CoreAudio.framework declares them.
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
};

/// The default output device, or null when macOS names none.
fn default_device() ?Device {
    var address: Address = .{
        .selector = selector_default_output,
        .scope = scope_global,
        .element = element_main,
    };
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

const Write = union(enum) {
    held,
    absent,
    read_only,
    failed: i32,
};

fn write_duck(device: Device) Write {
    const address: Address = .duck(scope_output);
    if (core_audio.AudioObjectHasProperty(device, &address) == 0) return .absent;
    var settable: core_audio.boolean = 0;
    const settable_status = core_audio.AudioObjectIsPropertySettable(device, &address, &settable);
    if (settable_status != success) return .{ .failed = settable_status };
    if (settable == 0) return .read_only;
    const write_status = core_audio.AudioObjectSetPropertyData(
        device,
        &address,
        0,
        null,
        @sizeOf(@TypeOf(unduck_payload)),
        &unduck_payload,
    );
    if (write_status != success) return .{ .failed = write_status };
    return .held;
}

/// Clears the duck attenuation on the default output device. Main thread
/// only; each Core Audio call is quick.
pub fn hold() Outcome {
    const device = default_device() orelse return .no_device;
    return switch (write_duck(device)) {
        .held => .held,
        .absent => .no_property,
        .read_only => .read_only,
        .failed => |status| .{ .failed = status },
    };
}

const testing = std.testing;

test "the duck selector is the four bytes macOS reads" {
    try testing.expectEqual(@as(u32, 0x6475_636b), selector_duck);
    try testing.expectEqual(@as(u32, 0x6475_636b), fourcc("duck"));
    try testing.expectEqual(@as(u32, 0x644f_7574), fourcc("dOut"));
    try testing.expectEqual(@as(u32, 0x6f75_7470), fourcc("outp"));
}

test "a duck address names the duck property of the output scope" {
    const address: Address = .duck(scope_output);
    try testing.expectEqual(selector_duck, address.selector);
    try testing.expectEqual(fourcc("outp"), address.scope);
    try testing.expectEqual(element_main, address.element);
    try testing.expectEqual(@as(usize, 12), @sizeOf(Address));
}

test "unducking writes the sixteen zero bytes macOS leaves when nothing ducks" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(@TypeOf(unduck_payload)));
    for (unduck_payload) |value| try testing.expectEqual(@as(f32, 0.0), value);
    // 1.0 in the first float is an attenuation, and it silences every app.
    try testing.expect(@as([4]f32, .{ 1.0, 0.0, 0.0, 0.0 })[0] != unduck_payload[0]);
    assert(@as(usize, 4) * @sizeOf(f32) == @sizeOf(@TypeOf(unduck_payload)));
}
