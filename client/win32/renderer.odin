package main

import "core:fmt"

import "vendor:glfw"
import vk "vendor:vulkan"

MAX_FRAMES_IN_FLIGHT :: 2

Renderer :: struct {
	window:               glfw.WindowHandle,
	instance:             vk.Instance,
	surface:              vk.SurfaceKHR,
	physical_device:      vk.PhysicalDevice,
	device:               vk.Device,
	graphics_family:      u32,
	present_family:       u32,
	graphics_queue:       vk.Queue,
	present_queue:        vk.Queue,
	swapchain:            vk.SwapchainKHR,
	swapchain_format:     vk.Format,
	swapchain_extent:     vk.Extent2D,
	swapchain_images:     []vk.Image,
	swapchain_views:      []vk.ImageView,
	render_pass:          vk.RenderPass,
	framebuffers:         []vk.Framebuffer,
	command_pool:         vk.CommandPool,
	command_buffers:      [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
	image_avail_sems:     [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
	render_done_sems:     [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
	in_flight_fences:     [MAX_FRAMES_IN_FLIGHT]vk.Fence,
	current_frame:        u32,
	current_image_index:  u32,
	clear_color:          [4]f32,
	// Set by the fullscreen toggle (or any external "the surface just changed"
	// event). Honoured at the top of `renderer_begin_frame` so the rebuild
	// happens at a known synchronisation point — never while the caller might
	// still be mid-frame.
	swapchain_dirty:      bool,
}

vk_check :: proc(r: vk.Result, where_: string, loc := #caller_location) -> bool {
	if r != .SUCCESS {
		fmt.eprintfln("vulkan error %v at %s (%v)", r, where_, loc)
		return false
	}
	return true
}

renderer_init :: proc(r: ^Renderer, window: glfw.WindowHandle) -> bool {
	r.window = window
	r.clear_color = {0.01, 0.01, 0.02, 1.0}

	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))

	if !create_instance(r) do return false
	vk.load_proc_addresses_instance(r.instance)

	if !vk_check(glfw.CreateWindowSurface(r.instance, window, nil, &r.surface), "CreateWindowSurface") do return false
	if !pick_physical_device(r) do return false
	if !create_logical_device(r) do return false
	vk.load_proc_addresses_device(r.device)

	if !create_swapchain(r) do return false
	if !create_image_views(r) do return false
	if !create_render_pass(r) do return false
	if !create_framebuffers(r) do return false
	if !create_command_pool(r) do return false
	if !create_command_buffers(r) do return false
	if !create_sync_objects(r) do return false
	return true
}

renderer_recreate_swapchain :: proc(r: ^Renderer) -> bool {
	if r.device == nil do return false
	// Wait for the current frame's resources to settle. The drained framebuffer
	// dimensions are 0×0 while the window is minimised — bail and retry later.
	for {
		w, h := glfw.GetFramebufferSize(r.window)
		if w > 0 && h > 0 do break
		glfw.WaitEvents()
	}
	vk.DeviceWaitIdle(r.device)

	// Tear down everything that views the old swapchain images, but keep the
	// old swapchain handle alive so the driver can hand off presentation state
	// to its replacement (the `oldSwapchain` hint in CreateSwapchainKHR). On
	// Windows this is the difference between a clean fullscreen toggle and the
	// first few frames being silently dropped/black on some drivers.
	for fb in r.framebuffers do vk.DestroyFramebuffer(r.device, fb, nil)
	delete(r.framebuffers)
	r.framebuffers = nil
	for v in r.swapchain_views do vk.DestroyImageView(r.device, v, nil)
	delete(r.swapchain_views)
	r.swapchain_views = nil
	delete(r.swapchain_images)
	r.swapchain_images = nil

	old := r.swapchain
	r.swapchain = 0
	if !create_swapchain(r, old) do return false
	if old != 0 do vk.DestroySwapchainKHR(r.device, old, nil)
	if !create_image_views(r) do return false
	if !create_framebuffers(r) do return false
	r.swapchain_dirty = false
	return true
}

renderer_shutdown :: proc(r: ^Renderer) {
	if r.device != nil {
		vk.DeviceWaitIdle(r.device)
		for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
			if r.image_avail_sems[i] != 0 do vk.DestroySemaphore(r.device, r.image_avail_sems[i], nil)
			if r.render_done_sems[i] != 0 do vk.DestroySemaphore(r.device, r.render_done_sems[i], nil)
			if r.in_flight_fences[i] != 0 do vk.DestroyFence(r.device, r.in_flight_fences[i], nil)
		}
		if r.command_pool != 0 do vk.DestroyCommandPool(r.device, r.command_pool, nil)
		for fb in r.framebuffers do vk.DestroyFramebuffer(r.device, fb, nil)
		delete(r.framebuffers)
		if r.render_pass != 0 do vk.DestroyRenderPass(r.device, r.render_pass, nil)
		for v in r.swapchain_views do vk.DestroyImageView(r.device, v, nil)
		delete(r.swapchain_views)
		delete(r.swapchain_images)
		if r.swapchain != 0 do vk.DestroySwapchainKHR(r.device, r.swapchain, nil)
		vk.DestroyDevice(r.device, nil)
	}
	if r.surface != 0 do vk.DestroySurfaceKHR(r.instance, r.surface, nil)
	if r.instance != nil do vk.DestroyInstance(r.instance, nil)
}

renderer_begin_frame :: proc(r: ^Renderer) -> (cb: vk.CommandBuffer, ok: bool) {
	// External signal (fullscreen toggle) that the surface configuration
	// changed and the swapchain must be rebuilt before we touch any of its
	// images. Doing it here rather than mid-toggle keeps the rebuild on the
	// same thread/timing as every other Vulkan operation we issue.
	if r.swapchain_dirty {
		renderer_recreate_swapchain(r)
		return cb, false
	}

	frame := r.current_frame
	vk.WaitForFences(r.device, 1, &r.in_flight_fences[frame], true, max(u64))

	acq := vk.AcquireNextImageKHR(r.device, r.swapchain, max(u64), r.image_avail_sems[frame], 0, &r.current_image_index)
	if acq == .ERROR_OUT_OF_DATE_KHR {
		// Surface no longer matches the swapchain (window was resized, moved
		// across monitors, or toggled fullscreen). Rebuild and skip this frame
		// — the semaphore wasn't signalled, so we must not submit.
		renderer_recreate_swapchain(r)
		return cb, false
	}
	if acq != .SUCCESS && acq != .SUBOPTIMAL_KHR {
		fmt.eprintfln("AcquireNextImageKHR: %v", acq)
		return cb, false
	}

	vk.ResetFences(r.device, 1, &r.in_flight_fences[frame])
	cb = r.command_buffers[frame]
	vk.ResetCommandBuffer(cb, {})

	begin := vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO}
	vk.BeginCommandBuffer(cb, &begin)

	clear := vk.ClearValue{color = {float32 = r.clear_color}}
	rp_begin := vk.RenderPassBeginInfo{
		sType           = .RENDER_PASS_BEGIN_INFO,
		renderPass      = r.render_pass,
		framebuffer     = r.framebuffers[r.current_image_index],
		renderArea      = {extent = r.swapchain_extent},
		clearValueCount = 1,
		pClearValues    = &clear,
	}
	vk.CmdBeginRenderPass(cb, &rp_begin, .INLINE)

	viewport := vk.Viewport{
		x        = 0,
		y        = 0,
		width    = f32(r.swapchain_extent.width),
		height   = f32(r.swapchain_extent.height),
		minDepth = 0,
		maxDepth = 1,
	}
	vk.CmdSetViewport(cb, 0, 1, &viewport)
	scissor := vk.Rect2D{extent = r.swapchain_extent}
	vk.CmdSetScissor(cb, 0, 1, &scissor)

	ok = true
	return
}

renderer_end_frame :: proc(r: ^Renderer) {
	frame := r.current_frame
	cb := r.command_buffers[frame]
	vk.CmdEndRenderPass(cb)
	vk.EndCommandBuffer(cb)

	wait_stage := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
	submit := vk.SubmitInfo{
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &r.image_avail_sems[frame],
		pWaitDstStageMask    = &wait_stage,
		commandBufferCount   = 1,
		pCommandBuffers      = &r.command_buffers[frame],
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &r.render_done_sems[frame],
	}
	vk.QueueSubmit(r.graphics_queue, 1, &submit, r.in_flight_fences[frame])

	image_index := r.current_image_index
	present := vk.PresentInfoKHR{
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &r.render_done_sems[frame],
		swapchainCount     = 1,
		pSwapchains        = &r.swapchain,
		pImageIndices      = &image_index,
	}
	pres := vk.QueuePresentKHR(r.present_queue, &present)
	if pres == .ERROR_OUT_OF_DATE_KHR || pres == .SUBOPTIMAL_KHR {
		// Surface mismatch detected at present time — typical on Windows after
		// a fullscreen toggle. Rebuild before the next acquire.
		renderer_recreate_swapchain(r)
	} else if pres != .SUCCESS {
		fmt.eprintfln("QueuePresentKHR: %v", pres)
	}

	r.current_frame = (frame + 1) % MAX_FRAMES_IN_FLIGHT
}

create_instance :: proc(r: ^Renderer) -> bool {
	app_info := vk.ApplicationInfo{
		sType              = .APPLICATION_INFO,
		pApplicationName   = "Adventum",
		applicationVersion = vk.MAKE_VERSION(1, 0, 0),
		pEngineName        = "Adventum",
		engineVersion      = vk.MAKE_VERSION(1, 0, 0),
		apiVersion         = vk.API_VERSION_1_2,
	}
	exts := glfw.GetRequiredInstanceExtensions()
	info := vk.InstanceCreateInfo{
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &app_info,
		enabledExtensionCount   = u32(len(exts)),
		ppEnabledExtensionNames = raw_data(exts),
	}
	return vk_check(vk.CreateInstance(&info, nil, &r.instance), "CreateInstance")
}

pick_physical_device :: proc(r: ^Renderer) -> bool {
	count: u32
	vk.EnumeratePhysicalDevices(r.instance, &count, nil)
	if count == 0 {
		fmt.eprintln("no vulkan physical devices")
		return false
	}
	devices := make([]vk.PhysicalDevice, count)
	defer delete(devices)
	vk.EnumeratePhysicalDevices(r.instance, &count, raw_data(devices))

	for d in devices {
		gfx, present, ok := find_queue_families(d, r.surface)
		if !ok do continue
		if !device_supports_swapchain(d) do continue
		fmts: u32; vk.GetPhysicalDeviceSurfaceFormatsKHR(d, r.surface, &fmts, nil)
		modes: u32; vk.GetPhysicalDeviceSurfacePresentModesKHR(d, r.surface, &modes, nil)
		if fmts == 0 || modes == 0 do continue
		r.physical_device = d
		r.graphics_family = gfx
		r.present_family = present
		return true
	}
	fmt.eprintln("no suitable physical device found")
	return false
}

find_queue_families :: proc(d: vk.PhysicalDevice, surface: vk.SurfaceKHR) -> (gfx: u32, present: u32, ok: bool) {
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(d, &count, nil)
	props := make([]vk.QueueFamilyProperties, count)
	defer delete(props)
	vk.GetPhysicalDeviceQueueFamilyProperties(d, &count, raw_data(props))

	gfx_found, present_found: bool
	for p, i in props {
		idx := u32(i)
		if !gfx_found && .GRAPHICS in p.queueFlags {
			gfx = idx
			gfx_found = true
		}
		supported: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(d, idx, surface, &supported)
		if !present_found && supported {
			present = idx
			present_found = true
		}
		if gfx_found && present_found do break
	}
	ok = gfx_found && present_found
	return
}

device_supports_swapchain :: proc(d: vk.PhysicalDevice) -> bool {
	count: u32
	vk.EnumerateDeviceExtensionProperties(d, nil, &count, nil)
	exts := make([]vk.ExtensionProperties, count)
	defer delete(exts)
	vk.EnumerateDeviceExtensionProperties(d, nil, &count, raw_data(exts))
	for &e in exts {
		name := cstring(raw_data(e.extensionName[:]))
		if string(name) == vk.KHR_SWAPCHAIN_EXTENSION_NAME do return true
	}
	return false
}

create_logical_device :: proc(r: ^Renderer) -> bool {
	priority := f32(1.0)
	queue_infos: [2]vk.DeviceQueueCreateInfo
	queue_count := u32(1)
	queue_infos[0] = {
		sType = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = r.graphics_family,
		queueCount = 1,
		pQueuePriorities = &priority,
	}
	if r.present_family != r.graphics_family {
		queue_infos[1] = {
			sType = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = r.present_family,
			queueCount = 1,
			pQueuePriorities = &priority,
		}
		queue_count = 2
	}

	dev_exts := []cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}

	info := vk.DeviceCreateInfo{
		sType                   = .DEVICE_CREATE_INFO,
		queueCreateInfoCount    = queue_count,
		pQueueCreateInfos       = raw_data(queue_infos[:]),
		enabledExtensionCount   = u32(len(dev_exts)),
		ppEnabledExtensionNames = raw_data(dev_exts),
	}
	if !vk_check(vk.CreateDevice(r.physical_device, &info, nil, &r.device), "CreateDevice") do return false
	vk.GetDeviceQueue(r.device, r.graphics_family, 0, &r.graphics_queue)
	vk.GetDeviceQueue(r.device, r.present_family, 0, &r.present_queue)
	return true
}

create_swapchain :: proc(r: ^Renderer, old_swapchain: vk.SwapchainKHR = 0) -> bool {
	caps: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(r.physical_device, r.surface, &caps)

	fmt_count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(r.physical_device, r.surface, &fmt_count, nil)
	formats := make([]vk.SurfaceFormatKHR, fmt_count)
	defer delete(formats)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(r.physical_device, r.surface, &fmt_count, raw_data(formats))

	chosen := formats[0]
	for f in formats {
		if f.format == .B8G8R8A8_SRGB && f.colorSpace == .SRGB_NONLINEAR {
			chosen = f
			break
		}
	}

	mode_count: u32
	vk.GetPhysicalDeviceSurfacePresentModesKHR(r.physical_device, r.surface, &mode_count, nil)
	modes := make([]vk.PresentModeKHR, mode_count)
	defer delete(modes)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(r.physical_device, r.surface, &mode_count, raw_data(modes))
	present_mode := vk.PresentModeKHR.FIFO
	for m in modes {
		if m == .MAILBOX {
			present_mode = .MAILBOX
			break
		}
	}
	fmt.printfln("present mode: %v", present_mode)

	extent := caps.currentExtent
	if extent.width == 0xFFFFFFFF {
		w, h := glfw.GetFramebufferSize(r.window)
		extent.width = clamp(u32(w), caps.minImageExtent.width, caps.maxImageExtent.width)
		extent.height = clamp(u32(h), caps.minImageExtent.height, caps.maxImageExtent.height)
	}

	image_count := caps.minImageCount + 1
	if caps.maxImageCount > 0 && image_count > caps.maxImageCount {
		image_count = caps.maxImageCount
	}

	info := vk.SwapchainCreateInfoKHR{
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = r.surface,
		minImageCount    = image_count,
		imageFormat      = chosen.format,
		imageColorSpace  = chosen.colorSpace,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		preTransform     = caps.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = present_mode,
		clipped          = true,
		oldSwapchain     = old_swapchain,
	}

	indices := [2]u32{r.graphics_family, r.present_family}
	if r.graphics_family != r.present_family {
		info.imageSharingMode = .CONCURRENT
		info.queueFamilyIndexCount = 2
		info.pQueueFamilyIndices = raw_data(indices[:])
	} else {
		info.imageSharingMode = .EXCLUSIVE
	}

	if !vk_check(vk.CreateSwapchainKHR(r.device, &info, nil, &r.swapchain), "CreateSwapchainKHR") do return false

	r.swapchain_format = chosen.format
	r.swapchain_extent = extent

	count: u32
	vk.GetSwapchainImagesKHR(r.device, r.swapchain, &count, nil)
	r.swapchain_images = make([]vk.Image, count)
	vk.GetSwapchainImagesKHR(r.device, r.swapchain, &count, raw_data(r.swapchain_images))
	return true
}

create_image_views :: proc(r: ^Renderer) -> bool {
	r.swapchain_views = make([]vk.ImageView, len(r.swapchain_images))
	for img, i in r.swapchain_images {
		info := vk.ImageViewCreateInfo{
			sType    = .IMAGE_VIEW_CREATE_INFO,
			image    = img,
			viewType = .D2,
			format   = r.swapchain_format,
			components = {.IDENTITY, .IDENTITY, .IDENTITY, .IDENTITY},
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		if !vk_check(vk.CreateImageView(r.device, &info, nil, &r.swapchain_views[i]), "CreateImageView") do return false
	}
	return true
}

create_render_pass :: proc(r: ^Renderer) -> bool {
	color := vk.AttachmentDescription{
		format         = r.swapchain_format,
		samples        = {._1},
		loadOp         = .CLEAR,
		storeOp        = .STORE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .UNDEFINED,
		finalLayout    = .PRESENT_SRC_KHR,
	}
	color_ref := vk.AttachmentReference{attachment = 0, layout = .COLOR_ATTACHMENT_OPTIMAL}
	subpass := vk.SubpassDescription{
		pipelineBindPoint    = .GRAPHICS,
		colorAttachmentCount = 1,
		pColorAttachments    = &color_ref,
	}
	dep := vk.SubpassDependency{
		srcSubpass    = vk.SUBPASS_EXTERNAL,
		dstSubpass    = 0,
		srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
	}
	info := vk.RenderPassCreateInfo{
		sType           = .RENDER_PASS_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color,
		subpassCount    = 1,
		pSubpasses      = &subpass,
		dependencyCount = 1,
		pDependencies   = &dep,
	}
	return vk_check(vk.CreateRenderPass(r.device, &info, nil, &r.render_pass), "CreateRenderPass")
}

create_shader_module :: proc(device: vk.Device, code: []u8) -> (vk.ShaderModule, bool) {
	info := vk.ShaderModuleCreateInfo{
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = cast(^u32)raw_data(code),
	}
	mod: vk.ShaderModule
	if !vk_check(vk.CreateShaderModule(device, &info, nil, &mod), "CreateShaderModule") do return 0, false
	return mod, true
}

create_framebuffers :: proc(r: ^Renderer) -> bool {
	r.framebuffers = make([]vk.Framebuffer, len(r.swapchain_views))
	for v, i in r.swapchain_views {
		view := v
		info := vk.FramebufferCreateInfo{
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = r.render_pass,
			attachmentCount = 1,
			pAttachments    = &view,
			width           = r.swapchain_extent.width,
			height          = r.swapchain_extent.height,
			layers          = 1,
		}
		if !vk_check(vk.CreateFramebuffer(r.device, &info, nil, &r.framebuffers[i]), "CreateFramebuffer") do return false
	}
	return true
}

create_command_pool :: proc(r: ^Renderer) -> bool {
	info := vk.CommandPoolCreateInfo{
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = r.graphics_family,
	}
	return vk_check(vk.CreateCommandPool(r.device, &info, nil, &r.command_pool), "CreateCommandPool")
}

create_command_buffers :: proc(r: ^Renderer) -> bool {
	info := vk.CommandBufferAllocateInfo{
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = r.command_pool,
		level              = .PRIMARY,
		commandBufferCount = MAX_FRAMES_IN_FLIGHT,
	}
	return vk_check(vk.AllocateCommandBuffers(r.device, &info, raw_data(r.command_buffers[:])), "AllocateCommandBuffers")
}

find_memory_type :: proc(r: ^Renderer, type_bits: u32, props: vk.MemoryPropertyFlags) -> (u32, bool) {
	mem_props: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(r.physical_device, &mem_props)
	for i in 0 ..< mem_props.memoryTypeCount {
		if (type_bits & (1 << i)) != 0 && (mem_props.memoryTypes[i].propertyFlags & props) == props {
			return i, true
		}
	}
	return 0, false
}

create_buffer :: proc(
	r: ^Renderer,
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	props: vk.MemoryPropertyFlags,
	out_buf: ^vk.Buffer,
	out_mem: ^vk.DeviceMemory,
) -> bool {
	info := vk.BufferCreateInfo{
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}
	if !vk_check(vk.CreateBuffer(r.device, &info, nil, out_buf), "CreateBuffer") do return false
	req: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(r.device, out_buf^, &req)
	mt, ok := find_memory_type(r, req.memoryTypeBits, props)
	if !ok {
		fmt.eprintln("no suitable memory type for buffer")
		return false
	}
	alloc := vk.MemoryAllocateInfo{
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = req.size,
		memoryTypeIndex = mt,
	}
	if !vk_check(vk.AllocateMemory(r.device, &alloc, nil, out_mem), "AllocateMemory") do return false
	vk.BindBufferMemory(r.device, out_buf^, out_mem^, 0)
	return true
}

create_image_2d :: proc(
	r: ^Renderer,
	w, h: u32,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
	out_img: ^vk.Image,
	out_mem: ^vk.DeviceMemory,
) -> bool {
	info := vk.ImageCreateInfo{
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = format,
		extent        = {w, h, 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = usage,
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	if !vk_check(vk.CreateImage(r.device, &info, nil, out_img), "CreateImage") do return false
	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(r.device, out_img^, &req)
	mt, ok := find_memory_type(r, req.memoryTypeBits, {.DEVICE_LOCAL})
	if !ok {
		fmt.eprintln("no device-local memory type for image")
		return false
	}
	alloc := vk.MemoryAllocateInfo{
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = req.size,
		memoryTypeIndex = mt,
	}
	if !vk_check(vk.AllocateMemory(r.device, &alloc, nil, out_mem), "AllocateMemory image") do return false
	vk.BindImageMemory(r.device, out_img^, out_mem^, 0)
	return true
}

upload_image :: proc(r: ^Renderer, image: vk.Image, w, h: u32, pixels: []u8) -> bool {
	size := vk.DeviceSize(len(pixels))
	staging: vk.Buffer
	staging_mem: vk.DeviceMemory
	if !create_buffer(r, size, {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT}, &staging, &staging_mem) do return false
	defer {
		vk.DestroyBuffer(r.device, staging, nil)
		vk.FreeMemory(r.device, staging_mem, nil)
	}

	mapped: rawptr
	vk.MapMemory(r.device, staging_mem, 0, size, {}, &mapped)
	dst := ([^]u8)(mapped)
	for b, i in pixels do dst[i] = b
	vk.UnmapMemory(r.device, staging_mem)

	cb := one_shot_begin(r) or_return

	to_dst := vk.ImageMemoryBarrier{
		sType               = .IMAGE_MEMORY_BARRIER,
		oldLayout           = .UNDEFINED,
		newLayout           = .TRANSFER_DST_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = image,
		subresourceRange    = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		srcAccessMask       = {},
		dstAccessMask       = {.TRANSFER_WRITE},
	}
	vk.CmdPipelineBarrier(cb, {.TOP_OF_PIPE}, {.TRANSFER}, {}, 0, nil, 0, nil, 1, &to_dst)

	region := vk.BufferImageCopy{
		imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		imageExtent      = {w, h, 1},
	}
	vk.CmdCopyBufferToImage(cb, staging, image, .TRANSFER_DST_OPTIMAL, 1, &region)

	to_shader := vk.ImageMemoryBarrier{
		sType               = .IMAGE_MEMORY_BARRIER,
		oldLayout           = .TRANSFER_DST_OPTIMAL,
		newLayout           = .SHADER_READ_ONLY_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = image,
		subresourceRange    = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		srcAccessMask       = {.TRANSFER_WRITE},
		dstAccessMask       = {.SHADER_READ},
	}
	vk.CmdPipelineBarrier(cb, {.TRANSFER}, {.FRAGMENT_SHADER}, {}, 0, nil, 0, nil, 1, &to_shader)

	one_shot_end(r, cb)
	return true
}

one_shot_begin :: proc(r: ^Renderer) -> (vk.CommandBuffer, bool) {
	info := vk.CommandBufferAllocateInfo{
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = r.command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	cb: vk.CommandBuffer
	if !vk_check(vk.AllocateCommandBuffers(r.device, &info, &cb), "one-shot Allocate") do return cb, false
	begin := vk.CommandBufferBeginInfo{
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk.BeginCommandBuffer(cb, &begin)
	return cb, true
}

one_shot_end :: proc(r: ^Renderer, cb: vk.CommandBuffer) {
	cb := cb
	vk.EndCommandBuffer(cb)
	submit := vk.SubmitInfo{
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &cb,
	}
	vk.QueueSubmit(r.graphics_queue, 1, &submit, 0)
	vk.QueueWaitIdle(r.graphics_queue)
	vk.FreeCommandBuffers(r.device, r.command_pool, 1, &cb)
}

create_sync_objects :: proc(r: ^Renderer) -> bool {
	sem_info := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
	fence_info := vk.FenceCreateInfo{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}}
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		if !vk_check(vk.CreateSemaphore(r.device, &sem_info, nil, &r.image_avail_sems[i]), "CreateSemaphore") do return false
		if !vk_check(vk.CreateSemaphore(r.device, &sem_info, nil, &r.render_done_sems[i]), "CreateSemaphore") do return false
		if !vk_check(vk.CreateFence(r.device, &fence_info, nil, &r.in_flight_fences[i]), "CreateFence") do return false
	}
	return true
}
