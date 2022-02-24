const std = @import("std");
const log = std.log;
const Allocator = std.mem.Allocator;

// TODO: sort out these imports
const glfw = @import("glfw");
const resources = @import("resources");
const vk = @import("vulkan");
const zva = @import("zva");
const zlm = @import("zlm");

const GraphicsContext = @import("engine/graphics_context.zig").GraphicsContext;
const Swapchain = @import("engine/swapchain.zig").Swapchain;

const Mesh = @import("engine/Mesh.zig");
const Buffer = @import("engine/Buffer.zig");

const Frames = @import("engine/frames.zig").Frames;
const Frame = @import("engine/frames.zig").Frame;
const GpuCameraData = @import("engine/frames.zig").GpuCameraData;

const createPipeline = @import("engine/pipeline.zig").createPipeline;
const createRenderPass = @import("engine/renderpass.zig").createRenderPass;
const Framebuffers = @import("engine/Framebuffers.zig");

const vec3 = zlm.vec3;
const Vec3 = zlm.Vec3;
const Vec4 = zlm.Vec4;
const Mat4 = zlm.Mat4;

pub const PushConstants = struct {
    data: Vec4,
    render_matrix: Mat4,
};

var g_selectedShader: enum { red, colored, mesh } = .mesh;

const font_file = @embedFile("../deps/techna-sans/TechnaSans-Regular.otf");

// TODO: split into init/draw functions, with minimal defined shared state
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try glfw.init(.{});
    errdefer glfw.terminate();

    // TODO: account for HiDPI
    // window size
    var extent = vk.Extent2D{ .width = 800, .height = 600 };

    // create the glfw window
    const window = try glfw.Window.create(
        extent.width,
        extent.height,
        "vkguide.dev",
        null,
        null,
        .{ .client_api = .no_api },
    );
    defer window.destroy();

    // add simple key commands
    window.setKeyCallback((struct {
        fn callback(_window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
            _ = scancode;
            _ = mods;

            // only handle keydown events
            if (action != .press and action != .repeat) return;

            switch (key) {
                .escape => _window.setShouldClose(true),
                .space => g_selectedShader = switch (g_selectedShader) {
                    .red => .colored,
                    .colored => .mesh,
                    .mesh => .red,
                },
                else => {},
            }
        }
    }).callback);

    // initialise vulkan using the GLFW window with vulkan-zig
    const gc = try GraphicsContext.init(allocator, "vkguide example", window);
    defer gc.deinit();

    log.info("Using device: {s}", .{gc.deviceName()});

    // initialise a vulkan allocator
    // this is a light wrapper over the vulkan GPU memory functions
    // TODO: refactor to be more ergonomic with more recent vulkan-zig
    var vma = try zva.Allocator.init(allocator, .{
        .getPhysicalDeviceProperties = gc.vki.dispatch.vkGetPhysicalDeviceProperties,
        .getPhysicalDeviceMemoryProperties = gc.vki.dispatch.vkGetPhysicalDeviceMemoryProperties,

        .allocateMemory = gc.vkd.dispatch.vkAllocateMemory,
        .freeMemory = gc.vkd.dispatch.vkFreeMemory,
        .mapMemory = gc.vkd.dispatch.vkMapMemory,
        .unmapMemory = gc.vkd.dispatch.vkUnmapMemory,
    }, gc.pdev, gc.dev, 128);
    defer vma.deinit();

    // a swapchain is a list of images accessible to the OS to draw to the screen
    var swapchain = try Swapchain.init(&gc, allocator, extent);
    defer swapchain.deinit();

    // create a static buffer of all frame-specific data
    // this allows double buffering by preparing the next frame while the previous frame is being drawn
    var frames = try Frames(2).create(&gc, &vma);
    defer frames.free();

    // define the mesh for the mesh shader pipeline
    var mesh = Mesh.init(allocator);
    defer mesh.deinit();
    try mesh.loadObj("assets/models/suzanne.obj");

    // copy the mesh data to a shared CPU->GPU buffer
    var buffer = try Buffer.uploadMesh(&gc, &vma, mesh);
    defer buffer.free(&gc, &vma);

    // all rendering commands must occur within a render pass
    // a render pass encapsulates the state required to setup the target for rendering,
    // and the state of the images being rendered
    const render_pass = try createRenderPass(&gc, swapchain.surface_format.format, .d32_sfloat);
    defer gc.vkd.destroyRenderPass(gc.dev, render_pass, null);

    // a pipeline turns data/programs into pixels
    // a pipeline has several sequential stages, defined by shaders
    // the pipeline layout defines the stucture of the stages of the pipeline,
    // and can be reused between pipelines
    const pipeline_layout = try gc.vkd.createPipelineLayout(gc.dev, &.{
        .flags = .{},
        .set_layout_count = 0,
        .p_set_layouts = undefined,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
    }, null);
    defer gc.vkd.destroyPipelineLayout(gc.dev, pipeline_layout, null);

    // solid red triangle
    const red_pipeline = try createPipeline(
        &gc,
        resources.red_triangle_vert,
        resources.red_triangle_frag,
        pipeline_layout,
        render_pass,
        swapchain.extent,
        .{},
    );
    defer gc.vkd.destroyPipeline(gc.dev, red_pipeline, null);

    // interpolated color triangle
    const colored_pipeline = try createPipeline(
        &gc,
        resources.colored_triangle_vert,
        resources.colored_triangle_frag,
        pipeline_layout,
        render_pass,
        swapchain.extent,
        .{},
    );
    defer gc.vkd.destroyPipeline(gc.dev, colored_pipeline, null);

    // push constants provide a simple method for passing small amounts of data
    // directly to a shader (both vertex and fragment)
    const push_constant = vk.PushConstantRange{
        .stage_flags = .{ .vertex_bit = true },
        .offset = 0,
        .size = @sizeOf(PushConstants),
    };

    // mesh gets its own pipeline layout to allow for push constants
    const mesh_pipeline_layout = try gc.vkd.createPipelineLayout(gc.dev, &.{
        .flags = .{},
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &frames.shared_data.global_set_layout),
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast([*]const vk.PushConstantRange, &push_constant),
    }, null);
    defer gc.vkd.destroyPipelineLayout(gc.dev, mesh_pipeline_layout, null);

    // mesh vertices, using colored triangle interpolation
    const mesh_pipeline = try createPipeline(
        &gc,
        resources.mesh_vert,
        resources.colored_triangle_frag,
        mesh_pipeline_layout,
        render_pass,
        swapchain.extent,
        .{ .vert_input_desc = Mesh.Vertex.desc() },
    );
    defer gc.vkd.destroyPipeline(gc.dev, mesh_pipeline, null);

    // framebuffers are created from a render pass, and are the link between the attachements
    // of a renderpass and the real images they should render to
    var framebuffers = try Framebuffers.create(&gc, &vma, allocator, render_pass, swapchain);
    defer framebuffers.free(&gc, &vma);

    // a fence is used to ensure the GPU has finished it's work before continuing
    var fence = try gc.vkd.createFence(gc.dev, &.{ .flags = .{ .signaled_bit = true } }, null);
    defer gc.vkd.destroyFence(gc.dev, fence, null);

    // wait until device is idle to start cleanup
    defer gc.vkd.deviceWaitIdle(gc.dev) catch {};

    // wait for the user to close the window.
    var frame_number: u32 = 0;
    var need_resize = false;
    while (!window.shouldClose()) : (frame_number += 1) {
        // check if minimized
        var curr_size = try window.getFramebufferSize();
        if (curr_size.width == 0 and curr_size.height == 0) {
            try glfw.waitEvents();
            continue;
        }

        // get the current frame to ensure the correct data buffers are being written to
        // this also gets the correct semaphores to ensure we're waiting on the correct operations
        const curr_frame = frames.currentFrame(frame_number);

        // wait until the GPU has finished rendering the last frame. Timeout of 1 second
        _ = try gc.vkd.waitForFences(gc.dev, 1, @ptrCast([*]vk.Fence, &fence), @boolToInt(true), 1_000_000_000);
        try gc.vkd.resetFences(gc.dev, 1, @ptrCast([*]vk.Fence, &fence));

        // now that we are sure that the commands finished executing, we can safely reset the command buffer to begin recording again
        try gc.vkd.resetCommandBuffer(curr_frame.cmd_buf, .{});

        if (need_resize) {
            const new_size = @bitCast(vk.Extent2D, try window.getSize());
            try swapchain.recreate(new_size);
            try framebuffers.recreate(&gc, &vma, render_pass, swapchain);

            need_resize = false;
        }

        // request image from the swapchain, one second timeout
        const result = try gc.vkd.acquireNextImageKHR(gc.dev, swapchain.handle, 1_000_000_000, curr_frame.present_semaphore, .null_handle);
        const image_index = result.image_index;

        // begin the command buffer recording
        // we will use this command buffer exactly once, so we want to let Vulkan know that
        try gc.vkd.beginCommandBuffer(curr_frame.cmd_buf, &.{
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        });

        // make a clear-color from frame number
        const flash = std.math.absFloat(std.math.sin(@intToFloat(f32, frame_number) / 120.0));
        const clear_value = vk.ClearValue{ .color = .{ .float_32 = .{ 0.0, 0.0, flash, 1.0 } } };

        // clear depth at 1
        const depth_clear = vk.ClearValue{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } };

        const rp_begin_info = vk.RenderPassBeginInfo{
            .render_pass = render_pass,
            .framebuffer = framebuffers.buffers[image_index],
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = swapchain.extent },
            .clear_value_count = 2,
            .p_clear_values = &[_]vk.ClearValue{ clear_value, depth_clear },
        };

        // start the main renderpass
        // we will use the clear color from above, and the framebuffer of the index the swapchain gave us
        gc.vkd.cmdBeginRenderPass(curr_frame.cmd_buf, &rp_begin_info, .@"inline");

        gc.vkd.cmdBindPipeline(curr_frame.cmd_buf, .graphics, switch (g_selectedShader) {
            .red => red_pipeline,
            .colored => colored_pipeline,
            .mesh => mesh_pipeline,
        });

        if (g_selectedShader == .mesh) {
            gc.vkd.cmdBindVertexBuffers(curr_frame.cmd_buf, 0, 1, @ptrCast([*]const vk.Buffer, &buffer.buffer), &[_]vk.DeviceSize{0});

            // make a model view matrix for rendering the object
            var projection = Mat4.createPerspective(
                zlm.toRadians(60.0),
                800.0 / 600.0,
                0.1,
                200.0,
            );
            projection.fields[1][1] *= -1;

            const UP = vec3(0, 1, 0);
            const CENTRE = Vec3.zero;

            const cam_pos = vec3(0, 0.6, 3);
            const view = Mat4.createLookAt(cam_pos, CENTRE, UP);

            const rot_mat = Mat4.createAngleAxis(UP, zlm.toRadians(@intToFloat(f32, frame_number)));

            const cam_data = GpuCameraData{
                .proj = projection,
                .view = view,
                .view_proj = rot_mat.mul(view.mul(projection)),
            };

            std.mem.copy(u8, curr_frame.camera_buf.allocation.data, std.mem.asBytes(&cam_data));
            gc.vkd.cmdBindDescriptorSets(
                curr_frame.cmd_buf,
                .graphics,
                mesh_pipeline_layout,
                0,
                1,
                @ptrCast([*]const vk.DescriptorSet, &curr_frame.global_desc),
                0,
                undefined,
            );

            const constants = PushConstants{
                .data = Vec4.zero,
                .render_matrix = Mat4.identity,
            };
            gc.vkd.cmdPushConstants(
                curr_frame.cmd_buf,
                mesh_pipeline_layout,
                .{ .vertex_bit = true },
                0,
                @sizeOf(PushConstants),
                std.mem.asBytes(&constants),
            );

            gc.vkd.cmdDraw(curr_frame.cmd_buf, @intCast(u32, mesh.vertices.items.len), 1, 0, 0);
        } else {
            gc.vkd.cmdDraw(curr_frame.cmd_buf, 3, 1, 0, 0);
        }

        // finalize the render pass
        gc.vkd.cmdEndRenderPass(curr_frame.cmd_buf);
        // finalize the command buffer (we can no longer add commands, but it can now be executed)
        try gc.vkd.endCommandBuffer(curr_frame.cmd_buf);

        // prepare the submission to the queue.
        // we want to wait on the present_semaphore, as that semaphore is signaled when the swapchain is ready
        // we will signal the render_semaphore, to signal that rendering has finished
        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast([*]const vk.Semaphore, &curr_frame.present_semaphore),
            .p_wait_dst_stage_mask = @ptrCast([*]const vk.PipelineStageFlags, &vk.PipelineStageFlags{ .color_attachment_output_bit = true }),
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast([*]vk.CommandBuffer, &curr_frame.cmd_buf),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast([*]const vk.Semaphore, &curr_frame.render_semaphore),
        };
        try gc.vkd.queueSubmit(gc.graphics_queue.handle, 1, @ptrCast([*]const vk.SubmitInfo, &submit_info), fence);

        // this will put the image we just rendered into the visible window.
        // we want to wait on the render_semaphore for that,
        // as it's necessary that drawing commands have finished before the image is displayed to the user
        _ = gc.vkd.queuePresentKHR(gc.graphics_queue.handle, &.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast([*]const vk.Semaphore, &curr_frame.render_semaphore),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast([*]const vk.SwapchainKHR, &swapchain.handle),
            .p_image_indices = @ptrCast([*]const u32, &image_index),
            .p_results = null,
        }) catch |err| switch (err) {
            error.OutOfDateKHR => need_resize = true,
            else => return err,
        };

        try glfw.pollEvents();
    }
}
