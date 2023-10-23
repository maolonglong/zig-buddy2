const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const buddy2_mod = b.addModule("buddy2", .{
        .source_file = .{ .path = "src/buddy2.zig" },
    });

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/buddy2.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    const kcov = b.addSystemCommand(&.{ "kcov", "--clean", "--include-pattern=src/", "kcov-output" });
    kcov.addArtifactArg(main_tests);

    const kcov_step = b.step("kcov", "Generate code coverage report");
    kcov_step.dependOn(&kcov.step);

    inline for ([_]struct {
        name: []const u8,
        src: []const u8,
    }{
        .{ .name = "non_threadsafe", .src = "examples/non_threadsafe.zig" },
        .{ .name = "threadsafe", .src = "examples/threadsafe.zig" },
    }) |config| {
        const step_name = std.fmt.allocPrint(b.allocator, "run-{s}", .{config.name}) catch unreachable;
        const step_desc = std.fmt.allocPrint(b.allocator, "Run the {s} example", .{config.name}) catch unreachable;

        const example = b.addExecutable(.{
            .name = config.name,
            .root_source_file = .{ .path = config.src },
            .target = target,
            .optimize = optimize,
        });

        example.addModule("buddy2", buddy2_mod);

        const run_cmd = b.addRunArtifact(example);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step(step_name, step_desc);
        run_step.dependOn(&run_cmd.step);

        b.allocator.free(step_name);
        b.allocator.free(step_desc);
    }
}
