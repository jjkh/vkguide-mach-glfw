const std = @import("std");

const vk = @import("vulkan");
const glfw = @import("glfw");
const resources = @import("resources");
const zva = @import("zva");

const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Swapchain = @import("swapchain.zig").Swapchain;
const Allocator = std.mem.Allocator;

pub const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

var g_selectedShader: enum { red, colored } = .red;

const font_file = @embedFile("../deps/techna-sans/TechnaSans-Regular.otf");

const AllocatedBuffer = struct {
    buffer: vk.Buffer,
    allocation: zva.Allocation,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try glfw.init(.{});
    errdefer glfw.terminate();

    // var ft_handle: c.FT_Library = undefined;
    // {
    //     const status = c.FT_Init_FreeType(&ft_handle);
    //     if (status > 0) {
    //         std.debug.print("freetype init failed with code {}\n", .{status});
    //         return error.FreeTypeInitFailed;
    //     }
    // }
    // defer _ = c.FT_Done_FreeType(ft_handle);

    // var ft_face: c.FT_Face = undefined;
    // {
    //     const status = c.FT_New_Memory_Face(ft_handle, font_file, font_file.len, 0, &ft_face);
    //     if (status > 0) {
    //         std.debug.print("font load failed with code {}\n", .{status});
    //         return error.FreeTypeInitFailed;
    //     }
    // }
    // defer _ = c.FT_Done_Face(ft_face);

    // _ = c.FT_Set_Pixel_Sizes(ft_face, 0, 48);

    // {
    //     const status = c.FT_Load_Char(ft_face, 'x', c.FT_LOAD_RENDER);
    //     if (status > 0) {
    //         std.debug.print("glyph 'x' load failed with code {}\n", .{status});
    //         return error.FreeTypeInitFailed;
    //     }
    // }
    // defer _ = c.FT_Done_Face(ft_face);

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

    window.setKeyCallback((struct {
        fn callback(_window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
            _ = scancode;
            _ = mods;

            if (action != .press and action != .repeat) return;

            switch (key) {
                .escape => _window.setShouldClose(true),
                .space => g_selectedShader = if (g_selectedShader == .red) .colored else .red,
                else => {},
            }
        }
    }).callback);

    const gc = try GraphicsContext.init(allocator, "vkguide example", window);
    defer gc.deinit();

    std.debug.print("Using device: {s}\n", .{gc.deviceName()});

    const v_alloc = try zva.Allocator.init(allocator, .{
        .getPhysicalDeviceProperties = gc.vki.dispatch.vkGetPhysicalDeviceProperties,
        .getPhysicalDeviceMemoryProperties = gc.vki.dispatch.vkGetPhysicalDeviceMemoryProperties,

        .allocateMemory = gc.vkd.dispatch.vkAllocateMemory,
        .freeMemory = gc.vkd.dispatch.vkFreeMemory,
        .mapMemory = gc.vkd.dispatch.vkMapMemory,
        .unmapMemory = gc.vkd.dispatch.vkUnmapMemory,
    }, gc.pdev, gc.dev, 128);
    defer v_alloc.deinit();

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

    const pipeline_layout = try gc.vkd.createPipelineLayout(gc.dev, &.{
        .flags = .{},
        .set_layout_count = 0,
        .p_set_layouts = undefined,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
    }, null);
    defer gc.vkd.destroyPipelineLayout(gc.dev, pipeline_layout, null);

    const render_pass = try createRenderPass(&gc, swapchain);
    defer gc.vkd.destroyRenderPass(gc.dev, render_pass, null);

    const red_pipeline = try createPipeline(
        &gc,
        resources.red_triangle_vert,
        resources.red_triangle_frag,
        pipeline_layout,
        render_pass,
        swapchain.extent,
    );
    defer gc.vkd.destroyPipeline(gc.dev, red_pipeline, null);

    const colored_pipeline = try createPipeline(
        &gc,
        resources.colored_triangle_vert,
        resources.colored_triangle_frag,
        pipeline_layout,
        render_pass,
        swapchain.extent,
    );
    defer gc.vkd.destroyPipeline(gc.dev, colored_pipeline, null);

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

    // wait until device is idle to start cleanup
    defer gc.vkd.deviceWaitIdle(gc.dev) catch {};

    var frame_number: u32 = 0;
    // Wait for the user to close the window.
    while (!window.shouldClose()) : (frame_number += 1) {
        const cmdbuf = cmdbufs[0];

        // wait until the GPU has finished rendering the last frame. Timeout of 1 second
        _ = try gc.vkd.waitForFences(gc.dev, 1, @ptrCast([*]vk.Fence, &fence), @boolToInt(true), 1_000_000_000);
        try gc.vkd.resetFences(gc.dev, 1, @ptrCast([*]vk.Fence, &fence));

        // now that we are sure that the commands finished executing, we can safely reset the command buffer to begin recording again
        try gc.vkd.resetCommandBuffer(cmdbuf, .{});

        // request image from the swapchain, one second timeout
        const result = try gc.vkd.acquireNextImageKHR(gc.dev, swapchain.handle, 1_000_000_000, present_semaphore, .null_handle);
        const image_index = result.image_index;

        // begin the command buffer recording. We will use this command buffer exactly once, so we want to let Vulkan know that
        try gc.vkd.beginCommandBuffer(cmdbuf, &.{
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        });

        // make a clear-color from frame number. This will flash with a 12,000*pi frame period
        const flash = std.math.absFloat(std.math.sin(@intToFloat(f32, frame_number) / 12_000.0));
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
        gc.vkd.cmdBeginRenderPass(cmdbuf, &rp_begin_info, .@"inline");

        gc.vkd.cmdBindPipeline(cmdbuf, .graphics, if (g_selectedShader == .red) red_pipeline else colored_pipeline);
        gc.vkd.cmdDraw(cmdbuf, 3, 1, 0, 0);

        // finalize the render pass
        gc.vkd.cmdEndRenderPass(cmdbuf);
        // finalize the command buffer (we can no longer add commands, but it can now be executed)
        try gc.vkd.endCommandBuffer(cmdbuf);

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
            .p_signal_semaphores = @ptrCast([*]const vk.Semaphore, &render_semaphore),
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

fn loadShaderModule(gc: *const GraphicsContext, shader: []const u8) !vk.ShaderModule {
    return gc.vkd.createShaderModule(gc.dev, &.{
        .flags = .{},
        .code_size = shader.len,
        .p_code = @ptrCast([*]const u32, @alignCast(4, shader)),
    }, null);
}

fn createPipeline(
    gc: *const GraphicsContext,
    vert_shader: []const u8,
    frag_shader: []const u8,
    layout: vk.PipelineLayout,
    render_pass: vk.RenderPass,
    extent: vk.Extent2D,
) !vk.Pipeline {
    const vert = try loadShaderModule(gc, vert_shader);
    defer gc.vkd.destroyShaderModule(gc.dev, vert, null);

    const frag = try loadShaderModule(gc, frag_shader);
    defer gc.vkd.destroyShaderModule(gc.dev, frag, null);
    // build the stage_create_info for both vertex and fragment stages.
    // this lets the pipeline know the shader modules per stage
    const stage_infos = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .flags = .{},
            .stage = .{ .vertex_bit = true },
            .module = vert,
            .p_name = "main",
            .p_specialization_info = null,
        },
        .{
            .flags = .{},
            .stage = .{ .fragment_bit = true },
            .module = frag,
            .p_name = "main",
            .p_specialization_info = null,
        },
    };

    // vertex input controls how to read vertices from vertex buffers
    // currently unused
    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
        .flags = .{},
        .vertex_binding_description_count = 0,
        .p_vertex_binding_descriptions = undefined,
        .vertex_attribute_description_count = 0,
        .p_vertex_attribute_descriptions = undefined,
    };

    // input assembly is the configuration for drawing triangle lists, strips, or individual points.
    // we are just going to draw triangle list
    const input_assembly_info = vk.PipelineInputAssemblyStateCreateInfo{
        .flags = .{},
        .topology = .triangle_list,
        .primitive_restart_enable = vk.FALSE,
    };

    // configure the rasterizer to draw filled triangles
    const rasterization_info = vk.PipelineRasterizationStateCreateInfo{
        .flags = .{},
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,

        .polygon_mode = .fill,
        .cull_mode = .{},
        .front_face = .clockwise,

        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0.0,
        .depth_bias_clamp = 0.0,
        .depth_bias_slope_factor = 0.0,

        .line_width = 1.0,
    };

    // we don't use MSAA so just run the default one
    const msaa_info = vk.PipelineMultisampleStateCreateInfo{
        .flags = .{},
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = vk.FALSE,
        .min_sample_shading = 1.0,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };

    // a single blend attachment with no blending that writes to RGBA
    const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
        .blend_enable = vk.FALSE,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,

        .color_write_mask = .{
            .r_bit = true,
            .g_bit = true,
            .b_bit = true,
            .a_bit = true,
        },
    };
    const color_blend_info = vk.PipelineColorBlendStateCreateInfo{
        .flags = .{},
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast([*]const @TypeOf(color_blend_attachment), &color_blend_attachment),
        .blend_constants = [_]f32{ 0.0, 0.0, 0.0, 0.0 },
    };

    const viewport = vk.Viewport{
        .x = 0.0,
        .y = 0.0,
        .width = @intToFloat(f32, extent.width),
        .height = @intToFloat(f32, extent.height),
        .min_depth = 0.0,
        .max_depth = 1.0,
    };
    const scissor = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    };
    const viewport_info = vk.PipelineViewportStateCreateInfo{
        .flags = .{},
        .viewport_count = 1,
        .p_viewports = @ptrCast([*]const vk.Viewport, &viewport),
        .scissor_count = 1,
        .p_scissors = @ptrCast([*]const vk.Rect2D, &scissor),
    };

    const pipeline_info = vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .stage_count = stage_infos.len,
        .p_stages = &stage_infos,
        .p_vertex_input_state = &vertex_input_info,
        .p_input_assembly_state = &input_assembly_info,
        .p_tessellation_state = null,
        .p_viewport_state = &viewport_info,
        .p_rasterization_state = &rasterization_info,
        .p_multisample_state = &msaa_info,
        .p_depth_stencil_state = null,
        .p_color_blend_state = &color_blend_info,
        .p_dynamic_state = null,
        .layout = layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try gc.vkd.createGraphicsPipelines(
        gc.dev,
        .null_handle,
        1,
        @ptrCast([*]const vk.GraphicsPipelineCreateInfo, &pipeline_info),
        null,
        @ptrCast([*]vk.Pipeline, &pipeline),
    );
    return pipeline;
}
