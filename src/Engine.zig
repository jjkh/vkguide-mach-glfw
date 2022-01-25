window_extent: vk.Extent2D,
window: glfw.Window,

instance: vk.Instance,

// debug_messenger: vk.DebugUtilsMessengerEXT, // Vulkan debug output handle
gpu: PhysicalDevice, // GPU chosen as the default device
device: vk.Device, // Vulkan device for commands
surface: vk.SurfaceKHR,
graphics_queue: Queue,
present_queue: Queue,

vki: InstanceDispatch,
vkd: DeviceDispatch,

const Self = @This();

const std = @import("std");
const vk = @import("vulkan");
const glfw = @import("glfw");

const Allocator = std.mem.Allocator;

pub const AppInfo = struct {
    name: [:0]const u8,
    version: u32 = vk.makeApiVersion(0, 0, 0, 0),
};

pub const WindowOptions = struct {
    title: [:0]const u8,
    extent: vk.Extent2D = .{ .width = 1700, .height = 900 },
};

pub fn init(allocator: Allocator, app_info: AppInfo, opts: WindowOptions) !Self {
    var self: Self = undefined;
    self.window_extent = opts.extent;

    try glfw.init(.{});
    errdefer glfw.terminate();

    // create the window
    self.window = try glfw.Window.create(
        self.window_extent.width,
        self.window_extent.height,
        opts.title,
        null,
        null,
        .{ .client_api = .no_api },
    );
    errdefer self.window.destroy();

    try self.initVulkan(allocator, app_info);

    return self;
}

pub fn deinit(self: *Self) void {
    self.vki.destroySurfaceKHR(self.instance, self.surface, null);
    self.vki.destroyInstance(self.instance, null);

    self.window.destroy();
    glfw.terminate();
}

const BaseDispatch = vk.BaseWrapper(.{
    .createInstance = true,
});

const InstanceDispatch = vk.InstanceWrapper(.{
    .destroyInstance = true,
    .destroySurfaceKHR = true,
    .enumeratePhysicalDevices = true,
    .getPhysicalDeviceProperties = true,
    .enumerateDeviceExtensionProperties = true,
    .getPhysicalDeviceSurfaceFormatsKHR = true,
    .getPhysicalDeviceSurfacePresentModesKHR = true,
    .createDevice = true,
    .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
    .getPhysicalDeviceQueueFamilyProperties = true,
    .getPhysicalDeviceSurfaceSupportKHR = true,
    .getPhysicalDeviceMemoryProperties = true,
    .getDeviceProcAddr = true,
});

fn initVulkan(self: *Self, allocator: Allocator, app_info: AppInfo) !void {
    const vk_proc = @ptrCast(
        fn (instance: vk.Instance, procname: [*:0]const u8) callconv(.C) vk.PfnVoidFunction,
        glfw.getInstanceProcAddress,
    );
    const vkb = try BaseDispatch.load(vk_proc);

    const vk_app_info = vk.ApplicationInfo{
        .p_application_name = app_info.name,
        .application_version = app_info.version,
        .p_engine_name = "vkguide.dev engine",
        .engine_version = vk.makeApiVersion(0, 0, 0, 0),
        .api_version = vk.API_VERSION_1_2,
    };

    const glfw_exts = try glfw.getRequiredInstanceExtensions();

    // TODO: create the debug messenger and validation layer
    // // VkDebugUtilsMessengerCreateInfoEXT messengerCreateInfo = {};
    // // if (info.use_debug_messenger) {
    // //     messengerCreateInfo.sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
    // //     messengerCreateInfo.pNext = nullptr;
    // //     messengerCreateInfo.messageSeverity = info.debug_message_severity;
    // //     messengerCreateInfo.messageType = info.debug_message_type;
    // //     messengerCreateInfo.pfnUserCallback = info.debug_callback;
    // //     messengerCreateInfo.pUserData = info.debug_user_data_pointer;
    // //     pNext_chain.push_back(reinterpret_cast<VkBaseOutStructure*>(&messengerCreateInfo));
    // // }
    //
    // // TODO: validate this is present in vkEnumerateInstanceLayerProperties
    // const layers = [_][*:0]const u8{
    //     "VK_LAYER_KHRONOS_validation",
    // };

    self.instance = try vkb.createInstance(&.{
        .flags = .{},
        .p_application_info = &vk_app_info,
        // .enabled_layer_count = layers.len,
        // .pp_enabled_layer_names = &layers,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = undefined,
        .enabled_extension_count = @intCast(u32, glfw_exts.len),
        .pp_enabled_extension_names = @ptrCast([*]const [*:0]const u8, &glfw_exts[0]),
    }, null);

    self.vki = try InstanceDispatch.load(self.instance, vk_proc);
    errdefer self.vki.destroyInstance(self.instance, null);

    try self.createSurface();
    errdefer self.vki.destroySurfaceKHR(self.instance, self.surface, null);

    try self.selectPhysicalDevice(allocator);
    try self.createDevice();
    errdefer self.vkd.destroyDevice(self.device, null);

    self.graphics_queue = Queue.init(self.vkd, self.device, self.gpu.queues.?.graphics_family);
    self.present_queue = Queue.init(self.vkd, self.device, self.gpu.queues.?.present_family);
}

fn createSurface(self: *Self) !void {
    const result = try glfw.createWindowSurface(
        self.instance,
        self.window,
        null,
        &self.surface,
    );
    if (result != @enumToInt(vk.Result.success))
        return error.SurfaceInitFailed;
}

fn cStrToSlice(buf: []const u8) [:0]const u8 {
    const len = std.mem.indexOfScalar(u8, buf, 0).?;
    return buf[0..len :0];
}

fn selectPhysicalDevice(self: *Self, allocator: Allocator) !void {
    var device_count: u32 = undefined;
    _ = try self.vki.enumeratePhysicalDevices(self.instance, &device_count, null);

    const physical_devices = try allocator.alloc(vk.PhysicalDevice, device_count);
    defer allocator.free(physical_devices);

    _ = try self.vki.enumeratePhysicalDevices(
        self.instance,
        &device_count,
        physical_devices.ptr,
    );

    for (physical_devices) |handle| {
        var physical_device = PhysicalDevice{
            .handle = handle,
            .props = self.vki.getPhysicalDeviceProperties(handle),
        };

        if (try self.checkPhysicalDeviceSuitable(allocator, &physical_device)) {
            std.log.info(
                "found physical device: {s}",
                .{cStrToSlice(&physical_device.props.device_name)},
            );

            self.gpu = physical_device;
            return;
        }
    }

    return error.NoSuitablePhysicalDevice;
}

fn checkPhysicalDeviceSuitable(
    self: *Self,
    allocator: Allocator,
    physical_device: *PhysicalDevice,
) !bool {
    if (!try self.checkExtensionSupport(allocator, physical_device.*))
        return false;

    if (!try self.checkSurfaceSupport(physical_device.*))
        return false;

    // TODO: rename - this doesn't (permanently) allocate!
    if (!try self.allocateQueues(allocator, physical_device))
        return false;

    // TODO: should validate supports vulkan version

    return true;
}

const required_device_extensions = [_][]const u8{vk.extension_info.khr_swapchain.name};

fn checkExtensionSupport(
    self: *Self,
    allocator: Allocator,
    physical_device: PhysicalDevice,
) !bool {
    var prop_count: u32 = undefined;
    _ = try self.vki.enumerateDeviceExtensionProperties(
        physical_device.handle,
        null,
        &prop_count,
        null,
    );

    const props_vec = try allocator.alloc(vk.ExtensionProperties, prop_count);
    defer allocator.free(props_vec);

    _ = try self.vki.enumerateDeviceExtensionProperties(
        physical_device.handle,
        null,
        &prop_count,
        props_vec.ptr,
    );

    for (required_device_extensions) |extension_name| {
        for (props_vec) |props| {
            if (std.mem.eql(u8, extension_name, cStrToSlice(&props.extension_name)))
                break;
        } else {
            return false;
        }
    }

    return true;
}

fn checkSurfaceSupport(self: *Self, physical_device: PhysicalDevice) !bool {
    var format_count: u32 = undefined;
    _ = try self.vki.getPhysicalDeviceSurfaceFormatsKHR(
        physical_device.handle,
        self.surface,
        &format_count,
        null,
    );
    if (format_count <= 0) return false;

    var present_mode_count: u32 = undefined;
    _ = try self.vki.getPhysicalDeviceSurfacePresentModesKHR(
        physical_device.handle,
        self.surface,
        &present_mode_count,
        null,
    );
    if (present_mode_count <= 0) return false;

    return true;
}

const PhysicalDevice = struct {
    handle: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: ?QueueAllocation = null,
};

const QueueAllocation = struct {
    graphics_family: u32,
    present_family: u32,

    pub fn count(self: QueueAllocation) u32 {
        return if (self.graphics_family == self.present_family) 1 else 2;
    }
};

fn allocateQueues(self: *Self, allocator: Allocator, physical_device: *PhysicalDevice) !bool {
    var family_count: u32 = undefined;
    self.vki.getPhysicalDeviceQueueFamilyProperties(physical_device.handle, &family_count, null);

    const families = try allocator.alloc(vk.QueueFamilyProperties, family_count);
    defer allocator.free(families);
    self.vki.getPhysicalDeviceQueueFamilyProperties(physical_device.handle, &family_count, families.ptr);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;

    for (families) |props, i| {
        const family = @intCast(u32, i);
        const surface_support = try self.vki.getPhysicalDeviceSurfaceSupportKHR(
            physical_device.handle,
            family,
            self.surface,
        );

        if (graphics_family == null and props.queue_flags.graphics_bit)
            graphics_family = family;

        if (present_family == null and surface_support == vk.TRUE)
            present_family = family;
    }

    if (graphics_family != null and present_family != null) {
        physical_device.queues = QueueAllocation{
            .graphics_family = graphics_family.?,
            .present_family = present_family.?,
        };
        return true;
    }

    return false;
}

const DeviceDispatch = vk.DeviceWrapper(.{
    .destroyDevice = true,
    .getDeviceQueue = true,
    .createSemaphore = true,
    .createFence = true,
    .createImageView = true,
    .destroyImageView = true,
    .destroySemaphore = true,
    .destroyFence = true,
    .getSwapchainImagesKHR = true,
    .createSwapchainKHR = true,
    .destroySwapchainKHR = true,
    .acquireNextImageKHR = true,
    .deviceWaitIdle = true,
    .waitForFences = true,
    .resetFences = true,
    .queueSubmit = true,
    .queuePresentKHR = true,
    .createCommandPool = true,
    .destroyCommandPool = true,
    .allocateCommandBuffers = true,
    .freeCommandBuffers = true,
    .queueWaitIdle = true,
    .createShaderModule = true,
    .destroyShaderModule = true,
    .createPipelineLayout = true,
    .destroyPipelineLayout = true,
    .createRenderPass = true,
    .destroyRenderPass = true,
    .createGraphicsPipelines = true,
    .destroyPipeline = true,
    .createFramebuffer = true,
    .destroyFramebuffer = true,
    .beginCommandBuffer = true,
    .endCommandBuffer = true,
    .allocateMemory = true,
    .freeMemory = true,
    .createBuffer = true,
    .destroyBuffer = true,
    .getBufferMemoryRequirements = true,
    .mapMemory = true,
    .unmapMemory = true,
    .bindBufferMemory = true,
    .cmdBeginRenderPass = true,
    .cmdEndRenderPass = true,
    .cmdBindPipeline = true,
    .cmdDraw = true,
    .cmdSetViewport = true,
    .cmdSetScissor = true,
    .cmdBindVertexBuffers = true,
    .cmdCopyBuffer = true,
});

fn createDevice(self: *Self) !void {
    const priority = [_]f32{1};
    const qci = [_]vk.DeviceQueueCreateInfo{
        .{
            .flags = .{},
            .queue_family_index = self.gpu.queues.?.graphics_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
        .{
            .flags = .{},
            .queue_family_index = self.gpu.queues.?.present_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
    };

    self.device = try self.vki.createDevice(self.gpu.handle, &.{
        .flags = .{},
        .queue_create_info_count = self.gpu.queues.?.count(),
        .p_queue_create_infos = &qci,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = undefined,
        .enabled_extension_count = required_device_extensions.len,
        .pp_enabled_extension_names = @ptrCast([*]const [*:0]const u8, &required_device_extensions),
        .p_enabled_features = null,
    }, null);

    self.vkd = try DeviceDispatch.load(self.device, self.vki.dispatch.vkGetDeviceProcAddr);
}

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,

    fn init(vkd: DeviceDispatch, dev: vk.Device, family: u32) Queue {
        return .{
            .handle = vkd.getDeviceQueue(dev, family, 0),
            .family = family,
        };
    }
};
