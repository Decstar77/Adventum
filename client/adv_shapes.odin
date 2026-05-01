package main

import "core:math"

import vk "vendor:vulkan"

MAX_SHAPE_VERTS :: 16384
SHAPE_AA_PAD    :: 1.5

SHAPE_TYPE_RECT    :: 0.0
SHAPE_TYPE_CIRCLE  :: 1.0
SHAPE_TYPE_CAPSULE :: 2.0

SHAPES_VERT_SPV := #load("shaders/shapes.vert.spv")
SHAPES_FRAG_SPV := #load("shaders/shapes.frag.spv")

Shape_Vert :: struct {
	pos:    [2]f32,
	local:  [2]f32,
	params: [2]f32,
	color:  [4]f32,
	type:   f32,
}

Shape_PC :: struct #packed {
	screen: [2]f32,
}

Shape_Frame_Buffer :: struct {
	vbuf:   vk.Buffer,
	memory: vk.DeviceMemory,
	mapped: rawptr,
}

Shape_Renderer :: struct {
	pipeline_layout: vk.PipelineLayout,
	pipeline:        vk.Pipeline,
	frames:          [MAX_FRAMES_IN_FLIGHT]Shape_Frame_Buffer,
	cpu_verts:       [dynamic]Shape_Vert,
}

shapes_init :: proc(s: ^Shape_Renderer, r: ^Renderer) -> bool {
	if !shapes_create_pipeline(s, r) do return false
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		ok := create_buffer(
			r,
			vk.DeviceSize(MAX_SHAPE_VERTS * size_of(Shape_Vert)),
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

shapes_shutdown :: proc(s: ^Shape_Renderer, r: ^Renderer) {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		if s.frames[i].vbuf != 0 do vk.DestroyBuffer(r.device, s.frames[i].vbuf, nil)
		if s.frames[i].memory != 0 do vk.FreeMemory(r.device, s.frames[i].memory, nil)
	}
	if s.pipeline != 0 do vk.DestroyPipeline(r.device, s.pipeline, nil)
	if s.pipeline_layout != 0 do vk.DestroyPipelineLayout(r.device, s.pipeline_layout, nil)
	delete(s.cpu_verts)
}

shapes_create_pipeline :: proc(s: ^Shape_Renderer, r: ^Renderer) -> bool {
	vert_mod, ok1 := create_shader_module(r.device, SHAPES_VERT_SPV)
	if !ok1 do return false
	defer vk.DestroyShaderModule(r.device, vert_mod, nil)
	frag_mod, ok2 := create_shader_module(r.device, SHAPES_FRAG_SPV)
	if !ok2 do return false
	defer vk.DestroyShaderModule(r.device, frag_mod, nil)

	stages := [2]vk.PipelineShaderStageCreateInfo{
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX},   module = vert_mod, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = frag_mod, pName = "main"},
	}

	binding := vk.VertexInputBindingDescription{binding = 0, stride = size_of(Shape_Vert), inputRate = .VERTEX}
	attrs := [5]vk.VertexInputAttributeDescription{
		{location = 0, binding = 0, format = .R32G32_SFLOAT,       offset = u32(offset_of(Shape_Vert, pos))},
		{location = 1, binding = 0, format = .R32G32_SFLOAT,       offset = u32(offset_of(Shape_Vert, local))},
		{location = 2, binding = 0, format = .R32G32_SFLOAT,       offset = u32(offset_of(Shape_Vert, params))},
		{location = 3, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Shape_Vert, color))},
		{location = 4, binding = 0, format = .R32_SFLOAT,          offset = u32(offset_of(Shape_Vert, type))},
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
		size       = size_of(Shape_PC),
	}
	layout_info := vk.PipelineLayoutCreateInfo{
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &pc_range,
	}
	if !vk_check(vk.CreatePipelineLayout(r.device, &layout_info, nil, &s.pipeline_layout), "shapes PipelineLayout") do return false

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
	return vk_check(vk.CreateGraphicsPipelines(r.device, 0, 1, &info, nil, &s.pipeline), "shapes GraphicsPipeline")
}

@(private="file")
push_quad :: proc(
	s: ^Shape_Renderer,
	p0, p1, p2, p3: [2]f32,
	l0, l1, l2, l3: [2]f32,
	params: [2]f32,
	color:  [4]f32,
	type:   f32,
) {
	v0 := Shape_Vert{pos = p0, local = l0, params = params, color = color, type = type}
	v1 := Shape_Vert{pos = p1, local = l1, params = params, color = color, type = type}
	v2 := Shape_Vert{pos = p2, local = l2, params = params, color = color, type = type}
	v3 := Shape_Vert{pos = p3, local = l3, params = params, color = color, type = type}
	append(&s.cpu_verts, v0, v1, v2, v0, v2, v3)
}

shapes_push_rect :: proc(s: ^Shape_Renderer, x, y, w, h: f32, color: [4]f32) {
	hx, hy := w * 0.5, h * 0.5
	cx, cy := x + hx, y + hy
	px, py := hx + SHAPE_AA_PAD, hy + SHAPE_AA_PAD
	push_quad(
		s,
		{cx - px, cy - py}, {cx + px, cy - py}, {cx + px, cy + py}, {cx - px, cy + py},
		{-px, -py},         { px, -py},         { px,  py},         {-px,  py},
		{hx, hy},
		color,
		SHAPE_TYPE_RECT,
	)
}

shapes_push_circle :: proc(s: ^Shape_Renderer, cx, cy, radius: f32, color: [4]f32) {
	R := radius + SHAPE_AA_PAD
	push_quad(
		s,
		{cx - R, cy - R}, {cx + R, cy - R}, {cx + R, cy + R}, {cx - R, cy + R},
		{-R, -R},         { R, -R},         { R,  R},         {-R,  R},
		{radius, 0},
		color,
		SHAPE_TYPE_CIRCLE,
	)
}

shapes_push_line :: proc(s: ^Shape_Renderer, ax, ay, bx, by, thickness: f32, color: [4]f32) {
	dx := bx - ax
	dy := by - ay
	L := math.sqrt(dx*dx + dy*dy)
	if L <= 0 do return

	half_len := L * 0.5
	r        := thickness * 0.5
	ux, uy   := dx / L, dy / L
	nx, ny   := -uy, ux
	cx, cy   := (ax + bx) * 0.5, (ay + by) * 0.5

	lx := half_len + r + SHAPE_AA_PAD
	ly := r + SHAPE_AA_PAD

	p0 := [2]f32{cx - lx*ux + ly*nx, cy - lx*uy + ly*ny}
	p1 := [2]f32{cx + lx*ux + ly*nx, cy + lx*uy + ly*ny}
	p2 := [2]f32{cx + lx*ux - ly*nx, cy + lx*uy - ly*ny}
	p3 := [2]f32{cx - lx*ux - ly*nx, cy - lx*uy - ly*ny}

	push_quad(
		s,
		p0, p1, p2, p3,
		{-lx,  ly}, { lx,  ly}, { lx, -ly}, {-lx, -ly},
		{half_len, r},
		color,
		SHAPE_TYPE_CAPSULE,
	)
}

shapes_record :: proc(s: ^Shape_Renderer, r: ^Renderer, cb: vk.CommandBuffer) {
	frame := r.current_frame
	count := len(s.cpu_verts)
	if count == 0 do return
	if count > MAX_SHAPE_VERTS do count = MAX_SHAPE_VERTS

	dst := ([^]Shape_Vert)(s.frames[frame].mapped)
	for i in 0 ..< count do dst[i] = s.cpu_verts[i]

	pc := Shape_PC{screen = {f32(r.swapchain_extent.width), f32(r.swapchain_extent.height)}}
	vk.CmdBindPipeline(cb, .GRAPHICS, s.pipeline)
	vk.CmdPushConstants(cb, s.pipeline_layout, {.VERTEX}, 0, size_of(Shape_PC), &pc)

	offset := vk.DeviceSize(0)
	vbuf := s.frames[frame].vbuf
	vk.CmdBindVertexBuffers(cb, 0, 1, &vbuf, &offset)
	vk.CmdDraw(cb, u32(count), 1, 0, 0)

	clear(&s.cpu_verts)
}
