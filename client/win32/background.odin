package main

import "vendor:glfw"
import vk "vendor:vulkan"

BACKGROUND_VERT_SPV := #load("../shaders/background.vert.spv")
BACKGROUND_FRAG_SPV := #load("../shaders/background.frag.spv")

Background_PC :: struct #packed {
	screen:      [2]f32,
	view_scale:  [2]f32,
	view_offset: [2]f32,
	time:        f32,
	_pad:        f32,
}

Background_Renderer :: struct {
	pipeline_layout: vk.PipelineLayout,
	pipeline:        vk.Pipeline,
}

background_init :: proc(b: ^Background_Renderer, r: ^Renderer) -> bool {
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
}

background_record :: proc(b: ^Background_Renderer, r: ^Renderer, cb: vk.CommandBuffer, view_scale, view_offset: [2]f32) {
	full := vk.Rect2D{extent = r.swapchain_extent}
	vk.CmdSetScissor(cb, 0, 1, &full)
	vk.CmdBindPipeline(cb, .GRAPHICS, b.pipeline)
	pc := Background_PC{
		screen      = {f32(r.swapchain_extent.width), f32(r.swapchain_extent.height)},
		view_scale  = view_scale,
		view_offset = view_offset,
		time        = f32(glfw.GetTime()),
	}
	vk.CmdPushConstants(cb, b.pipeline_layout, {.FRAGMENT}, 0, size_of(Background_PC), &pc)
	vk.CmdDraw(cb, 3, 1, 0, 0)
}
