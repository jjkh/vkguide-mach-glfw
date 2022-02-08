const std = @import("std");

const glfw = @import("deps/mach-glfw/build.zig");

const vkgen = @import("deps/vulkan-zig/generator/index.zig");
const zigvulkan = @import("deps/vulkan-zig/build.zig");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("vkguide-mach-glfw", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    // zlm (zig linear maths library)
    exe.addPackagePath("zlm", "deps/zlm/zlm.zig");

    // vulkan-zig: Create a step that generates vk.zig (stored in zig-cache) from the provided vulkan registry.
    const gen = vkgen.VkGenerateStep.init(b, "deps/vulkan-zig/examples/vk.xml", "vk.zig");
    exe.addPackage(gen.package);

    // zva (zig vulkan allocator)
    const zva = @import("deps/zva/pkg.zig").Pkg("deps/zva", "zig-cache/vk.zig");
    exe.addPackage(zva.pkg);

    // mach-glfw
    exe.addPackagePath("glfw", "deps/mach-glfw/src/main.zig");
    glfw.link(b, exe, .{});

    // shader resources, to be compiled using glslc
    const res = zigvulkan.ResourceGenStep.init(b, "resources.zig");
    res.addShader("red_triangle_vert", "shaders/red_triangle.vert");
    res.addShader("red_triangle_frag", "shaders/red_triangle.frag");
    res.addShader("colored_triangle_vert", "shaders/colored_triangle.vert");
    res.addShader("colored_triangle_frag", "shaders/colored_triangle.frag");
    exe.addPackage(res.package);

    // freetype
    exe.linkLibC();
    exe.addIncludeDir("deps/freetype/include");
    exe.addObjectFile("deps/freetype/lib/win-x64-gnu/freetype.a");

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
