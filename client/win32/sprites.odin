package main

import "core:fmt"
import "core:math"
import "core:strings"

import stbi "vendor:stb/image"
import vk "vendor:vulkan"

// Sprite_Renderer — textured-quad pass for pixel-art assets. Mirrors the text
// renderer's atlas/descriptor machinery, but textures are loaded at runtime
// (one image + view + descriptor set each) and sampled NEAREST so pixel art
// scales up crisp. Quads carry the camera transform the same way shapes do, so
// `draw_texture` honours an active world-space camera.

MAX_SPRITE_VERTS :: 16384
MAX_SPRITE_TEXTURES :: 256

SPRITE_VERT_SPV := #load("../shaders/sprite.vert.spv")
SPRITE_FRAG_SPV := #load("../shaders/sprite.frag.spv")

Sprite_Vert :: struct {
	pos:   [2]f32,
	uv:    [2]f32,
	color: [4]f32,
}

Sprite_PC :: struct #packed {
	screen:      [2]f32,
	view_scale:  [2]f32,
	view_offset: [2]f32,
}

Sprite_Frame_Buffer :: struct {
	vbuf:   vk.Buffer,
	memory: vk.DeviceMemory,
	mapped: rawptr,
}

Sprite_Texture :: struct {
	image:    vk.Image,
	memory:   vk.DeviceMemory,
	view:     vk.ImageView,
	desc_set: vk.DescriptorSet,
	w, h:     f32,
}

Sprite_Batch :: struct {
	count:       u32,
	scissor:     [4]i32,
	view_scale:  [2]f32,
	view_offset: [2]f32,
	tex:         u32, // 1-based handle; index into `textures` is tex-1
}

Sprite_Renderer :: struct {
	sampler:         vk.Sampler,
	desc_layout:     vk.DescriptorSetLayout,
	desc_pool:       vk.DescriptorPool,
	pipeline_layout: vk.PipelineLayout,
	pipeline:        vk.Pipeline,
	frames:          [MAX_FRAMES_IN_FLIGHT]Sprite_Frame_Buffer,

	textures:        [dynamic]Sprite_Texture,

	cpu_verts:       [dynamic]Sprite_Vert,
	batches:         [dynamic]Sprite_Batch,
	current_scissor:     [4]i32,
	current_view_scale:  [2]f32,
	current_view_offset: [2]f32,
}

sprites_init :: proc(s: ^Sprite_Renderer, r: ^Renderer) -> bool {
	if !sprites_create_sampler(s, r) do return false
	if !sprites_create_descriptor_layout(s, r) do return false
	if !sprites_create_descriptor_pool(s, r) do return false
	if !sprites_create_pipeline(s, r) do return false

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		ok := create_buffer(
			r,
			vk.DeviceSize(MAX_SPRITE_VERTS * size_of(Sprite_Vert)),
			{.VERTEX_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
			&s.frames[i].vbuf,
			&s.frames[i].memory,
		)
		if !ok do return false
		vk.MapMemory(r.device, s.frames[i].memory, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, &s.frames[i].mapped)
	}
	return true
}

sprites_shutdown :: proc(s: ^Sprite_Renderer, r: ^Renderer) {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		if s.frames[i].vbuf != 0 do vk.DestroyBuffer(r.device, s.frames[i].vbuf, nil)
		if s.frames[i].memory != 0 do vk.FreeMemory(r.device, s.frames[i].memory, nil)
	}
	for &t in s.textures {
		if t.view != 0 do vk.DestroyImageView(r.device, t.view, nil)
		if t.image != 0 do vk.DestroyImage(r.device, t.image, nil)
		if t.memory != 0 do vk.FreeMemory(r.device, t.memory, nil)
	}
	if s.pipeline != 0 do vk.DestroyPipeline(r.device, s.pipeline, nil)
	if s.pipeline_layout != 0 do vk.DestroyPipelineLayout(r.device, s.pipeline_layout, nil)
	if s.desc_pool != 0 do vk.DestroyDescriptorPool(r.device, s.desc_pool, nil)
	if s.desc_layout != 0 do vk.DestroyDescriptorSetLayout(r.device, s.desc_layout, nil)
	if s.sampler != 0 do vk.DestroySampler(r.device, s.sampler, nil)
	delete(s.textures)
	delete(s.cpu_verts)
	delete(s.batches)
}

sprites_set_scissor :: proc(s: ^Sprite_Renderer, scissor: [4]i32) {
	s.current_scissor = scissor
}

sprites_set_view :: proc(s: ^Sprite_Renderer, scale, offset: [2]f32) {
	s.current_view_scale = scale
	s.current_view_offset = offset
}

// Load a PNG into a new texture. `path` is a full path resolved by the host.
// Returns a 1-based handle (0 on failure).
sprites_load :: proc(s: ^Sprite_Renderer, r: ^Renderer, path: string) -> u32 {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	w, h, channels: i32
	pixels := stbi.load(cpath, &w, &h, &channels, 4) // force RGBA
	if pixels == nil {
		fmt.eprintfln("failed to load texture: %s", path)
		return 0
	}
	defer stbi.image_free(pixels)

	tex: Sprite_Texture
	tex.w = f32(w)
	tex.h = f32(h)

	if !create_image_2d(r, u32(w), u32(h), .R8G8B8A8_UNORM, {.TRANSFER_DST, .SAMPLED}, &tex.image, &tex.memory) {
		return 0
	}
	byte_count := int(w) * int(h) * 4
	if !upload_image(r, tex.image, u32(w), u32(h), pixels[:byte_count]) {
		vk.DestroyImage(r.device, tex.image, nil)
		vk.FreeMemory(r.device, tex.memory, nil)
		return 0
	}

	view_info := vk.ImageViewCreateInfo{
		sType            = .IMAGE_VIEW_CREATE_INFO,
		image            = tex.image,
		viewType         = .D2,
		format           = .R8G8B8A8_UNORM,
		components       = {.IDENTITY, .IDENTITY, .IDENTITY, .IDENTITY},
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	if !vk_check(vk.CreateImageView(r.device, &view_info, nil, &tex.view), "sprite ImageView") {
		vk.DestroyImage(r.device, tex.image, nil)
		vk.FreeMemory(r.device, tex.memory, nil)
		return 0
	}

	layout := s.desc_layout
	alloc_info := vk.DescriptorSetAllocateInfo{
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = s.desc_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &layout,
	}
	if !vk_check(vk.AllocateDescriptorSets(r.device, &alloc_info, &tex.desc_set), "sprite AllocateDescriptorSets") {
		vk.DestroyImageView(r.device, tex.view, nil)
		vk.DestroyImage(r.device, tex.image, nil)
		vk.FreeMemory(r.device, tex.memory, nil)
		return 0
	}
	img_info := vk.DescriptorImageInfo{
		sampler     = s.sampler,
		imageView   = tex.view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	write := vk.WriteDescriptorSet{
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = tex.desc_set,
		dstBinding      = 0,
		descriptorCount = 1,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		pImageInfo      = &img_info,
	}
	vk.UpdateDescriptorSets(r.device, 1, &write, 0, nil)

	append(&s.textures, tex)
	return u32(len(s.textures)) // 1-based handle
}

sprites_texture_size :: proc(s: ^Sprite_Renderer, tex: u32) -> [2]f32 {
	if tex == 0 || int(tex) > len(s.textures) do return {0, 0}
	t := s.textures[tex - 1]
	return {t.w, t.h}
}

sprites_push :: proc(s: ^Sprite_Renderer, tex: u32, x, y, w, h: f32, tint: [4]f32) {
	if tex == 0 || int(tex) > len(s.textures) do return
	batch := sprites_active_batch(s, tex)
	x0, y0 := x, y
	x1, y1 := x + w, y + h
	v0 := Sprite_Vert{pos = {x0, y0}, uv = {0, 0}, color = tint}
	v1 := Sprite_Vert{pos = {x1, y0}, uv = {1, 0}, color = tint}
	v2 := Sprite_Vert{pos = {x1, y1}, uv = {1, 1}, color = tint}
	v3 := Sprite_Vert{pos = {x0, y1}, uv = {0, 1}, color = tint}
	append(&s.cpu_verts, v0, v1, v2, v0, v2, v3)
	batch.count += 6
}

sprites_push_rotated :: proc(s: ^Sprite_Renderer, tex: u32, cx, cy, w, h, angle: f32, tint: [4]f32) {
	if tex == 0 || int(tex) > len(s.textures) do return
	batch := sprites_active_batch(s, tex)
	co := math.cos(angle)
	si := math.sin(angle)
	hw := w * 0.5
	hh := h * 0.5
	// Rotate each corner around centre.
	p0 := [2]f32{cx + (-hw)*co - (-hh)*si, cy + (-hw)*si + (-hh)*co}
	p1 := [2]f32{cx + (+hw)*co - (-hh)*si, cy + (+hw)*si + (-hh)*co}
	p2 := [2]f32{cx + (+hw)*co - (+hh)*si, cy + (+hw)*si + (+hh)*co}
	p3 := [2]f32{cx + (-hw)*co - (+hh)*si, cy + (-hw)*si + (+hh)*co}
	v0 := Sprite_Vert{pos = p0, uv = {0, 0}, color = tint}
	v1 := Sprite_Vert{pos = p1, uv = {1, 0}, color = tint}
	v2 := Sprite_Vert{pos = p2, uv = {1, 1}, color = tint}
	v3 := Sprite_Vert{pos = p3, uv = {0, 1}, color = tint}
	append(&s.cpu_verts, v0, v1, v2, v0, v2, v3)
	batch.count += 6
}

@(private="file")
sprites_active_batch :: proc(s: ^Sprite_Renderer, tex: u32) -> ^Sprite_Batch {
	n := len(s.batches)
	if n == 0 ||
	   s.batches[n-1].tex         != tex ||
	   s.batches[n-1].scissor     != s.current_scissor ||
	   s.batches[n-1].view_scale  != s.current_view_scale ||
	   s.batches[n-1].view_offset != s.current_view_offset {
		append(&s.batches, Sprite_Batch{
			count       = 0,
			scissor     = s.current_scissor,
			view_scale  = s.current_view_scale,
			view_offset = s.current_view_offset,
			tex         = tex,
		})
		n = len(s.batches)
	}
	return &s.batches[n-1]
}

@(private="file")
sprites_create_sampler :: proc(s: ^Sprite_Renderer, r: ^Renderer) -> bool {
	samp := vk.SamplerCreateInfo{
		sType        = .SAMPLER_CREATE_INFO,
		magFilter    = .NEAREST,
		minFilter    = .NEAREST,
		mipmapMode   = .NEAREST,
		addressModeU = .CLAMP_TO_EDGE,
		addressModeV = .CLAMP_TO_EDGE,
		addressModeW = .CLAMP_TO_EDGE,
		borderColor  = .INT_OPAQUE_BLACK,
	}
	return vk_check(vk.CreateSampler(r.device, &samp, nil, &s.sampler), "sprite Sampler")
}

@(private="file")
sprites_create_descriptor_layout :: proc(s: ^Sprite_Renderer, r: ^Renderer) -> bool {
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
	return vk_check(vk.CreateDescriptorSetLayout(r.device, &layout_info, nil, &s.desc_layout), "sprite DescriptorSetLayout")
}

@(private="file")
sprites_create_descriptor_pool :: proc(s: ^Sprite_Renderer, r: ^Renderer) -> bool {
	pool_size := vk.DescriptorPoolSize{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = MAX_SPRITE_TEXTURES}
	pool_info := vk.DescriptorPoolCreateInfo{
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = MAX_SPRITE_TEXTURES,
		poolSizeCount = 1,
		pPoolSizes    = &pool_size,
	}
	return vk_check(vk.CreateDescriptorPool(r.device, &pool_info, nil, &s.desc_pool), "sprite DescriptorPool")
}

@(private="file")
sprites_create_pipeline :: proc(s: ^Sprite_Renderer, r: ^Renderer) -> bool {
	vert_mod, ok1 := create_shader_module(r.device, SPRITE_VERT_SPV)
	if !ok1 do return false
	defer vk.DestroyShaderModule(r.device, vert_mod, nil)
	frag_mod, ok2 := create_shader_module(r.device, SPRITE_FRAG_SPV)
	if !ok2 do return false
	defer vk.DestroyShaderModule(r.device, frag_mod, nil)

	stages := [2]vk.PipelineShaderStageCreateInfo{
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX},   module = vert_mod, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = frag_mod, pName = "main"},
	}

	binding := vk.VertexInputBindingDescription{binding = 0, stride = size_of(Sprite_Vert), inputRate = .VERTEX}
	attrs := [3]vk.VertexInputAttributeDescription{
		{location = 0, binding = 0, format = .R32G32_SFLOAT,       offset = u32(offset_of(Sprite_Vert, pos))},
		{location = 1, binding = 0, format = .R32G32_SFLOAT,       offset = u32(offset_of(Sprite_Vert, uv))},
		{location = 2, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Sprite_Vert, color))},
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo{
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 1,
		pVertexBindingDescriptions      = &binding,
		vertexAttributeDescriptionCount = u32(len(attrs)),
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
		size       = size_of(Sprite_PC),
	}
	layout_info := vk.PipelineLayoutCreateInfo{
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &s.desc_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &pc_range,
	}
	if !vk_check(vk.CreatePipelineLayout(r.device, &layout_info, nil, &s.pipeline_layout), "sprite PipelineLayout") do return false

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
		layout              = s.pipeline_layout,
		renderPass          = r.render_pass,
		subpass             = 0,
	}
	return vk_check(vk.CreateGraphicsPipelines(r.device, 0, 1, &info, nil, &s.pipeline), "sprite GraphicsPipeline")
}

sprites_record :: proc(s: ^Sprite_Renderer, r: ^Renderer, cb: vk.CommandBuffer) {
	frame := r.current_frame
	count := len(s.cpu_verts)
	if count == 0 {
		clear(&s.batches)
		return
	}
	if count > MAX_SPRITE_VERTS do count = MAX_SPRITE_VERTS

	dst := ([^]Sprite_Vert)(s.frames[frame].mapped)
	for i in 0 ..< count do dst[i] = s.cpu_verts[i]

	screen := [2]f32{f32(r.swapchain_extent.width), f32(r.swapchain_extent.height)}
	vk.CmdBindPipeline(cb, .GRAPHICS, s.pipeline)

	offset := vk.DeviceSize(0)
	vbuf := s.frames[frame].vbuf
	vk.CmdBindVertexBuffers(cb, 0, 1, &vbuf, &offset)

	first := u32(0)
	remaining := u32(count)
	for batch in s.batches {
		if remaining == 0 do break
		draw := batch.count
		if draw > remaining do draw = remaining
		sw := batch.scissor[2]; if sw < 0 do sw = 0
		sh := batch.scissor[3]; if sh < 0 do sh = 0
		rect := vk.Rect2D{offset = {batch.scissor[0], batch.scissor[1]}, extent = {u32(sw), u32(sh)}}
		vk.CmdSetScissor(cb, 0, 1, &rect)
		pc := Sprite_PC{
			screen      = screen,
			view_scale  = batch.view_scale,
			view_offset = batch.view_offset,
		}
		vk.CmdPushConstants(cb, s.pipeline_layout, {.VERTEX}, 0, size_of(Sprite_PC), &pc)
		ds := s.textures[batch.tex - 1].desc_set
		vk.CmdBindDescriptorSets(cb, .GRAPHICS, s.pipeline_layout, 0, 1, &ds, 0, nil)
		vk.CmdDraw(cb, draw, 1, first, 0)
		first += draw
		remaining -= draw
	}

	clear(&s.cpu_verts)
	clear(&s.batches)
}
