const std = @import("std");

const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
// this probably shouldn't be dependent on Mesh
const VertexInputDescription = @import("Mesh.zig").VertexInputDescription;

fn loadShaderModule(gc: *const GraphicsContext, shader: []const u8) !vk.ShaderModule {
    return gc.vkd.createShaderModule(gc.dev, &.{
        .flags = .{},
        .code_size = shader.len,
        .p_code = @ptrCast([*]const u32, @alignCast(4, shader)),
    }, null);
}

pub const CreatePipelineOptions = struct {
    vert_input_desc: ?VertexInputDescription = null,
};

pub fn createPipeline(
    gc: *const GraphicsContext,
    vert_shader: []const u8,
    frag_shader: []const u8,
    layout: vk.PipelineLayout,
    render_pass: vk.RenderPass,
    extent: vk.Extent2D,
    opts: CreatePipelineOptions,
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
    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
        .flags = .{},
        .vertex_binding_description_count = if (opts.vert_input_desc) |vid| @intCast(u32, vid.bindings.len) else 0,
        .p_vertex_binding_descriptions = if (opts.vert_input_desc) |vid| vid.bindings.ptr else undefined,
        .vertex_attribute_description_count = if (opts.vert_input_desc) |vid| @intCast(u32, vid.attributes.len) else 0,
        .p_vertex_attribute_descriptions = if (opts.vert_input_desc) |vid| vid.attributes.ptr else undefined,
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

    const depth_stencil_info = vk.PipelineDepthStencilStateCreateInfo{
        .flags = .{},
        .depth_test_enable = vk.TRUE,
        .depth_write_enable = vk.TRUE,
        .depth_compare_op = .less_or_equal,
        .depth_bounds_test_enable = vk.FALSE,
        .stencil_test_enable = vk.FALSE,
        .front = std.mem.zeroInit(vk.StencilOpState, .{}),
        .back = std.mem.zeroInit(vk.StencilOpState, .{}),
        .min_depth_bounds = 0.0,
        .max_depth_bounds = 1.0,
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
        .p_depth_stencil_state = &depth_stencil_info,
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
