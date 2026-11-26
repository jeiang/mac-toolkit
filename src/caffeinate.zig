//! What caffeinate is asked to keep awake, for how long, and the command
//! line that asks it (`man caffeinate`).
const std = @import("std");
const assert = std.debug.assert;

pub const program = "/usr/bin/caffeinate";

/// caffeinate's assertion flags, in its man page's order. With none,
/// caffeinate prevents idle sleep, as `-i` does.
pub const Flag = enum {
    display,
    idle,
    disk,
    system,
    user,

    pub fn argument(flag: Flag) []const u8 {
        return switch (flag) {
            .display => "-d",
            .idle => "-i",
            .disk => "-m",
            .system => "-s",
            .user => "-u",
        };
    }

    pub fn letter(flag: Flag) u8 {
        return flag.argument()[1];
    }

    pub fn label(flag: Flag) []const u8 {
        return switch (flag) {
            .display => "Prevent Display Sleep (-d)",
            .idle => "Prevent Idle Sleep (-i)",
            .disk => "Prevent Disk Idle Sleep (-m)",
            .system => "Prevent System Sleep on AC Power (-s)",
            .user => "Declare the User Active (-u)",
        };
    }
};

/// `-t`: how long caffeinate holds its assertions before it exits.
pub const Duration = enum(u32) {
    forever = 0,
    minutes_15 = 15 * std.time.s_per_min,
    hour_1 = std.time.s_per_hour,
    hours_2 = 2 * std.time.s_per_hour,
    hours_4 = 4 * std.time.s_per_hour,
    hours_8 = 8 * std.time.s_per_hour,

    pub fn seconds(duration: Duration) u32 {
        return @backingInt(duration);
    }

    pub fn label(duration: Duration) []const u8 {
        return switch (duration) {
            .forever => "Indefinitely",
            .minutes_15 => "15 Minutes",
            .hour_1 => "1 Hour",
            .hours_2 => "2 Hours",
            .hours_4 => "4 Hours",
            .hours_8 => "8 Hours",
        };
    }
};

pub const flag_count = @typeInfo(Flag).@"enum".field_names.len;
/// The program, every flag, `-t` and its seconds, `-w` and its process id.
pub const arguments_max = 1 + flag_count + 2 + 2;
/// The decimal digits of the largest `u32`.
const number_bytes_max = 10;
const duration_name_bytes_max = name_bytes_max: {
    var length_max = 0;
    for (@typeInfo(Duration).@"enum".field_names) |name| length_max = @max(length_max, name.len);
    break :name_bytes_max length_max;
};

pub const Settings = struct {
    flags: std.EnumSet(Flag) = .initMany(&.{ .display, .idle }),
    duration: Duration = .forever,

    /// The flags' letters, a slash, and the duration's name: "di/forever".
    pub const text_bytes_max = flag_count + 1 + duration_name_bytes_max;

    /// The text kept between launches.
    pub fn encode(settings: Settings, buffer: *[text_bytes_max]u8) []const u8 {
        var length: usize = 0;
        for (std.enums.values(Flag)) |flag| {
            if (!settings.flags.contains(flag)) continue;
            buffer[length] = flag.letter();
            length += 1;
        }
        buffer[length] = '/';
        length += 1;
        const name = @tagName(settings.duration);
        @memcpy(buffer[length..][0..name.len], name);
        length += name.len;
        assert(length <= text_bytes_max);
        return buffer[0..length];
    }

    /// The settings in `text`, or null when `encode` could not have written it.
    pub fn decode(text: []const u8) ?Settings {
        if (text.len > text_bytes_max) return null;
        const slash = std.mem.findScalar(u8, text, '/') orelse return null;
        var settings: Settings = .{ .flags = .empty };
        for (text[0..slash]) |letter| {
            const flag = for (std.enums.values(Flag)) |flag| {
                if (flag.letter() == letter) break flag;
            } else return null;
            settings.flags.insert(flag);
        }
        settings.duration = std.meta.stringToEnum(Duration, text[slash + 1 ..]) orelse return null;
        return settings;
    }
};

/// caffeinate's argument vector. Its arguments point into its own buffers,
/// so it is filled in place (`init`) and never copied.
pub const Command = struct {
    arguments: [arguments_max][]const u8,
    arguments_count: u8,
    seconds_text: [number_bytes_max]u8,
    pid_text: [number_bytes_max]u8,

    /// `-w watched_pid`: caffeinate exits with that process, so it never
    /// outlives the app that started it.
    pub fn init(command: *Command, settings: Settings, watched_pid: u32) void {
        assert(watched_pid > 0);
        command.arguments_count = 0;
        command.push(program);
        for (std.enums.values(Flag)) |flag| {
            if (settings.flags.contains(flag)) command.push(flag.argument());
        }
        if (settings.duration != .forever) {
            command.push("-t");
            command.push(print_number(&command.seconds_text, settings.duration.seconds()));
        }
        command.push("-w");
        command.push(print_number(&command.pid_text, watched_pid));
        assert(command.arguments_count >= 3);
    }

    pub fn argv(command: *const Command) []const []const u8 {
        assert(command.arguments_count <= arguments_max);
        return command.arguments[0..command.arguments_count];
    }

    fn push(command: *Command, argument: []const u8) void {
        assert(command.arguments_count < arguments_max);
        assert(argument.len > 0);
        command.arguments[command.arguments_count] = argument;
        command.arguments_count += 1;
    }
};

fn print_number(buffer: *[number_bytes_max]u8, number: u32) []const u8 {
    // A u32 always fits in its ten digits.
    return std.mem.print(buffer, "{d}", .{number}) catch unreachable;
}

const testing = std.testing;

fn expect_argv(expected: []const []const u8, settings: Settings) !void {
    var command: Command = undefined;
    command.init(settings, 4242);
    const actual = command.argv();
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try testing.expectEqualStrings(want, got);
}

test "the command names every chosen flag, the duration only when set, and the app's pid" {
    try expect_argv(&.{ program, "-d", "-i", "-w", "4242" }, .{});
    try expect_argv(&.{ program, "-w", "4242" }, .{ .flags = .empty });
    try expect_argv(
        &.{ program, "-d", "-i", "-m", "-s", "-u", "-t", "28800", "-w", "4242" },
        .{ .flags = .full, .duration = .hours_8 },
    );
}

test "kept settings read back as written, and anything else reads as nothing" {
    var buffer: [Settings.text_bytes_max]u8 = undefined;
    try testing.expectEqualStrings("di/forever", Settings.encode(.{}, &buffer));
    const all: Settings = .{ .flags = .full, .duration = .minutes_15 };
    const text = all.encode(&buffer);
    try testing.expectEqualStrings("dimsu/minutes_15", text);
    const back = Settings.decode(text).?;
    try testing.expect(back.flags.eql(all.flags));
    try testing.expectEqual(all.duration, back.duration);
    try testing.expect(Settings.decode("/hour_1").?.flags.eql(.empty));
    for ([_][]const u8{ "", "di", "dx/forever", "di/forever!", "di/hours_99" }) |bad| {
        try testing.expectEqual(null, Settings.decode(bad));
    }
}
