const std = @import("std");

const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;

pub fn createRenderPass(gc: *const GraphicsContext, format: vk.Format, depth_format: vk.Format) !vk.RenderPass {
    // the renderpass will use this color attachment
    const color_attachment = vk.AttachmentDescription{
        .flags = .{},
        .format = format,
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

    const depth_attachment = vk.AttachmentDescription{
        .flags = .{},
        .format = depth_format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .clear,
        .stencil_store_op = .dont_care,
        .initial_layout = .@"undefined",
        // after the renderpass ends, the image has to be on a layout ready for display
        .final_layout = .depth_stencil_attachment_optimal,
    };

    const depth_attachment_ref = vk.AttachmentReference{
        .attachment = 1,
        .layout = .depth_stencil_attachment_optimal,
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
        .p_depth_stencil_attachment = &depth_attachment_ref,
        .preserve_attachment_count = 0,
        .p_preserve_attachments = undefined,
    };

    const dependency = vk.SubpassDependency{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .color_attachment_output_bit = true },
        .dst_stage_mask = .{ .color_attachment_output_bit = true },
        .src_access_mask = .{},
        .dst_access_mask = .{ .color_attachment_write_bit = true },
        .dependency_flags = .{},
    };

    const depth_dependency = vk.SubpassDependency{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
        .dst_stage_mask = .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
        .src_access_mask = .{},
        .dst_access_mask = .{},
        .dependency_flags = .{},
    };

    return try gc.vkd.createRenderPass(gc.dev, &.{
        .flags = .{},
        .attachment_count = 2,
        .p_attachments = &[_]vk.AttachmentDescription{ color_attachment, depth_attachment },
        .subpass_count = 1,
        .p_subpasses = @ptrCast([*]const vk.SubpassDescription, &subpass),
        .dependency_count = 2,
        .p_dependencies = &[_]vk.SubpassDependency{ dependency, depth_dependency },
    }, null);
}
