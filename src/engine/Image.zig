image: vk.Image,
view: vk.ImageView,
allocation: zva.Allocation,

const Image = @This();

const vk = @import("vulkan");
const zva = @import("zva");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;

pub fn create(
    gc: *const GraphicsContext,
    vma: *zva.Allocator,
    format: vk.Format,
    usage_flags: vk.ImageUsageFlags,
    aspect_flags: vk.ImageAspectFlags,
    extent: vk.Extent3D,
) !Image {
    // create the image
    const image = try gc.vkd.createImage(gc.dev, &.{
        .flags = .{},
        .image_type = .@"2d",

        .format = format,
        .extent = extent,

        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = usage_flags,
        .sharing_mode = .exclusive,

        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .initial_layout = .@"undefined",
    }, null);
    errdefer gc.vkd.destroyImage(gc.dev, image, null);

    // allocate the image
    const mem_req = gc.vkd.getImageMemoryRequirements(gc.dev, image);
    var allocation = try vma.alloc(
        mem_req.size,
        mem_req.alignment,
        mem_req.memory_type_bits,
        .GpuOnly,
        .ImageOptimal,
        .{ .device_local_bit = true },
    );
    errdefer vma.free(allocation);

    try gc.vkd.bindImageMemory(gc.dev, image, allocation.memory, allocation.offset);

    // create the image-view
    const view = try gc.vkd.createImageView(gc.dev, &vk.ImageViewCreateInfo{
        .flags = .{},
        .image = image,
        .view_type = .@"2d",
        .format = format,
        .components = .{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = .identity,
        },
        .subresource_range = .{
            .aspect_mask = aspect_flags,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    }, null);
    errdefer gc.vkd.destroyImageView(gc.dev, view, null);

    return Image{ .image = image, .view = view, .allocation = allocation };
}

pub fn free(self: *Image, gc: *const GraphicsContext, vma: *zva.Allocator) void {
    gc.vkd.destroyImageView(gc.dev, self.view, null);
    gc.vkd.destroyImage(gc.dev, self.image, null);
    vma.free(self.allocation);
}
