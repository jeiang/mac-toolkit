//! The caffeinate process: started, stopped, and noticed once it has ended
//! on its own (its `-t` ran out, or it was killed). Main thread only: it
//! starts, signals and reaps its child itself, so a process id it holds is
//! never one the system has given to another process.
const std = @import("std");
const assert = std.debug.assert;
const caffeinate = @import("caffeinate.zig");

/// waitpid calls retried when a signal interrupts them.
const interrupted_max = 16;

pub const Keeper = struct {
    io: std.Io,
    pid: ?std.c.pid_t = null,

    pub fn running(keeper: *const Keeper) bool {
        return keeper.pid != null;
    }

    pub fn start(keeper: *Keeper, settings: caffeinate.Settings) std.process.SpawnError!void {
        assert(keeper.pid == null);
        const own_pid = std.c.getpid();
        assert(own_pid > 0);
        var command: caffeinate.Command = undefined;
        command.init(settings, @intCast(own_pid));
        const child = try std.process.spawn(keeper.io, .{
            .argv = command.argv(),
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        keeper.pid = child.id.?;
        assert(keeper.pid.? > 0);
    }

    /// Ends caffeinate, which then releases its assertions, and reaps it.
    pub fn stop(keeper: *Keeper) void {
        const pid = keeper.pid orelse return;
        // Fails only when the process is gone already: waitpid still reaps it.
        _ = std.c.kill(pid, .TERM);
        _ = wait(pid, 0);
        keeper.pid = null;
    }

    /// True when caffeinate was running and has ended since.
    pub fn reap(keeper: *Keeper) bool {
        const pid = keeper.pid orelse return false;
        if (wait(pid, std.c.W.NOHANG) == 0) return false;
        // Its pid, or -1 when it is not this process's child: gone either way.
        keeper.pid = null;
        return true;
    }
};

fn wait(pid: std.c.pid_t, options: c_int) std.c.pid_t {
    assert(pid > 0);
    var status: c_int = 0;
    for (0..interrupted_max) |_| {
        const result = std.c.waitpid(pid, &status, options);
        if (result != -1 or std.posix.errno(result) != .INTR) return result;
    }
    return -1;
}
