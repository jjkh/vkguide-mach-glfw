vertices: ArrayList(Vertex),

const Mesh = @This();

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const zlm = @import("zlm");
const Vec3 = zlm.Vec3;

const Vertex = struct {
    position: Vec3,
    normal: Vec3,
    color: Vec3,
};

pub fn init(allocator: Allocator) Mesh {
    return .{ .vertices = ArrayList(Vertex).init(allocator) };
}

pub fn deinit(self: *Mesh) void {
    self.vertices.deinit();
}
