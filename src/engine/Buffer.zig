buffer: vk.Buffer,
allocation: zva.Allocation,

const Buffer = @This();

const std = @import("std");
const log = std.log.scoped(.buffer);

const vk = @import("vulkan");
const zva = @import("zva");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Mesh = @import("Mesh.zig");
const Vertex = Mesh.Vertex;

pub fn create(
    gc: *const GraphicsContext,
    vma: *zva.Allocator,
    alloc_size: usize,
    usage: vk.BufferUsageFlags,
    memory_usage: zva.MemoryUsage,
) !Buffer {
    const buffer_info = vk.BufferCreateInfo{
        .flags = .{},
        .size = alloc_size,
        .usage = usage,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };
    const buffer = try gc.vkd.createBuffer(gc.dev, &buffer_info, null);
    errdefer gc.vkd.destroyBuffer(gc.dev, buffer, null);

    const mem_req = gc.vkd.getBufferMemoryRequirements(gc.dev, buffer);
    var allocation = try vma.alloc(
        mem_req.size,
        mem_req.alignment,
        mem_req.memory_type_bits,
        memory_usage,
        .Buffer,
        .{},
    );

    return Buffer{ .buffer = buffer, .allocation = allocation };
}

// TODO: probably move this to Mesh? unclear
pub fn uploadMesh(gc: *const GraphicsContext, vma: *zva.Allocator, mesh: Mesh) !Buffer {
    var buf = try Buffer.create(
        gc,
        vma,
        mesh.vertices.items.len * @sizeOf(Vertex),
        .{ .vertex_buffer_bit = true },
        .CpuToGpu,
    );
    errdefer buf.free(gc, vma);

    try gc.vkd.bindBufferMemory(gc.dev, buf.buffer, buf.allocation.memory, buf.allocation.offset);
    std.mem.copy(u8, buf.allocation.data, std.mem.sliceAsBytes(mesh.vertices.items));

    return buf;
}

pub fn free(self: *Buffer, gc: *const GraphicsContext, vma: *zva.Allocator) void {
    gc.vkd.destroyBuffer(gc.dev, self.buffer, null);
    vma.free(self.allocation);

    self.* = undefined;
}
