package main

import "core:fmt"
import "core:os"

import tt "vendor:stb/truetype"
import vk "vendor:vulkan"

FONT_PATH       :: "res/fonts/SUSEMono-Regular.ttf"
FONT_PIXEL_SIZE :: 32.0
FONT_FIRST_CHAR :: 32
FONT_NUM_CHARS  :: 95
ATLAS_W         :: 512
ATLAS_H         :: 512
MAX_TEXT_VERTS  :: 8192

TEXT_VERT_SPV := #load("shaders/text.vert.spv")
TEXT_FRAG_SPV := #load("shaders/text.frag.spv")

Text_Vert :: struct {
	pos:   [2]f32,
	uv:    [2]f32,
	color: [4]f32,
}

Text_PC :: struct #packed {
	screen: [2]f32,
}

Text_Frame_Buffer :: struct {
	vbuf:   vk.Buffer,
	memory: vk.DeviceMemory,
	mapped: rawptr,
}

Text_Renderer :: struct {
	chardata:        [FONT_NUM_CHARS]tt.bakedchar,
	atlas_image:     vk.Image,
	atlas_memory:    vk.DeviceMemory,
	atlas_view:      vk.ImageView,
	atlas_sampler:   vk.Sampler,

	desc_layout:     vk.DescriptorSetLayout,
	desc_pool:       vk.DescriptorPool,
	desc_set:        vk.DescriptorSet,

	pipeline_layout: vk.PipelineLayout,
	pipeline:        vk.Pipeline,

	frames:          [MAX_FRAMES_IN_FLIGHT]Text_Frame_Buffer,

	cpu_verts:       [dynamic]Text_Vert,
}

text_init :: proc(t: ^Text_Renderer, r: ^Renderer) -> bool {
	if !text_bake_atlas(t, r) do return false
	if !text_create_descriptors(t, r) do return false
	if !text_create_pipeline(t, r) do return false
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		ok := create_buffer(
			r,
			vk.DeviceSize(MAX_TEXT_VERTS * size_of(Text_Vert)),
			{.VERTEX_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
			&t.frames[i].vbuf,
			&t.frames[i].memory,
		)
		if !ok do return false
		vk.MapMemory(r.device, t.frames[i].memory, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, &t.frames[i].mapped)
	}
	return true
}

text_shutdown :: proc(t: ^Text_Renderer, r: ^Renderer) {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		if t.frames[i].vbuf != 0 do vk.DestroyBuffer(r.device, t.frames[i].vbuf, nil)
		if t.frames[i].memory != 0 do vk.FreeMemory(r.device, t.frames[i].memory, nil)
	}
	if t.pipeline != 0 do vk.DestroyPipeline(r.device, t.pipeline, nil)
	if t.pipeline_layout != 0 do vk.DestroyPipelineLayout(r.device, t.pipeline_layout, nil)
	if t.desc_pool != 0 do vk.DestroyDescriptorPool(r.device, t.desc_pool, nil)
	if t.desc_layout != 0 do vk.DestroyDescriptorSetLayout(r.device, t.desc_layout, nil)
	if t.atlas_sampler != 0 do vk.DestroySampler(r.device, t.atlas_sampler, nil)
	if t.atlas_view != 0 do vk.DestroyImageView(r.device, t.atlas_view, nil)
	if t.atlas_image != 0 do vk.DestroyImage(r.device, t.atlas_image, nil)
	if t.atlas_memory != 0 do vk.FreeMemory(r.device, t.atlas_memory, nil)
	delete(t.cpu_verts)
}

text_bake_atlas :: proc(t: ^Text_Renderer, r: ^Renderer) -> bool {
	font_data, ok := os.read_entire_file(FONT_PATH)
	if !ok {
		fmt.eprintfln("failed to read font: %s", FONT_PATH)
		return false
	}
	defer delete(font_data)

	pixels := make([]u8, ATLAS_W * ATLAS_H)
	defer delete(pixels)

	res := tt.BakeFontBitmap(
		raw_data(font_data), 0, FONT_PIXEL_SIZE,
		raw_data(pixels), ATLAS_W, ATLAS_H,
		FONT_FIRST_CHAR, FONT_NUM_CHARS,
		raw_data(t.chardata[:]),
	)
	if res == 0 {
		fmt.eprintln("BakeFontBitmap fit no characters")
		return false
	}

	{
		ok2 := create_image_2d(r, ATLAS_W, ATLAS_H, .R8_UNORM, {.TRANSFER_DST, .SAMPLED}, &t.atlas_image, &t.atlas_memory)
		if !ok2 do return false
	}
	upload_image(r, t.atlas_image, ATLAS_W, ATLAS_H, pixels) or_return

	view_info := vk.ImageViewCreateInfo{
		sType    = .IMAGE_VIEW_CREATE_INFO,
		image    = t.atlas_image,
		viewType = .D2,
		format   = .R8_UNORM,
		components = {.IDENTITY, .IDENTITY, .IDENTITY, .IDENTITY},
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	if !vk_check(vk.CreateImageView(r.device, &view_info, nil, &t.atlas_view), "atlas ImageView") do return false

	samp := vk.SamplerCreateInfo{
		sType        = .SAMPLER_CREATE_INFO,
		magFilter    = .LINEAR,
		minFilter    = .LINEAR,
		mipmapMode   = .LINEAR,
		addressModeU = .CLAMP_TO_EDGE,
		addressModeV = .CLAMP_TO_EDGE,
		addressModeW = .CLAMP_TO_EDGE,
		borderColor  = .INT_OPAQUE_BLACK,
	}
	return vk_check(vk.CreateSampler(r.device, &samp, nil, &t.atlas_sampler), "atlas Sampler")
}

text_create_descriptors :: proc(t: ^Text_Renderer, r: ^Renderer) -> bool {
	binding := vk.DescriptorSetLayoutBinding{
		binding         = 0,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = 1,
		stageFlags      = {.FRAGMENT},
	}
	layout_info := vk.DescriptorSetLayoutCreateInfo{
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 1,
		pBindings    = &binding,
	}
	if !vk_check(vk.CreateDescriptorSetLayout(r.device, &layout_info, nil, &t.desc_layout), "DescriptorSetLayout") do return false

	pool_size := vk.DescriptorPoolSize{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1}
	pool_info := vk.DescriptorPoolCreateInfo{
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = 1,
		poolSizeCount = 1,
		pPoolSizes    = &pool_size,
	}
	if !vk_check(vk.CreateDescriptorPool(r.device, &pool_info, nil, &t.desc_pool), "DescriptorPool") do return false

	alloc_info := vk.DescriptorSetAllocateInfo{
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = t.desc_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &t.desc_layout,
	}
	if !vk_check(vk.AllocateDescriptorSets(r.device, &alloc_info, &t.desc_set), "AllocateDescriptorSets") do return false

	img_info := vk.DescriptorImageInfo{
		sampler     = t.atlas_sampler,
		imageView   = t.atlas_view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	write := vk.WriteDescriptorSet{
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = t.desc_set,
		dstBinding      = 0,
		descriptorCount = 1,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		pImageInfo      = &img_info,
	}
	vk.UpdateDescriptorSets(r.device, 1, &write, 0, nil)
	return true
}

text_create_pipeline :: proc(t: ^Text_Renderer, r: ^Renderer) -> bool {
	vert_mod, ok1 := create_shader_module(r.device, TEXT_VERT_SPV)
	if !ok1 do return false
	defer vk.DestroyShaderModule(r.device, vert_mod, nil)
	frag_mod, ok2 := create_shader_module(r.device, TEXT_FRAG_SPV)
	if !ok2 do return false
	defer vk.DestroyShaderModule(r.device, frag_mod, nil)

	stages := [2]vk.PipelineShaderStageCreateInfo{
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX},   module = vert_mod, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = frag_mod, pName = "main"},
	}

	binding := vk.VertexInputBindingDescription{binding = 0, stride = size_of(Text_Vert), inputRate = .VERTEX}
	attrs := [3]vk.VertexInputAttributeDescription{
		{location = 0, binding = 0, format = .R32G32_SFLOAT,       offset = u32(offset_of(Text_Vert, pos))},
		{location = 1, binding = 0, format = .R32G32_SFLOAT,       offset = u32(offset_of(Text_Vert, uv))},
		{location = 2, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Text_Vert, color))},
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo{
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 1,
		pVertexBindingDescriptions      = &binding,
		vertexAttributeDescriptionCount = 3,
		pVertexAttributeDescriptions    = raw_data(attrs[:]),
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
		blendEnable         = true,
		srcColorBlendFactor = .SRC_ALPHA,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp        = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
		alphaBlendOp        = .ADD,
		colorWriteMask      = {.R, .G, .B, .A},
	}
	color_blend := vk.PipelineColorBlendStateCreateInfo{
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_blend_attach,
	}

	pc_range := vk.PushConstantRange{
		stageFlags = {.VERTEX},
		offset     = 0,
		size       = size_of(Text_PC),
	}
	layout_info := vk.PipelineLayoutCreateInfo{
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &t.desc_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &pc_range,
	}
	if !vk_check(vk.CreatePipelineLayout(r.device, &layout_info, nil, &t.pipeline_layout), "text PipelineLayout") do return false

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
		layout              = t.pipeline_layout,
		renderPass          = r.render_pass,
		subpass             = 0,
	}
	return vk_check(vk.CreateGraphicsPipelines(r.device, 0, 1, &info, nil, &t.pipeline), "text GraphicsPipeline")
}

text_measure :: proc(t: ^Text_Renderer, s: string) -> f32 {
	width := f32(0)
	for ch in s {
		if int(ch) < FONT_FIRST_CHAR || int(ch) >= FONT_FIRST_CHAR + FONT_NUM_CHARS do continue
		width += t.chardata[int(ch) - FONT_FIRST_CHAR].xadvance
	}
	return width
}

text_push :: proc(t: ^Text_Renderer, x, y: f32, s: string, color: [4]f32) {
	xpos := x
	ypos := y
	for ch in s {
		if int(ch) < FONT_FIRST_CHAR || int(ch) >= FONT_FIRST_CHAR + FONT_NUM_CHARS do continue
		q: tt.aligned_quad
		idx := i32(int(ch) - FONT_FIRST_CHAR)
		tt.GetBakedQuad(&t.chardata[0], ATLAS_W, ATLAS_H, idx, &xpos, &ypos, &q, true)
		v0 := Text_Vert{pos = {q.x0, q.y0}, uv = {q.s0, q.t0}, color = color}
		v1 := Text_Vert{pos = {q.x1, q.y0}, uv = {q.s1, q.t0}, color = color}
		v2 := Text_Vert{pos = {q.x1, q.y1}, uv = {q.s1, q.t1}, color = color}
		v3 := Text_Vert{pos = {q.x0, q.y1}, uv = {q.s0, q.t1}, color = color}
		append(&t.cpu_verts, v0, v1, v2, v0, v2, v3)
	}
}

text_record :: proc(t: ^Text_Renderer, r: ^Renderer, cb: vk.CommandBuffer) {
	frame := r.current_frame
	count := len(t.cpu_verts)
	if count == 0 do return
	if count > MAX_TEXT_VERTS do count = MAX_TEXT_VERTS

	dst := ([^]Text_Vert)(t.frames[frame].mapped)
	for i in 0 ..< count do dst[i] = t.cpu_verts[i]

	pc := Text_PC{screen = {f32(r.swapchain_extent.width), f32(r.swapchain_extent.height)}}
	vk.CmdBindPipeline(cb, .GRAPHICS, t.pipeline)
	vk.CmdBindDescriptorSets(cb, .GRAPHICS, t.pipeline_layout, 0, 1, &t.desc_set, 0, nil)
	vk.CmdPushConstants(cb, t.pipeline_layout, {.VERTEX}, 0, size_of(Text_PC), &pc)

	offset := vk.DeviceSize(0)
	vbuf := t.frames[frame].vbuf
	vk.CmdBindVertexBuffers(cb, 0, 1, &vbuf, &offset)
	vk.CmdDraw(cb, u32(count), 1, 0, 0)

	clear(&t.cpu_verts)
}
