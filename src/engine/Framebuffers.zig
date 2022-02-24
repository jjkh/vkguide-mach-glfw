buffers: []vk.Framebuffer,
depth_image: Image,

allocator: Allocator,

const Framebuffers = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const zva = @import("zva");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Swapchain = @import("swapchain.zig").Swapchain;
const Image = @import("Image.zig");

pub fn create(
    gc: *const GraphicsContext,
    vma: *zva.Allocator,
    allocator: Allocator,
    render_pass: vk.RenderPass,
    swapchain: Swapchain,
) !Framebuffers {
    const framebuffers = try allocator.alloc(vk.Framebuffer, swapchain.swap_images.len);
    errdefer allocator.free(framebuffers);

    // a depth image is required by the render pipeline to ensure the correct
    // vertices (pixels?) are drawn on the top
    // this is part of the depth buffer, and is used by the render pass as a
    // depth attachment
    var depth_image = try Image.create(
        gc,
        vma,
        .d32_sfloat,
        .{ .depth_stencil_attachment_bit = true },
        .{ .depth_bit = true },
        .{
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
            .depth = 1,
        },
    );
    errdefer depth_image.free(gc, vma);

    var i: usize = 0;
    errdefer for (framebuffers[0..i]) |fb| gc.vkd.destroyFramebuffer(gc.dev, fb, null);

    for (framebuffers) |*fb| {
        fb.* = try gc.vkd.createFramebuffer(gc.dev, &.{
            .flags = .{},
            .render_pass = render_pass,
            .attachment_count = 2,
            .p_attachments = &[_]vk.ImageView{ swapchain.swap_images[i].view, depth_image.view },
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
            .layers = 1,
        }, null);
        i += 1;
    }

    return Framebuffers{ .buffers = framebuffers, .depth_image = depth_image, .allocator = allocator };
}

pub fn free(self: *Framebuffers, gc: *const GraphicsContext, vma: *zva.Allocator) void {
    self.depth_image.free(gc, vma);

    for (self.buffers) |fb| gc.vkd.destroyFramebuffer(gc.dev, fb, null);
    self.allocator.free(self.buffers);
}
