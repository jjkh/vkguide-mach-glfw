vertices: ArrayList(Vertex),
allocator: Allocator,

const Mesh = @This();

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.mesh);

const vk = @import("vulkan");
const zlm = @import("zlm");
const vec3 = zlm.vec3;
const Vec3 = zlm.Vec3;

pub const VertexInputDescription = struct {
    bindings: []const vk.VertexInputBindingDescription,
    attributes: []const vk.VertexInputAttributeDescription,

    flags: vk.PipelineVertexInputStateCreateFlags = .{},
};

pub const Vertex = extern struct {
    position: Vec3 = vec3(0, 0, 0),
    normal: Vec3 = vec3(0, 0, 0),
    color: Vec3 = vec3(0, 0, 0),

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
    return .{ .vertices = ArrayList(Vertex).init(allocator), .allocator = allocator };
}

pub fn deinit(self: *Mesh) void {
    self.vertices.deinit();
}

pub fn loadTriangle(self: *Mesh) !void {
    try self.vertices.appendSlice(&[_]Vertex{
        .{ .position = vec3(1, 1, 0), .color = vec3(1, 0, 0) },
        .{ .position = vec3(-1, 1, 0), .color = vec3(0, 1, 0) },
        .{ .position = vec3(0, -1, 0), .color = vec3(0, 0, 1) },
    });
}

const FileAlloc = struct {
    allocator: Allocator,
    file: ?[]u8 = null,
    mtl: ?[]u8 = null,

    const MAX_FILE_SIZE = 100 * 1024 * 1024;

    pub fn read(self: *FileAlloc, filename: []const u8, file: enum { file, mtl }) ![]u8 {
        const contents = try std.fs.cwd().readFileAlloc(self.allocator, filename, MAX_FILE_SIZE);

        if (file == .file)
            self.file = contents
        else
            self.mtl = contents;

        return contents;
    }

    pub fn free(self: *FileAlloc) void {
        if (self.mtl) |mtl| self.allocator.free(mtl);
        if (self.file) |file| self.allocator.free(file);
    }
};

pub fn loadObj(self: *Mesh, filename: []const u8) !void {
    const c = @cImport(@cInclude("tinyobj_loader_c.h"));

    log.debug("loading {s}", .{filename});

    var attrib: c.tinyobj_attrib_t = undefined;
    var shapes: [*c]c.tinyobj_shape_t = undefined;
    var shapes_count: usize = 0;
    var materials: [*c]c.tinyobj_material_t = undefined;
    var materials_count: usize = 0;

    var file_alloc = FileAlloc{ .allocator = self.allocator };
    defer file_alloc.free();

    const ret = c.tinyobj_parse_obj(
        &attrib,
        &shapes,
        &shapes_count,
        &materials,
        &materials_count,
        filename.ptr,
        read_file,
        &file_alloc,
        c.TINYOBJ_FLAG_TRIANGULATE,
        // 0,
    );
    if (ret != c.TINYOBJ_SUCCESS) return error.TinyObjParseError;
    log.debug("{} shapes ({*})", .{ shapes_count, shapes });
    log.debug("{} materials ({*})", .{ materials_count, materials });
    log.debug("{} faces", .{attrib.num_faces});
    log.debug("{} vertices", .{attrib.num_vertices});
    log.debug("{} normals", .{attrib.num_normals});
    log.debug("{} face number vertices", .{attrib.num_face_num_verts});

    // loop over shapes
    for (shapes[0..shapes_count]) |shape, i| {
        if (shape.name != null) {
            const name = std.mem.trim(u8, std.mem.sliceTo(shape.name, 0), "\r\n");
            log.debug("reading shape '{s}', len {}\n", .{ name, shape.length });
        } else log.debug("reading shape {}, len {}\n", .{ i, shape.length });

        // hardcode 3 vertices per face
        const VERT_COUNT = 3;

        // loop over faces (polygons)
        for (attrib.faces[shape.face_offset .. shape.face_offset + shape.length * VERT_COUNT]) |face| {
            const has_normal = face.vn_idx >= 0;
            const normal = if (has_normal) vec3(
                attrib.normals[3 * @intCast(usize, face.vn_idx) + 0],
                attrib.normals[3 * @intCast(usize, face.vn_idx) + 1],
                attrib.normals[3 * @intCast(usize, face.vn_idx) + 2],
            ) else vec3(0, 0, 0);

            try self.vertices.append(.{
                .position = vec3(
                    attrib.vertices[3 * @intCast(usize, face.v_idx) + 0],
                    attrib.vertices[3 * @intCast(usize, face.v_idx) + 1],
                    attrib.vertices[3 * @intCast(usize, face.v_idx) + 2],
                ),
                .normal = normal,
                .color = if (has_normal) normal else vec3(0, 1, 0),
            });
        }
    }
}

export fn read_file(
    ctx: ?*anyopaque,
    filename: ?[*:0]const u8,
    is_mtl: c_int,
    obj_filename: ?[*:0]const u8,
    buf: ?*?[*]u8,
    buf_len: ?*usize,
) void {
    const file_alloc = @ptrCast(*FileAlloc, @alignCast(@alignOf(FileAlloc), ctx.?));

    const file = blk: {
        if (is_mtl != 0 and obj_filename != null) {
            const obj_fn = std.mem.sliceTo(obj_filename.?, 0);

            const dir_name = std.fs.path.dirname(obj_fn);
            const base_name = std.fs.path.basename(obj_fn);
            const base_name_no_ext = base_name[0..std.mem.lastIndexOf(u8, base_name, ".").?];

            var fn_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const mtl_fn = std.fmt.bufPrint(
                &fn_buf,
                "{s}/{s}.mtl",
                .{ dir_name, base_name_no_ext },
            ) catch unreachable;

            break :blk file_alloc.read(mtl_fn, .mtl);
        } else {
            break :blk file_alloc.read(std.mem.sliceTo(filename.?, 0), .file);
        }
    } catch |err|
        std.debug.panic(
        "failed to read file {s} (mtl={}) with error {}",
        .{ filename.?, is_mtl != 0, err },
    );

    buf.?.* = file.ptr;
    buf_len.?.* = file.len;
}
