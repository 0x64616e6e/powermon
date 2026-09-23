const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const exe = b.addExecutable(.{
        .name = "powermon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // localtime_r for local timestamps
            .strip = optimize != .Debug,
        }),
    });
    exe.pie = true; // position-independent, for ASLR (Debian hardening)
    b.installArtifact(exe);
}
