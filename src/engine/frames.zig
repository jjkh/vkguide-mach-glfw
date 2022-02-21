const std = @import("std");

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

const SharedFrameData = struct {
    gc: *const GraphicsContext,
    vma: *zva.Allocator,

    global_set_layout: vk.DescriptorSetLayout = undefined,
    descriptor_pool: vk.DescriptorPool = undefined,

    // this seems not right...
    cam_buffer_binding: vk.DescriptorSetLayoutBinding = .{
        .binding = 0,
        .descriptor_type = .uniform_buffer,
        .descriptor_count = 1,
        // we use it from the vertex shader
        .stage_flags = .{ .vertex_bit = true },
        .p_immutable_samplers = null,
    },

    const POOL_SIZES = [_]vk.DescriptorPoolSize{
        .{ .@"type" = .uniform_buffer, .descriptor_count = 10 },
    };
};

pub fn Frames(comptime frame_overlap: usize) type {
    return struct {
        const log = std.log.scoped(.frames);

        frames: [frame_overlap]Frame = undefined,

        // keep track of how many frames have been created so they can be freed
        created_frames: usize = 0,

        shared_data: SharedFrameData = undefined,

        const Self = @This();

        pub fn currentFrame(self: *Self, frame_number: u32) *Frame {
            const curr_frame = frame_number % frame_overlap;
            if (curr_frame > self.created_frames) {
                log.err(
                    "frame {}/{} has not yet been initialised! (only {} initialised)",
                    .{ curr_frame, frame_overlap, self.created_frames },
                );
                unreachable;
            }

            return &self.frames[curr_frame];
        }

        pub fn create(gc: *const GraphicsContext, vma: *zva.Allocator) !Self {
            var sfd = SharedFrameData{ .gc = gc, .vma = vma };
            // create camera descriptor set
            {
                sfd.global_set_layout = try gc.vkd.createDescriptorSetLayout(gc.dev, &.{
                    .flags = .{},
                    .binding_count = 1,
                    .p_bindings = @ptrCast([*]vk.DescriptorSetLayoutBinding, &sfd.cam_buffer_binding),
                }, null);
                errdefer gc.vkd.destroyDescriptorSetLayout(gc.dev, sfd.global_set_layout, null);

                sfd.descriptor_pool = try gc.vkd.createDescriptorPool(gc.dev, &.{
                    .flags = .{},
                    .max_sets = 10,
                    .pool_size_count = @intCast(u32, SharedFrameData.POOL_SIZES.len),
                    .p_pool_sizes = &SharedFrameData.POOL_SIZES,
                }, null);
            }

            var self = Self{ .shared_data = sfd, .created_frames = 0 };
            errdefer self.free();

            for (self.frames) |*frame| {
                frame.* = try Frame.create(sfd);
                self.created_frames += 1;
            }

            return self;
        }

        pub fn free(self: *Self) void {
            for (self.frames[0..self.created_frames]) |*frame| frame.free();
            self.created_frames = 0;

            const sfd = self.shared_data;

            sfd.gc.vkd.destroyDescriptorPool(sfd.gc.dev, sfd.descriptor_pool, null);
            sfd.gc.vkd.destroyDescriptorSetLayout(sfd.gc.dev, sfd.global_set_layout, null);

            self.* = undefined;
        }
    };
}

pub const Frame = struct {
    shared_data: SharedFrameData,

    // synchronisation structures
    present_semaphore: vk.Semaphore = undefined,
    render_semaphore: vk.Semaphore = undefined,

    // command pool and buffer
    cmd_pool: vk.CommandPool = undefined,
    cmd_buf: vk.CommandBuffer = undefined,

    // camera data and per-frame descriptor set
    camera_buf: Buffer = undefined,
    global_desc: vk.DescriptorSet = undefined,

    const log = std.log.scoped(.frames);

    fn create(shared_data: SharedFrameData) !Frame {
        var frame = Frame{ .shared_data = shared_data };

        try frame.createSyncStructures();
        errdefer frame.freeSyncStructures();

        try frame.createCommandBuffer();
        errdefer frame.freeCommandBuffer();

        try frame.createCameraBuffer();
        errdefer frame.freeCameraBuffer();

        return frame;
    }

    fn free(self: *Frame) void {
        self.freeCameraBuffer();
        self.freeCommandBuffer();
        self.freeSyncStructures();

        self.* = undefined;
    }

    fn createSyncStructures(self: *Frame) !void {
        const gc = self.shared_data.gc;

        self.present_semaphore = try gc.vkd.createSemaphore(gc.dev, &.{ .flags = .{} }, null);
        errdefer gc.vkd.destroySemaphore(gc.dev, self.present_semaphore, null);

        self.render_semaphore = try gc.vkd.createSemaphore(gc.dev, &.{ .flags = .{} }, null);
    }

    fn freeSyncStructures(self: *Frame) void {
        const gc = self.shared_data.gc;

        gc.vkd.destroySemaphore(gc.dev, self.render_semaphore, null);
        gc.vkd.destroySemaphore(gc.dev, self.present_semaphore, null);

        self.render_semaphore = undefined;
        self.present_semaphore = undefined;
    }

    fn createCommandBuffer(self: *Frame) !void {
        const gc = self.shared_data.gc;

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

    fn freeCommandBuffer(self: *Frame) void {
        const gc = self.shared_data.gc;

        gc.vkd.freeCommandBuffers(
            gc.dev,
            self.cmd_pool,
            1,
            @ptrCast([*]vk.CommandBuffer, &self.cmd_buf),
        );
        gc.vkd.destroyCommandPool(gc.dev, self.cmd_pool, null);

        self.cmd_pool = undefined;
    }

    fn createCameraBuffer(self: *Frame) !void {
        const sfd = self.shared_data;
        const gc = sfd.gc;

        self.camera_buf = try Buffer.create(gc, sfd.vma, @sizeOf(GpuCameraData), .{ .uniform_buffer_bit = true }, .CpuToGpu);
        errdefer self.camera_buf.free(gc, sfd.vma);

        // allocate one descriptor set for each frame
        try gc.vkd.allocateDescriptorSets(gc.dev, &.{
            .descriptor_pool = sfd.descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &sfd.global_set_layout),
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

    fn freeCameraBuffer(self: *Frame) void {
        self.camera_buf.free(self.shared_data.gc, self.shared_data.vma);
        self.camera_buf = undefined;
    }
};
