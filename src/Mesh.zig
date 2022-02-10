vertices: ArrayList(Vertex),

const Mesh = @This();

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const zlm = @import("zlm");
const Vec3 = zlm.Vec3;

pub const VertexInputDescription = struct {
    bindings: []const vk.VertexInputBindingDescription,
    attributes: []const vk.VertexInputAttributeDescription,

    flags: vk.PipelineVertexInputStateCreateFlags = .{},
};

pub const Vertex = extern struct {
    position: Vec3 = Vec3.new(0, 0, 0),
    normal: Vec3 = Vec3.new(0, 0, 0),
    color: Vec3 = Vec3.new(0, 0, 0),

    const binding_desc = [_]vk.VertexInputBindingDescription{.{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    }};

    const attr_descs = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "position"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "normal"),
        },
        .{
            .binding = 0,
            .location = 2,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "color"),
        },
    };

    pub fn desc() VertexInputDescription {
        return .{
            .bindings = &binding_desc,
            .attributes = &attr_descs,
        };
    }
};

pub fn init(allocator: Allocator) Mesh {
    return .{ .vertices = ArrayList(Vertex).init(allocator) };
}

pub fn deinit(self: *Mesh) void {
    self.vertices.deinit();
}

pub fn loadTriangle(self: *Mesh) !void {
    try self.vertices.appendSlice(&[_]Vertex{
        .{ .position = Vec3.new(0.8, 0.8, 0), .color = Vec3.new(0, 1, 0) },
        .{ .position = Vec3.new(-0.8, 0.8, 0), .color = Vec3.new(0, 1, 0) },
        .{ .position = Vec3.new(0, -0.8, 0), .color = Vec3.new(0, 1, 0) },
    });
}
