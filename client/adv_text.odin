package main

import "core:fmt"
import "core:os"

import tt "vendor:stb/truetype"
import sg "sokol/gfx"

FONT_PATH       :: "res/fonts/SUSEMono-Regular.ttf"
FONT_PIXEL_SIZE :: 16.0      // legacy alias for the Small atlas; layout math still uses this
FONT_FIRST_CHAR :: 32
FONT_NUM_CHARS  :: 95
ATLAS_W         :: 1024
ATLAS_H         :: 1024
MAX_TEXT_VERTS  :: 8192

Font_Size :: enum {
	Small,
	Large,
}

FONT_COUNT :: len(Font_Size)

FONT_PIXEL_SIZES := [FONT_COUNT]f32{
	Font_Size.Small = 16.0,
	Font_Size.Large = 36.0,
}

Text_Vert :: struct {
	pos:   [2]f32,
	uv:    [2]f32,
	color: [4]f32,
}

// std140 padded: vec2 screen + 8 bytes pad → 16 bytes.
Text_Uniforms :: struct {
	screen: [2]f32,
	_pad:   [2]f32,
}

Text_Batch :: struct {
	count:   u32,
	scissor: [4]i32,
	font:    Font_Size,
}

Font_Atlas :: struct {
	chardata:   [FONT_NUM_CHARS]tt.bakedchar,
	image:      sg.Image,
	pixel_size: f32,
}

Text_Renderer :: struct {
	atlases:         [FONT_COUNT]Font_Atlas,
	sampler:         sg.Sampler,
	shader:          sg.Shader,
	pipeline:        sg.Pipeline,
	vbuf:            sg.Buffer,

	cpu_verts:       [dynamic]Text_Vert,
	batches:         [dynamic]Text_Batch,
	current_scissor: [4]i32,
	current_font:    Font_Size,
}

text_init :: proc(t: ^Text_Renderer) -> bool {
	font_data, ok := os.read_entire_file(FONT_PATH)
	if !ok {
		fmt.eprintfln("failed to read font: %s", FONT_PATH)
		return false
	}
	defer delete(font_data)

	for size, i in Font_Size {
		if !text_bake_atlas(&t.atlases[i], FONT_PIXEL_SIZES[i], font_data) do return false
	}

	t.sampler = sg.make_sampler({
		min_filter = .LINEAR,
		mag_filter = .LINEAR,
		wrap_u     = .CLAMP_TO_EDGE,
		wrap_v     = .CLAMP_TO_EDGE,
		label      = "text-sampler",
	})

	t.vbuf = sg.make_buffer({
		size  = MAX_TEXT_VERTS * size_of(Text_Vert),
		usage = .STREAM,
		type  = .VERTEXBUFFER,
		label = "text-vbuf",
	})

	shader_desc := sg.Shader_Desc{
		vertex_func   = {source = select_shader_source(TEXT_VS_GLCORE, TEXT_VS_GLES3)},
		fragment_func = {source = select_shader_source(TEXT_FS_GLCORE, TEXT_FS_GLES3)},
		label         = "text-shader",
	}
	shader_desc.attrs[0] = {glsl_name = "in_pos"}
	shader_desc.attrs[1] = {glsl_name = "in_uv"}
	shader_desc.attrs[2] = {glsl_name = "in_color"}
	shader_desc.uniform_blocks[0] = {
		stage  = .VERTEX,
		size   = size_of(Text_Uniforms),
		layout = .STD140,
	}
	shader_desc.uniform_blocks[0].glsl_uniforms[0] = {type = .FLOAT2, glsl_name = "screen"}
	shader_desc.images[0]   = {stage = .FRAGMENT, image_type = ._2D, sample_type = .FLOAT}
	shader_desc.samplers[0] = {stage = .FRAGMENT, sampler_type = .FILTERING}
	shader_desc.image_sampler_pairs[0] = {stage = .FRAGMENT, image_slot = 0, sampler_slot = 0, glsl_name = "u_atlas"}
	t.shader = sg.make_shader(shader_desc)

	pip_desc := sg.Pipeline_Desc{
		shader         = t.shader,
		primitive_type = .TRIANGLES,
		index_type     = .NONE,
		cull_mode      = .NONE,
		label          = "text-pipeline",
	}
	pip_desc.layout.buffers[0] = {stride = size_of(Text_Vert)}
	pip_desc.layout.attrs[0] = {buffer_index = 0, offset = i32(offset_of(Text_Vert, pos)),   format = .FLOAT2}
	pip_desc.layout.attrs[1] = {buffer_index = 0, offset = i32(offset_of(Text_Vert, uv)),    format = .FLOAT2}
	pip_desc.layout.attrs[2] = {buffer_index = 0, offset = i32(offset_of(Text_Vert, color)), format = .FLOAT4}
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
	t.pipeline = sg.make_pipeline(pip_desc)
	return true
}

text_shutdown :: proc(t: ^Text_Renderer) {
	sg.destroy_pipeline(t.pipeline)
	sg.destroy_shader(t.shader)
	sg.destroy_buffer(t.vbuf)
	sg.destroy_sampler(t.sampler)
	for &a in t.atlases do sg.destroy_image(a.image)
	delete(t.cpu_verts)
	delete(t.batches)
}

text_set_scissor :: proc(t: ^Text_Renderer, scissor: [4]i32) {
	t.current_scissor = scissor
}

@(private="file")
text_active_batch :: proc(t: ^Text_Renderer) -> ^Text_Batch {
	n := len(t.batches)
	if n == 0 ||
	   t.batches[n-1].scissor != t.current_scissor ||
	   t.batches[n-1].font    != t.current_font {
		append(&t.batches, Text_Batch{
			count   = 0,
			scissor = t.current_scissor,
			font    = t.current_font,
		})
		n = len(t.batches)
	}
	return &t.batches[n-1]
}

@(private="file")
text_bake_atlas :: proc(atlas: ^Font_Atlas, pixel_size: f32, font_data: []u8) -> bool {
	atlas.pixel_size = pixel_size

	pixels := make([]u8, ATLAS_W * ATLAS_H)
	defer delete(pixels)

	res := tt.BakeFontBitmap(
		raw_data(font_data), 0, pixel_size,
		raw_data(pixels), ATLAS_W, ATLAS_H,
		FONT_FIRST_CHAR, FONT_NUM_CHARS,
		raw_data(atlas.chardata[:]),
	)
	if res == 0 {
		fmt.eprintfln("BakeFontBitmap fit no characters at %.0fpx", pixel_size)
		return false
	}

	img_desc := sg.Image_Desc{
		width        = ATLAS_W,
		height       = ATLAS_H,
		pixel_format = .R8,
		label        = "font-atlas",
	}
	img_desc.data.subimage[0][0] = {ptr = raw_data(pixels), size = ATLAS_W * ATLAS_H}
	atlas.image = sg.make_image(img_desc)
	return true
}

text_measure :: proc(t: ^Text_Renderer, s: string, font: Font_Size = .Small) -> f32 {
	atlas := &t.atlases[font]
	width := f32(0)
	for ch in s {
		if int(ch) < FONT_FIRST_CHAR || int(ch) >= FONT_FIRST_CHAR + FONT_NUM_CHARS do continue
		width += atlas.chardata[int(ch) - FONT_FIRST_CHAR].xadvance
	}
	return width
}

font_pixel_size :: proc(font: Font_Size) -> f32 {
	return FONT_PIXEL_SIZES[font]
}

text_push :: proc(t: ^Text_Renderer, x, y: f32, s: string, color: [4]f32, font: Font_Size = .Small) {
	t.current_font = font
	atlas := &t.atlases[font]
	xpos := x
	ypos := y
	batch := text_active_batch(t)
	for ch in s {
		if int(ch) < FONT_FIRST_CHAR || int(ch) >= FONT_FIRST_CHAR + FONT_NUM_CHARS do continue
		q: tt.aligned_quad
		idx := i32(int(ch) - FONT_FIRST_CHAR)
		tt.GetBakedQuad(&atlas.chardata[0], ATLAS_W, ATLAS_H, idx, &xpos, &ypos, &q, true)
		v0 := Text_Vert{pos = {q.x0, q.y0}, uv = {q.s0, q.t0}, color = color}
		v1 := Text_Vert{pos = {q.x1, q.y0}, uv = {q.s1, q.t0}, color = color}
		v2 := Text_Vert{pos = {q.x1, q.y1}, uv = {q.s1, q.t1}, color = color}
		v3 := Text_Vert{pos = {q.x0, q.y1}, uv = {q.s0, q.t1}, color = color}
		append(&t.cpu_verts, v0, v1, v2, v0, v2, v3)
		batch.count += 6
	}
}

text_record :: proc(t: ^Text_Renderer, r: ^Renderer) {
	count := len(t.cpu_verts)
	if count == 0 {
		clear(&t.batches)
		return
	}
	if count > MAX_TEXT_VERTS do count = MAX_TEXT_VERTS

	sg.update_buffer(t.vbuf, {ptr = raw_data(t.cpu_verts), size = uint(count) * size_of(Text_Vert)})

	sg.apply_pipeline(t.pipeline)

	uni := Text_Uniforms{screen = {f32(r.width), f32(r.height)}}

	first := u32(0)
	remaining := u32(count)
	for batch in t.batches {
		if remaining == 0 do break
		draw := batch.count
		if draw > remaining do draw = remaining
		sw := batch.scissor[2]; if sw < 0 do sw = 0
		sh := batch.scissor[3]; if sh < 0 do sh = 0
		sg.apply_scissor_rect(batch.scissor[0], batch.scissor[1], sw, sh, true)

		bind := sg.Bindings{}
		bind.vertex_buffers[0] = t.vbuf
		bind.images[0]         = t.atlases[batch.font].image
		bind.samplers[0]       = t.sampler
		sg.apply_bindings(bind)
		sg.apply_uniforms(0, {ptr = &uni, size = size_of(Text_Uniforms)})
		sg.draw(int(first), int(draw), 1)
		first += draw
		remaining -= draw
	}

	clear(&t.cpu_verts)
	clear(&t.batches)
}
