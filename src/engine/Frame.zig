// synchronisation structures
present_semaphore: vk.Semaphore,
render_semaphore: vk.Semaphore,

// command pool and buffer
cmd_pool: vk.CommandPool,
cmd_buf: vk.CommandBuffer,

// camera data and per-frame descriptor set
camera_buf: Buffer,
global_desc: vk.DescriptorSet,

// TODO: move this global state
// number of frames to overlap when rendering
const FRAME_OVERLAP = 2;
var frame_buf = [_]Frame{undefined} ** FRAME_OVERLAP;
// keep track of how many frames have been created so they can be free'd
var initialised_frames: usize = 0;

const POOL_SIZES = [_]vk.DescriptorPoolSize{
    .{ .@"type" = .uniform_buffer, .descriptor_count = 10 },
};
var descriptor_pool: ?vk.DescriptorPool = null;

var cam_buffer_binding = vk.DescriptorSetLayoutBinding{
    .binding = 0,
    .descriptor_type = .uniform_buffer,
    .descriptor_count = 1,
    // we use it from the vertex shader
    .stage_flags = .{ .vertex_bit = true },
    .p_immutable_samplers = null,
};
pub var global_set_layout: ?vk.DescriptorSetLayout = null;

const Frame = @This();

const std = @import("std");
const log = std.log.scoped(.frame);

const vk = @import("vulkan");
const zva = @import("zva");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Mat4 = @import("zlm").Mat4;
const Buffer = @import("Buffer.zig");

pub const GpuCameraData = struct {
    view: Mat4,
    proj: Mat4,
    view_proj: Mat4,
};

pub fn getCurrentFrame(frame_number: u32) *Frame {
    const curr_frame = frame_number % FRAME_OVERLAP;
    if (curr_frame > initialised_frames) {
        log.err(
            "frame {}/{} has not yet been initialised! (only {} initialised)",
            .{ curr_frame, FRAME_OVERLAP, initialised_frames },
        );
        unreachable;
    }

    return &frame_buf[curr_frame];
}

pub fn createAll(gc: *const GraphicsContext, vma: *zva.Allocator) ![]Frame {
    errdefer freeAll(gc, vma);

    // create camera descriptor set
    global_set_layout = try gc.vkd.createDescriptorSetLayout(gc.dev, &.{
        .flags = .{},
        .binding_count = 1,
        .p_bindings = @ptrCast([*]vk.DescriptorSetLayoutBinding, &cam_buffer_binding),
    }, null);

    descriptor_pool = try gc.vkd.createDescriptorPool(gc.dev, &.{
        .flags = .{},
        .max_sets = 10,
        .pool_size_count = @intCast(u32, POOL_SIZES.len),
        .p_pool_sizes = &POOL_SIZES,
    }, null);

    for (frame_buf) |*frame| {
        frame.* = try create(gc, vma);
        initialised_frames += 1;
    }

    return frame_buf[0..initialised_frames];
}

pub fn freeAll(gc: *const GraphicsContext, vma: *zva.Allocator) void {
    for (frame_buf[0..initialised_frames]) |*frame|
        frame.free(gc, vma);

    if (descriptor_pool) |dp| {
        gc.vkd.destroyDescriptorPool(gc.dev, dp, null);
        descriptor_pool = null;
    }

    if (global_set_layout) |gsl| {
        gc.vkd.destroyDescriptorSetLayout(gc.dev, gsl, null);
        global_set_layout = null;
    }

    initialised_frames = 0;
}

fn create(gc: *const GraphicsContext, vma: *zva.Allocator) !Frame {
    var frame: Frame = undefined;

    try frame.createSyncStructures(gc);
    errdefer frame.freeSyncStructures(gc);

    try frame.createCommandBuffer(gc);
    errdefer frame.freeCommandBuffer(gc);

    try frame.createCameraBuffer(gc, vma);
    errdefer frame.freeCameraBuffer(gc, vma);

    return frame;
}

fn free(self: *Frame, gc: *const GraphicsContext, vma: *zva.Allocator) void {
    self.freeCameraBuffer(gc, vma);
    self.freeCommandBuffer(gc);
    self.freeSyncStructures(gc);

    self.* = undefined;
}

fn createSyncStructures(self: *Frame, gc: *const GraphicsContext) !void {
    self.present_semaphore = try gc.vkd.createSemaphore(gc.dev, &.{ .flags = .{} }, null);
    errdefer gc.vkd.destroySemaphore(gc.dev, self.present_semaphore, null);

    self.render_semaphore = try gc.vkd.createSemaphore(gc.dev, &.{ .flags = .{} }, null);
}

fn freeSyncStructures(self: *Frame, gc: *const GraphicsContext) void {
    gc.vkd.destroySemaphore(gc.dev, self.render_semaphore, null);
    gc.vkd.destroySemaphore(gc.dev, self.present_semaphore, null);

    self.render_semaphore = undefined;
    self.present_semaphore = undefined;
}

fn createCommandBuffer(self: *Frame, gc: *const GraphicsContext) !void {
    // create a command pool for commands submitted to the graphics queue
    self.cmd_pool = try gc.vkd.createCommandPool(gc.dev, &.{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = gc.graphics_queue.family,
    }, null);
    errdefer gc.vkd.destroyCommandPool(gc.dev, self.cmd_pool, null);

    // allocate the default command buffer that we will use for rendering
    try gc.vkd.allocateCommandBuffers(gc.dev, &.{
        .command_pool = self.cmd_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast([*]vk.CommandBuffer, &self.cmd_buf));
}

fn freeCommandBuffer(self: *Frame, gc: *const GraphicsContext) void {
    gc.vkd.freeCommandBuffers(
        gc.dev,
        self.cmd_pool,
        1,
        @ptrCast([*]vk.CommandBuffer, &self.cmd_buf),
    );
    gc.vkd.destroyCommandPool(gc.dev, self.cmd_pool, null);

    self.cmd_pool = undefined;
}

fn createCameraBuffer(self: *Frame, gc: *const GraphicsContext, vma: *zva.Allocator) !void {
    self.camera_buf = try Buffer.create(gc, vma, @sizeOf(GpuCameraData), .{ .uniform_buffer_bit = true }, .CpuToGpu);
    errdefer self.camera_buf.free(gc, vma);

    // allocate one descriptor set for each frame
    try gc.vkd.allocateDescriptorSets(gc.dev, &.{
        .descriptor_pool = descriptor_pool.?,
        .descriptor_set_count = 1,
        .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &global_set_layout.?),
    }, @ptrCast([*]vk.DescriptorSet, &self.global_desc));

    try gc.vkd.bindBufferMemory(
        gc.dev,
        self.camera_buf.buffer,
        self.camera_buf.allocation.memory,
        self.camera_buf.allocation.offset,
    );

    // point the descriptor to the camera buffer
    const set_write = vk.WriteDescriptorSet{
        .dst_set = self.global_desc,
        .dst_binding = 0,
        .dst_array_element = 0,

        .descriptor_count = 1,
        .descriptor_type = .uniform_buffer,

        .p_image_info = undefined,
        .p_buffer_info = &.{
            .buffer = self.camera_buf.buffer,
            .offset = 0,
            .range = @sizeOf(GpuCameraData),
        },
        .p_texel_buffer_view = undefined,
    };

    gc.vkd.updateDescriptorSets(
        gc.dev,
        1,
        @ptrCast([*]const vk.WriteDescriptorSet, &set_write),
        0,
        undefined,
    );
}

fn freeCameraBuffer(self: *Frame, gc: *const GraphicsContext, vma: *zva.Allocator) void {
    self.camera_buf.free(gc, vma);

    self.camera_buf = undefined;
}
