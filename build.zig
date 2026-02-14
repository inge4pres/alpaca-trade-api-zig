const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const websocket = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("alpaca-trade-api", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "websocket", .module = websocket.module("websocket") },
        },
    });

    const lib_tests = b.addTest(.{
        .root_module = mod,
    });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/paper_trading.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "alpaca-trade-api", .module = mod },
        },
    });

    const example_exe = b.addExecutable(.{
        .name = "paper-trading",
        .root_module = example_mod,
    });

    const example_step = b.step("example", "Build and run the paper trading example");
    example_step.dependOn(&b.addRunArtifact(example_exe).step);
}
