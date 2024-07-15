const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .aarch64,
            .cpu_model = .{
                .explicit = &std.Target.aarch64.cpu.cortex_a53,
            },
            .os_tag = .linux,
            .abi = .gnu,
        },
        // .default_target = .{
        //     .cpu_arch = .x86_64,
        //     .cpu_model = .{
        //         .explicit = &std.Target.x86.cpu.x86_64_v3,
        //     },
        // },
    });

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "deepstars-zig",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });

    exe.root_module.addImport("mach-glfw", b.dependency("mach-glfw", .{
        .target = target,
        .optimize = optimize,
    }).module("mach-glfw"));

    exe.root_module.addImport("zmath", b.dependency("zmath", .{
        .target = target,
        .optimize = optimize,
    }).module("root"));

    const gl_bindings = @import("zigglgen").generateBindingsModule(b, .{
        .api = .gles,
        .version = .@"2.0",
        .extensions = &.{
            .KHR_debug,
            .OES_vertex_array_object,
            .EXT_blend_minmax,
        },
    });

    // Import the generated module.
    exe.root_module.addImport("gl", gl_bindings);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const gen_stars_exe = b.addExecutable(.{
        .name = "deepstars-gen-stars",
        .root_source_file = b.path("src/gen_stars.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });

    // b.installArtifact(gen_stars_exe);

    const gen_stars_cmd = b.addRunArtifact(gen_stars_exe);

    // gen_stars_cmd.step.dependOn(b.getInstallStep());

    const gen_stars_step = b.step("genStars", "Generate stars and save them to disk");
    gen_stars_step.dependOn(&gen_stars_cmd.step);
}
