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

    const examples_step = b.step("examples", "Build and run all examples");

    const examples = [_][]const u8{
        "paper_trading",
        "historical_data",
    };

    for (examples) |name| {
        const exe_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "alpaca-trade-api", .module = mod },
            },
        });

        const exe = b.addExecutable(.{
            .name = b.dupe(name),
            .root_module = exe_mod,
        });

        examples_step.dependOn(&b.addRunArtifact(exe).step);
    }
}
