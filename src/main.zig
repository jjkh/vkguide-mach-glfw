const std = @import("std");

const vk = @import("vulkan");
const glfw = @import("glfw");

const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Swapchain = @import("swapchain.zig").Swapchain;
const Allocator = std.mem.Allocator;

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

    // create a command pool for commands submitted to the graphics queue
    const pool = try gc.vkd.createCommandPool(gc.dev, &.{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = gc.graphics_queue.family,
    }, null);
    defer gc.vkd.destroyCommandPool(gc.dev, pool, null);

    // command buffer
    const cmdbufs = try allocator.alloc(vk.CommandBuffer, 1);
    defer allocator.free(cmdbufs);

    // allocate the default command buffer that we will use for rendering
    try gc.vkd.allocateCommandBuffers(gc.dev, &.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = @intCast(u32, cmdbufs.len),
    }, cmdbufs.ptr);
    defer gc.vkd.freeCommandBuffers(gc.dev, pool, @truncate(u32, cmdbufs.len), cmdbufs.ptr);

    const render_pass = try createRenderPass(&gc, swapchain);
    defer gc.vkd.destroyRenderPass(gc.dev, render_pass, null);

    var framebuffers = try createFramebuffers(&gc, allocator, render_pass, swapchain);
    defer {
        for (framebuffers) |fb| gc.vkd.destroyFramebuffer(gc.dev, fb, null);
        allocator.free(framebuffers);
    }

    var fence = try gc.vkd.createFence(gc.dev, &.{ .flags = .{ .signaled_bit = true } }, null);
    defer gc.vkd.destroyFence(gc.dev, fence, null);

    var present_semaphore = try gc.vkd.createSemaphore(gc.dev, &.{ .flags = .{} }, null);
    defer gc.vkd.destroySemaphore(gc.dev, present_semaphore, null);
    var render_semaphore = try gc.vkd.createSemaphore(gc.dev, &.{ .flags = .{} }, null);
    defer gc.vkd.destroySemaphore(gc.dev, render_semaphore, null);

    var frame_number: u32 = 0;
    // Wait for the user to close the window.
    while (!window.shouldClose()) : (frame_number += 1) {
        // wait until the GPU has finished rendering the last frame. Timeout of 1 second
        _ = try gc.vkd.waitForFences(gc.dev, 1, @ptrCast([*]vk.Fence, &fence), @boolToInt(true), 1_000_000_000);
        try gc.vkd.resetFences(gc.dev, 1, @ptrCast([*]vk.Fence, &fence));

        // request image from the swapchain, one second timeout
        const result = try gc.vkd.acquireNextImageKHR(gc.dev, swapchain.handle, 1_000_000_000, present_semaphore, fence);
        const image_index = result.image_index;

        // now that we are sure that the commands finished executing, we can safely reset the command buffer to begin recording again
        try gc.vkd.resetCommandBuffer(cmdbufs[0], .{});

        // begin the command buffer recording. We will use this command buffer exactly once, so we want to let Vulkan know that
        try gc.vkd.beginCommandBuffer(cmdbufs[0], &.{
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        });

        // make a clear-color from frame number. This will flash with a 120*pi frame period
        const flash = std.math.absFloat(std.math.sin(@intToFloat(f32, frame_number) / 120.0));
        const clear_value = [_]vk.ClearValue{.{ .color = .{ .float_32 = .{ 0.0, 0.0, flash, 1.0 } } }};

        const rp_begin_info = vk.RenderPassBeginInfo{
            .render_pass = render_pass,
            .framebuffer = framebuffers[image_index],
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
            .clear_value_count = 1,
            .p_clear_values = &clear_value,
        };

        // start the main renderpass
        // we will use the clear color from above, and the framebuffer of the index the swapchain gave us
        gc.vkd.cmdBeginRenderPass(cmdbufs[0], &rp_begin_info, .@"inline");

        // finalize the render pass
        gc.vkd.cmdEndRenderPass(cmdbufs[0]);
        // // finalize the command buffer (we can no longer add commands, but it can now be executed)
        try gc.vkd.endCommandBuffer(cmdbufs[0]);

        // prepare the submission to the queue.
        // we want to wait on the present_semaphore, as that semaphore is signaled when the swapchain is ready
        // we will signal the render_semaphore, to signal that rendering has finished
        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast([*]const vk.Semaphore, &present_semaphore),
            .p_wait_dst_stage_mask = @ptrCast([*]const vk.PipelineStageFlags, &vk.PipelineStageFlags{ .color_attachment_output_bit = true }),
            .command_buffer_count = 1,
            .p_command_buffers = cmdbufs.ptr,
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast([*]const vk.Semaphore, &present_semaphore),
        };
        try gc.vkd.queueSubmit(gc.graphics_queue.handle, 1, @ptrCast([*]const vk.SubmitInfo, &submit_info), fence);

        // this will put the image we just rendered into the visible window.
        // we want to wait on the render_semaphore for that,
        // as it's necessary that drawing commands have finished before the image is displayed to the user
        _ = try gc.vkd.queuePresentKHR(gc.graphics_queue.handle, &.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast([*]const vk.Semaphore, &render_semaphore),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast([*]const vk.SwapchainKHR, &swapchain.handle),
            .p_image_indices = @ptrCast([*]const u32, &image_index),
            .p_results = null,
        });

        try glfw.pollEvents();
    }
}

fn createRenderPass(gc: *const GraphicsContext, swapchain: Swapchain) !vk.RenderPass {
    // the renderpass will use this color attachment
    const color_attachment = vk.AttachmentDescription{
        .flags = .{},
        .format = swapchain.surface_format.format,
        // 1 sample, we won't be doing MSAA
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .@"undefined",
        // after the renderpass ends, the image has to be on a layout ready for display
        .final_layout = .present_src_khr,
    };

    const color_attachment_ref = vk.AttachmentReference{
        // attachment number will index into the pAttachments array in the parent renderpass itself
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };

    // we are going to create 1 subpass, which is the minimum you can do
    const subpass = vk.SubpassDescription{
        .flags = .{},
        .pipeline_bind_point = .graphics,
        .input_attachment_count = 0,
        .p_input_attachments = undefined,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast([*]const vk.AttachmentReference, &color_attachment_ref),
        .p_resolve_attachments = null,
        .p_depth_stencil_attachment = null,
        .preserve_attachment_count = 0,
        .p_preserve_attachments = undefined,
    };

    return try gc.vkd.createRenderPass(gc.dev, &.{
        .flags = .{},
        .attachment_count = 1,
        .p_attachments = @ptrCast([*]const vk.AttachmentDescription, &color_attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast([*]const vk.SubpassDescription, &subpass),
        .dependency_count = 0,
        .p_dependencies = undefined,
    }, null);
}

fn createFramebuffers(gc: *const GraphicsContext, allocator: Allocator, render_pass: vk.RenderPass, swapchain: Swapchain) ![]vk.Framebuffer {
    const framebuffers = try allocator.alloc(vk.Framebuffer, swapchain.swap_images.len);
    errdefer allocator.free(framebuffers);

    var i: usize = 0;
    errdefer for (framebuffers[0..i]) |fb| gc.vkd.destroyFramebuffer(gc.dev, fb, null);

    for (framebuffers) |*fb| {
        fb.* = try gc.vkd.createFramebuffer(gc.dev, &.{
            .flags = .{},
            .render_pass = render_pass,
            .attachment_count = 1,
            .p_attachments = @ptrCast([*]const vk.ImageView, &swapchain.swap_images[i].view),
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
            .layers = 1,
        }, null);
        i += 1;
    }

    return framebuffers;
}
