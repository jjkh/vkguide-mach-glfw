const std = @import("std");

const vk = @import("vulkan");
const glfw = @import("glfw");

const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Swapchain = @import("swapchain.zig").Swapchain;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try glfw.init(.{});
    errdefer glfw.terminate();

    var extent = vk.Extent2D{ .width = 800, .height = 600 };

    // create the window
    const window = try glfw.Window.create(
        extent.width,
        extent.height,
        "vkguide.dev",
        null,
        null,
        .{ .client_api = .no_api },
    );
    defer window.destroy();

    const gc = try GraphicsContext.init(allocator, "vkguide example", window);
    defer gc.deinit();

    std.debug.print("Using device: {s}\n", .{gc.deviceName()});

    var swapchain = try Swapchain.init(&gc, allocator, extent);
    defer swapchain.deinit();

    // Wait for the user to close the window.
    while (!window.shouldClose()) {
        try glfw.pollEvents();
    }
}
