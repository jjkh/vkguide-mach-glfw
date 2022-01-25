window_extent: vk.Extent2D,
window: glfw.Window,

instance: vk.Instance,

// debug_messenger: vk.DebugUtilsMessengerEXT, // Vulkan debug output handle
chosen_gpu: vk.PhysicalDevice, // GPU chosen as the default device
device: vk.Device, // Vulkan device for commands
surface: vk.SurfaceKHR,

vki: InstanceDispatch,

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
    // .createDevice = true,
    // .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
    // .getPhysicalDeviceQueueFamilyProperties = true,
    // .getPhysicalDeviceSurfaceSupportKHR = true,
    // .getPhysicalDeviceMemoryProperties = true,
    // .getDeviceProcAddr = true,
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
    // try self.createDevice();
    // errdefer self.vkd.destroyDevice(self.device, null);
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

    for (physical_devices) |physical_device| {
        if (try self.checkPhysicalDeviceSuitable(allocator, physical_device)) {
            self.chosen_gpu = physical_device;
            return;
        }
    }

    return error.NoSuitablePhysicalDevice;
}

fn checkPhysicalDeviceSuitable(
    self: *Self,
    allocator: Allocator,
    physical_device: vk.PhysicalDevice,
) !bool {
    const props = self.vki.getPhysicalDeviceProperties(physical_device);

    const len = std.mem.indexOfScalar(u8, &props.device_name, 0).?;
    std.log.info("found physical device: {s}", .{props.device_name[0..len]});

    if (!try self.checkExtensionSupport(allocator, physical_device))
        return false;

    if (!try self.checkSurfaceSupport(physical_device))
        return false;

    // TODO: are we validating the device supports the vulkan version?

    // TODO: triangle sample allocates queues - is this necessary?
    return true;
}

const required_device_extensions = [_][]const u8{vk.extension_info.khr_swapchain.name};

fn checkExtensionSupport(
    self: *Self,
    allocator: Allocator,
    physical_device: vk.PhysicalDevice,
) !bool {
    var prop_count: u32 = undefined;
    _ = try self.vki.enumerateDeviceExtensionProperties(
        physical_device,
        null,
        &prop_count,
        null,
    );

    const props_vec = try allocator.alloc(vk.ExtensionProperties, prop_count);
    defer allocator.free(props_vec);

    _ = try self.vki.enumerateDeviceExtensionProperties(
        physical_device,
        null,
        &prop_count,
        props_vec.ptr,
    );

    for (required_device_extensions) |extension_name| {
        for (props_vec) |props| {
            // TODO: can this be done with sentinel slice instead?
            // e.g. std.mem.len(@ptrCast([*:0]const u8, &props.extension_name))
            const len = std.mem.indexOfScalar(u8, &props.extension_name, 0).?;
            const prop_ext_name = props.extension_name[0..len];
            // TODO: actually, can this whole thing be replaced with std.mem.startsWith?
            if (std.mem.eql(u8, extension_name, prop_ext_name))
                break;
        } else {
            return false;
        }
    }

    return true;
}

fn checkSurfaceSupport(self: *Self, physical_device: vk.PhysicalDevice) !bool {
    var format_count: u32 = undefined;
    _ = try self.vki.getPhysicalDeviceSurfaceFormatsKHR(
        physical_device,
        self.surface,
        &format_count,
        null,
    );
    if (format_count <= 0) return false;

    var present_mode_count: u32 = undefined;
    _ = try self.vki.getPhysicalDeviceSurfacePresentModesKHR(
        physical_device,
        self.surface,
        &present_mode_count,
        null,
    );
    if (present_mode_count <= 0) return false;

    return true;
}
