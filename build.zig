//! mac-toolkit: small utilities behind one menu bar icon, drawn by nanoui.
//!
//!   zig build run    build and open it
//!   zig build app    zig-out/mac-toolkit.app, for /Applications
//!   zig build test   the caffeinate command line, the kept settings, the duck payload
//!   zig build icon   redraws macos/icon.png and macos/AppIcon.icns (macOS host)
const std = @import("std");

/// The notices of the code that ships in the program: mac-toolkit's own, then
/// nanoui's and those of the code nanoui takes from others (nanoui's
/// THIRD_PARTY_NOTICES.md says which).
const nanoui_notices = [_][]const u8{
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    "third_party/licenses/mygo-MIT.txt",
    "third_party/licenses/GPUI-Apache-2.0.txt",
    "third_party/licenses/GPUI-Kit-Apache-2.0.txt",
    "third_party/licenses/gpui-motion-MIT.txt",
    "third_party/licenses/brotli-MIT.txt",
    "third_party/licenses/Unicode-3.0.txt",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nanoui_dep = b.dependency("nanoui", .{ .target = target, .optimize = optimize });
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "nanoui", .module = nanoui_dep.module("nanoui") }},
    });
    add_frameworks(b, module, target);

    const exe = b.addExecutable(.{ .name = "mac-toolkit", .root_module = module });
    b.installArtifact(exe);
    install_notices(b, nanoui_dep, b.getInstallStep(), "share/licenses/mac-toolkit");

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run mac-toolkit").dependOn(&run.step);

    add_app_step(b, exe, nanoui_dep);
    add_icon_step(b);

    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}

/// Core Audio's duck property and the event tap's Core Graphics calls. With
/// `NIX_CFLAGS_COMPILE` set (the flake devshell does), Zig searches only the
/// Nix paths and finds none of the SDK's frameworks.
fn add_frameworks(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .macos) return;
    module.linkFramework("CoreAudio", .{});
    module.linkFramework("ApplicationServices", .{});
    // IOHIDEventSetFloatValue: the scroll under the CGEvent, for Chromium.
    module.linkFramework("IOKit", .{});
    const sdk = std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result) orelse return;
    const frameworks = b.pathJoin(&.{ sdk, "System/Library/Frameworks" });
    module.addSystemFrameworkPath(b.graph.cwdRelativePath(frameworks));
    module.addLibraryPath(b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "usr/lib" })));
}

fn install_notices(
    b: *std.Build,
    nanoui_dep: *std.Build.Dependency,
    step: *std.Build.Step,
    dest: []const u8,
) void {
    const own = b.addInstallFile(b.path("LICENSE"), b.pathJoin(&.{ dest, "LICENSE" }));
    step.dependOn(&own.step);
    for (nanoui_notices) |name| {
        // The same paths as in nanoui, which its notices' links use.
        const to = b.pathJoin(&.{ dest, "nanoui", name });
        step.dependOn(&b.addInstallFile(nanoui_dep.path(name), to).step);
    }
}

/// zig-out/mac-toolkit.app: the program, its icon, the notices, and an
/// Info.plist that keeps it out of the Dock (a menu bar app).
fn add_app_step(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    nanoui_dep: *std.Build.Dependency,
) void {
    const bundle_exe = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{
        .custom = "mac-toolkit.app/Contents/MacOS",
    } } });
    const plist = b.addInstallFile(b.path("macos/Info.plist"), "mac-toolkit.app/Contents/Info.plist");
    const icns = b.addInstallFile(b.path("macos/AppIcon.icns"), "mac-toolkit.app/Contents/Resources/AppIcon.icns");
    const app = b.step("app", "Build zig-out/mac-toolkit.app");
    app.dependOn(&bundle_exe.step);
    app.dependOn(&plist.step);
    app.dependOn(&icns.step);
    install_notices(b, nanoui_dep, app, "mac-toolkit.app/Contents/Resources/licenses");
}

fn add_icon_step(b: *std.Build) void {
    const icon = b.step("icon", "Redraw macos/icon.png and macos/AppIcon.icns (macOS host)");
    if (b.graph.host.result.os.tag != .macos) {
        icon.dependOn(&b.addFail("zig build icon runs on a Mac: it needs sips and iconutil").step);
        return;
    }
    const icon_exe = b.addExecutable(.{
        .name = "icon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/icon.zig"),
            .target = b.graph.host,
            .optimize = .safe,
            .link_libc = true, // erfc, for the shadow
        }),
    });
    const icon_run = b.addRunArtifact(icon_exe);
    // It writes the icon's files in the source tree, which the cache cannot see.
    icon_run.setCwd(b.path("."));
    icon_run.has_side_effects = true;
    icon.dependOn(&icon_run.step);
}
