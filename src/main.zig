const std = @import("std");

const vk = @import("vulkan");
const glfw = @import("glfw");

const Engine = @import("Engine.zig");

pub fn main() !void {
    const engine = Engine.init(.{ .name = "vkguide example" }, .{ .title = "vkguide.dev" });
    defer engine.deinit();

    // Wait for the user to close the window.
    while (!engine.window.shouldClose()) {
        try glfw.pollEvents();
    }
}
