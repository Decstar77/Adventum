package main

import "core:math"

import sg "sokol/gfx"

MAX_SHAPE_VERTS :: 16384
SHAPE_AA_PAD    :: 1.5

SHAPE_TYPE_RECT    :: 0.0
SHAPE_TYPE_CIRCLE  :: 1.0
SHAPE_TYPE_CAPSULE :: 2.0

Shape_Vert :: struct {
	pos:    [2]f32,
	local:  [2]f32,
	params: [2]f32,
	color:  [4]f32,
	type:   f32,
}

// std140-friendly: 3 vec2s tightly packed (24 bytes) padded to 32 (vec4 multiple).
Shape_Uniforms :: struct {
	screen:      [2]f32,
	view_scale:  [2]f32,
	view_offset: [2]f32,
	_pad:        [2]f32,
}

Shape_Batch :: struct {
	count:       u32,
	scissor:     [4]i32,
	view_scale:  [2]f32,
	view_offset: [2]f32,
}

Shape_Renderer :: struct {
	pipeline:            sg.Pipeline,
	shader:              sg.Shader,
	vbuf:                sg.Buffer,
	cpu_verts:           [dynamic]Shape_Vert,
	batches:             [dynamic]Shape_Batch,
	current_scissor:     [4]i32,
	current_view_scale:  [2]f32,
	current_view_offset: [2]f32,
}

shapes_init :: proc(s: ^Shape_Renderer) -> bool {
	s.vbuf = sg.make_buffer({
		size  = MAX_SHAPE_VERTS * size_of(Shape_Vert),
		usage = .STREAM,
		type  = .VERTEXBUFFER,
		label = "shapes-vbuf",
	})

	shader_desc := sg.Shader_Desc{
		vertex_func   = {source = select_shader_source(SHAPES_VS_GLCORE, SHAPES_VS_GLES3)},
		fragment_func = {source = select_shader_source(SHAPES_FS_GLCORE, SHAPES_FS_GLES3)},
		label         = "shapes-shader",
	}
	shader_desc.attrs[0] = {glsl_name = "in_pos"}
	shader_desc.attrs[1] = {glsl_name = "in_local"}
	shader_desc.attrs[2] = {glsl_name = "in_params"}
	shader_desc.attrs[3] = {glsl_name = "in_color"}
	shader_desc.attrs[4] = {glsl_name = "in_type"}
	shader_desc.uniform_blocks[0] = {
		stage  = .VERTEX,
		size   = size_of(Shape_Uniforms),
		layout = .STD140,
	}
	shader_desc.uniform_blocks[0].glsl_uniforms[0] = {type = .FLOAT2, glsl_name = "screen"}
	shader_desc.uniform_blocks[0].glsl_uniforms[1] = {type = .FLOAT2, glsl_name = "view_scale"}
	shader_desc.uniform_blocks[0].glsl_uniforms[2] = {type = .FLOAT2, glsl_name = "view_offset"}
	s.shader = sg.make_shader(shader_desc)

	pip_desc := sg.Pipeline_Desc{
		shader         = s.shader,
		primitive_type = .TRIANGLES,
		index_type     = .NONE,
		cull_mode      = .NONE,
		label          = "shapes-pipeline",
	}
	pip_desc.layout.buffers[0] = {stride = size_of(Shape_Vert)}
	pip_desc.layout.attrs[0] = {buffer_index = 0, offset = i32(offset_of(Shape_Vert, pos)),    format = .FLOAT2}
	pip_desc.layout.attrs[1] = {buffer_index = 0, offset = i32(offset_of(Shape_Vert, local)),  format = .FLOAT2}
	pip_desc.layout.attrs[2] = {buffer_index = 0, offset = i32(offset_of(Shape_Vert, params)), format = .FLOAT2}
	pip_desc.layout.attrs[3] = {buffer_index = 0, offset = i32(offset_of(Shape_Vert, color)),  format = .FLOAT4}
	pip_desc.layout.attrs[4] = {buffer_index = 0, offset = i32(offset_of(Shape_Vert, type)),   format = .FLOAT}
	pip_desc.colors[0] = {
		blend = {
			enabled          = true,
			src_factor_rgb   = .SRC_ALPHA,
			dst_factor_rgb   = .ONE_MINUS_SRC_ALPHA,
			op_rgb           = .ADD,
			src_factor_alpha = .ONE,
			dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
			op_alpha         = .ADD,
		},
	}
	s.pipeline = sg.make_pipeline(pip_desc)
	return true
}

shapes_shutdown :: proc(s: ^Shape_Renderer) {
	sg.destroy_pipeline(s.pipeline)
	sg.destroy_shader(s.shader)
	sg.destroy_buffer(s.vbuf)
	delete(s.cpu_verts)
	delete(s.batches)
}

shapes_set_scissor :: proc(s: ^Shape_Renderer, scissor: [4]i32) {
	s.current_scissor = scissor
}

shapes_set_view :: proc(s: ^Shape_Renderer, scale, offset: [2]f32) {
	s.current_view_scale = scale
	s.current_view_offset = offset
}

@(private="file")
shapes_active_batch :: proc(s: ^Shape_Renderer) -> ^Shape_Batch {
	n := len(s.batches)
	if n == 0 ||
	   s.batches[n-1].scissor     != s.current_scissor ||
	   s.batches[n-1].view_scale  != s.current_view_scale ||
	   s.batches[n-1].view_offset != s.current_view_offset {
		append(&s.batches, Shape_Batch{
			count       = 0,
			scissor     = s.current_scissor,
			view_scale  = s.current_view_scale,
			view_offset = s.current_view_offset,
		})
		n = len(s.batches)
	}
	return &s.batches[n-1]
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
	shapes_active_batch(s).count += 6
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

shapes_record :: proc(s: ^Shape_Renderer, r: ^Renderer) {
	count := len(s.cpu_verts)
	if count == 0 {
		clear(&s.batches)
		return
	}
	if count > MAX_SHAPE_VERTS do count = MAX_SHAPE_VERTS

	sg.update_buffer(s.vbuf, {ptr = raw_data(s.cpu_verts), size = uint(count) * size_of(Shape_Vert)})

	bind := sg.Bindings{}
	bind.vertex_buffers[0] = s.vbuf
	sg.apply_pipeline(s.pipeline)
	sg.apply_bindings(bind)

	screen := [2]f32{f32(r.width), f32(r.height)}
	first := u32(0)
	remaining := u32(count)
	for batch in s.batches {
		if remaining == 0 do break
		draw := batch.count
		if draw > remaining do draw = remaining
		sw := batch.scissor[2]; if sw < 0 do sw = 0
		sh := batch.scissor[3]; if sh < 0 do sh = 0
		sg.apply_scissor_rect(batch.scissor[0], batch.scissor[1], sw, sh, true)

		uni := Shape_Uniforms{
			screen      = screen,
			view_scale  = batch.view_scale,
			view_offset = batch.view_offset,
		}
		sg.apply_uniforms(0, {ptr = &uni, size = size_of(Shape_Uniforms)})
		sg.draw(int(first), int(draw), 1)
		first += draw
		remaining -= draw
	}

	clear(&s.cpu_verts)
	clear(&s.batches)
}
