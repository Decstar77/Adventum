package main

import "vendor:glfw"
import vk "vendor:vulkan"

BACKGROUND_VERT_SPV := #load("../shaders/background.vert.spv")
BACKGROUND_FRAG_SPV := #load("../shaders/background.frag.spv")

// Hard cap matched in shaders/background.frag. The UBO sizes itself for this
// many points whether we use them or not — at 16 bytes each, 256 lights = 4 KB,
// which is well within the spec-mandated 16 KB minimum maxUniformBufferRange.
MAX_FOG_LIGHTS :: 256

// Default world-space radii. The lit disk reaches out to FOG_LIGHT_RADIUS at
// full strength and softly falls off over an additional FOG_LIGHT_FALLOFF.
// Tuned against the hex grid (HEX_SIZE = 28 ⇒ ~48 world units between centres).
FOG_LIGHT_RADIUS  :: f32(220)
FOG_LIGHT_FALLOFF :: f32(480)

Background_PC :: struct #packed {
	screen:        [2]f32,
	view_scale:    [2]f32,
	view_offset:   [2]f32,
	time:          f32,
	light_count:   i32,
	light_radius:  f32,
	light_falloff: f32,
}

// Per-frame-in-flight UBO + descriptor set for the lights array.
Fog_Frame :: struct {
	buf:    vk.Buffer,
	mem:    vk.DeviceMemory,
	mapped: rawptr,
	set:    vk.DescriptorSet,
}

Background_Renderer :: struct {
	pipeline_layout: vk.PipelineLayout,
	pipeline:        vk.Pipeline,

	desc_layout:     vk.DescriptorSetLayout,
	desc_pool:       vk.DescriptorPool,
	frames:          [MAX_FRAMES_IN_FLIGHT]Fog_Frame,

	// CPU-side per-frame collection of light positions (.xy used; zw reserved).
	lights:          [dynamic][4]f32,
	light_radius:    f32,
	light_falloff:   f32,
}

background_init :: proc(b: ^Background_Renderer, r: ^Renderer) -> bool {
	b.light_radius  = FOG_LIGHT_RADIUS
	b.light_falloff = FOG_LIGHT_FALLOFF

	if !background_create_descriptor_layout(b, r) do return false
	if !background_create_descriptor_pool(b, r) do return false
	if !background_create_frame_resources(b, r) do return false
	if !background_create_pipeline(b, r) do return false
	return true
}

@(private="file")
background_create_descriptor_layout :: proc(b: ^Background_Renderer, r: ^Renderer) -> bool {
	binding := vk.DescriptorSetLayoutBinding{
		binding         = 0,
		descriptorType  = .UNIFORM_BUFFER,
		descriptorCount = 1,
		stageFlags      = {.FRAGMENT},
	}
	info := vk.DescriptorSetLayoutCreateInfo{
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 1,
		pBindings    = &binding,
	}
	return vk_check(vk.CreateDescriptorSetLayout(r.device, &info, nil, &b.desc_layout), "background DescriptorSetLayout")
}

@(private="file")
background_create_descriptor_pool :: proc(b: ^Background_Renderer, r: ^Renderer) -> bool {
	pool_size := vk.DescriptorPoolSize{
		type            = .UNIFORM_BUFFER,
		descriptorCount = u32(MAX_FRAMES_IN_FLIGHT),
	}
	info := vk.DescriptorPoolCreateInfo{
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = u32(MAX_FRAMES_IN_FLIGHT),
		poolSizeCount = 1,
		pPoolSizes    = &pool_size,
	}
	return vk_check(vk.CreateDescriptorPool(r.device, &info, nil, &b.desc_pool), "background DescriptorPool")
}

@(private="file")
background_create_frame_resources :: proc(b: ^Background_Renderer, r: ^Renderer) -> bool {
	ubo_size := vk.DeviceSize(MAX_FOG_LIGHTS * size_of([4]f32))
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		ok := create_buffer(
			r,
			ubo_size,
			{.UNIFORM_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
			&b.frames[i].buf,
			&b.frames[i].mem,
		)
		if !ok do return false
		vk.MapMemory(r.device, b.frames[i].mem, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, &b.frames[i].mapped)

		layout := b.desc_layout
		alloc := vk.DescriptorSetAllocateInfo{
			sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
			descriptorPool     = b.desc_pool,
			descriptorSetCount = 1,
			pSetLayouts        = &layout,
		}
		if !vk_check(vk.AllocateDescriptorSets(r.device, &alloc, &b.frames[i].set), "background AllocateDescriptorSets") do return false

		buf_info := vk.DescriptorBufferInfo{
			buffer = b.frames[i].buf,
			offset = 0,
			range  = ubo_size,
		}
		write := vk.WriteDescriptorSet{
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = b.frames[i].set,
			dstBinding      = 0,
			descriptorCount = 1,
			descriptorType  = .UNIFORM_BUFFER,
			pBufferInfo     = &buf_info,
		}
		vk.UpdateDescriptorSets(r.device, 1, &write, 0, nil)
	}
	return true
}

@(private="file")
background_create_pipeline :: proc(b: ^Background_Renderer, r: ^Renderer) -> bool {
	vert_mod, ok1 := create_shader_module(r.device, BACKGROUND_VERT_SPV)
	if !ok1 do return false
	defer vk.DestroyShaderModule(r.device, vert_mod, nil)
	frag_mod, ok2 := create_shader_module(r.device, BACKGROUND_FRAG_SPV)
	if !ok2 do return false
	defer vk.DestroyShaderModule(r.device, frag_mod, nil)

	stages := [2]vk.PipelineShaderStageCreateInfo{
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX},   module = vert_mod, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = frag_mod, pName = "main"},
	}

	// No vertex inputs — the vertex shader synthesises positions from gl_VertexIndex.
	vertex_input := vk.PipelineVertexInputStateCreateInfo{
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}
	input_assembly := vk.PipelineInputAssemblyStateCreateInfo{
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}
	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state := vk.PipelineDynamicStateCreateInfo{
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = 2,
		pDynamicStates    = raw_data(dynamic_states[:]),
	}
	viewport_state := vk.PipelineViewportStateCreateInfo{
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}
	rasterizer := vk.PipelineRasterizationStateCreateInfo{
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode    = {},
		frontFace   = .CLOCKWISE,
		lineWidth   = 1.0,
	}
	multisampling := vk.PipelineMultisampleStateCreateInfo{
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
		minSampleShading     = 1.0,
	}
	color_blend_attach := vk.PipelineColorBlendAttachmentState{
		blendEnable    = false,
		colorWriteMask = {.R, .G, .B, .A},
	}
	color_blend := vk.PipelineColorBlendStateCreateInfo{
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_blend_attach,
	}

	pc_range := vk.PushConstantRange{
		stageFlags = {.FRAGMENT},
		offset     = 0,
		size       = size_of(Background_PC),
	}
	layout_info := vk.PipelineLayoutCreateInfo{
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &b.desc_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &pc_range,
	}
	if !vk_check(vk.CreatePipelineLayout(r.device, &layout_info, nil, &b.pipeline_layout), "background PipelineLayout") do return false

	info := vk.GraphicsPipelineCreateInfo{
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = 2,
		pStages             = raw_data(stages[:]),
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState   = &multisampling,
		pColorBlendState    = &color_blend,
		pDynamicState       = &dynamic_state,
		layout              = b.pipeline_layout,
		renderPass          = r.render_pass,
		subpass             = 0,
	}
	return vk_check(vk.CreateGraphicsPipelines(r.device, 0, 1, &info, nil, &b.pipeline), "background GraphicsPipeline")
}

background_shutdown :: proc(b: ^Background_Renderer, r: ^Renderer) {
	if b.pipeline != 0 do vk.DestroyPipeline(r.device, b.pipeline, nil)
	if b.pipeline_layout != 0 do vk.DestroyPipelineLayout(r.device, b.pipeline_layout, nil)
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		if b.frames[i].buf != 0 do vk.DestroyBuffer(r.device, b.frames[i].buf, nil)
		if b.frames[i].mem != 0 do vk.FreeMemory(r.device, b.frames[i].mem, nil)
	}
	if b.desc_pool != 0 do vk.DestroyDescriptorPool(r.device, b.desc_pool, nil)
	if b.desc_layout != 0 do vk.DestroyDescriptorSetLayout(r.device, b.desc_layout, nil)
	delete(b.lights)
}

// Per-frame light list management. The game clears at the start of its frame
// and pushes one entry per visible building/tile in world space.
background_clear_lights :: proc(b: ^Background_Renderer) {
	clear(&b.lights)
}

background_push_light :: proc(b: ^Background_Renderer, x, y: f32) {
	if len(b.lights) >= MAX_FOG_LIGHTS do return
	append(&b.lights, [4]f32{x, y, 0, 0})
}

background_record :: proc(b: ^Background_Renderer, r: ^Renderer, cb: vk.CommandBuffer, view_scale, view_offset: [2]f32) {
	full := vk.Rect2D{extent = r.swapchain_extent}
	vk.CmdSetScissor(cb, 0, 1, &full)
	vk.CmdBindPipeline(cb, .GRAPHICS, b.pipeline)

	frame := r.current_frame
	count := len(b.lights)
	if count > MAX_FOG_LIGHTS do count = MAX_FOG_LIGHTS
	if count > 0 {
		dst := ([^][4]f32)(b.frames[frame].mapped)
		for i in 0 ..< count do dst[i] = b.lights[i]
	}

	set := b.frames[frame].set
	vk.CmdBindDescriptorSets(cb, .GRAPHICS, b.pipeline_layout, 0, 1, &set, 0, nil)

	pc := Background_PC{
		screen        = {f32(r.swapchain_extent.width), f32(r.swapchain_extent.height)},
		view_scale    = view_scale,
		view_offset   = view_offset,
		time          = f32(glfw.GetTime()),
		light_count   = i32(count),
		light_radius  = b.light_radius,
		light_falloff = b.light_falloff,
	}
	vk.CmdPushConstants(cb, b.pipeline_layout, {.FRAGMENT}, 0, size_of(Background_PC), &pc)
	vk.CmdDraw(cb, 3, 1, 0, 0)
}
