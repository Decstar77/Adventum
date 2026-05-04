package main

import sg "sokol/gfx"

// std140 padded already at 32 bytes (3 vec2 + 2 floats).
Bg_Uniforms :: struct {
	screen:      [2]f32,
	view_scale:  [2]f32,
	view_offset: [2]f32,
	time:        f32,
	_pad:        f32,
}

Background_Renderer :: struct {
	pipeline: sg.Pipeline,
	shader:   sg.Shader,
}

background_init :: proc(b: ^Background_Renderer) -> bool {
	shader_desc := sg.Shader_Desc{
		vertex_func   = {source = select_shader_source(BG_VS_GLCORE, BG_VS_GLES3)},
		fragment_func = {source = select_shader_source(BG_FS_GLCORE, BG_FS_GLES3)},
		label         = "bg-shader",
	}
	shader_desc.uniform_blocks[0] = {
		stage  = .FRAGMENT,
		size   = size_of(Bg_Uniforms),
		layout = .STD140,
	}
	shader_desc.uniform_blocks[0].glsl_uniforms[0] = {type = .FLOAT2, glsl_name = "screen"}
	shader_desc.uniform_blocks[0].glsl_uniforms[1] = {type = .FLOAT2, glsl_name = "view_scale"}
	shader_desc.uniform_blocks[0].glsl_uniforms[2] = {type = .FLOAT2, glsl_name = "view_offset"}
	shader_desc.uniform_blocks[0].glsl_uniforms[3] = {type = .FLOAT,  glsl_name = "time"}
	b.shader = sg.make_shader(shader_desc)

	pip_desc := sg.Pipeline_Desc{
		shader         = b.shader,
		primitive_type = .TRIANGLES,
		index_type     = .NONE,
		cull_mode      = .NONE,
		label          = "bg-pipeline",
	}
	pip_desc.colors[0] = {} // no blend
	b.pipeline = sg.make_pipeline(pip_desc)
	return true
}

background_shutdown :: proc(b: ^Background_Renderer) {
	sg.destroy_pipeline(b.pipeline)
	sg.destroy_shader(b.shader)
}

background_record :: proc(b: ^Background_Renderer, r: ^Renderer, view_scale, view_offset: [2]f32, time: f32) {
	sg.apply_scissor_rect(0, 0, r.width, r.height, true)
	sg.apply_pipeline(b.pipeline)
	// No vertex buffer / images, so apply_bindings is intentionally skipped:
	// sokol's bitmask check would otherwise flag a mismatch since the pipeline
	// declares no required bindings.
	uni := Bg_Uniforms{
		screen      = {f32(r.width), f32(r.height)},
		view_scale  = view_scale,
		view_offset = view_offset,
		time        = time,
	}
	sg.apply_uniforms(0, {ptr = &uni, size = size_of(Bg_Uniforms)})
	sg.draw(0, 3, 1)
}
