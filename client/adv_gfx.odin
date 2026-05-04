package main

import sg    "sokol/gfx"
import sglue "sokol/glue"

Graphics :: struct {
	renderer:           ^Renderer,
	bg:                 Background_Renderer,
	shapes:             Shape_Renderer,
	text:               Text_Renderer,
	scissor_stack:      [dynamic][4]i32,
	world_view_scale:   [2]f32,
	world_view_offset:  [2]f32,
	bg_time:            f32,
}

gfx_init :: proc(g: ^Graphics, r: ^Renderer) -> bool {
	g.renderer = r
	if !background_init(&g.bg) do return false
	if !shapes_init(&g.shapes) do return false
	if !text_init(&g.text) do return false
	return true
}

gfx_shutdown :: proc(g: ^Graphics) {
	if g.renderer == nil do return
	text_shutdown(&g.text)
	shapes_shutdown(&g.shapes)
	background_shutdown(&g.bg)
	delete(g.scissor_stack)
}

gfx_begin :: proc(g: ^Graphics, dt: f32) -> bool {
	renderer_update_size(g.renderer)
	w := g.renderer.width
	h := g.renderer.height
	if w <= 0 || h <= 0 do return false

	g.bg_time += dt

	clear(&g.scissor_stack)
	full := [4]i32{0, 0, w, h}
	append(&g.scissor_stack, full)
	shapes_set_scissor(&g.shapes, full)
	shapes_set_view(&g.shapes, {1, 1}, {0, 0})
	text_set_scissor(&g.text, full)
	g.world_view_scale  = {1, 1}
	g.world_view_offset = {0, 0}
	return true
}

gfx_set_camera :: proc(g: ^Graphics, cam: ^Camera) {
	sw := f32(g.renderer.width)
	sh := f32(g.renderer.height)
	scale := [2]f32{cam.zoom, cam.zoom}
	offset := [2]f32{sw * 0.5 - cam.pos.x * cam.zoom, sh * 0.5 - cam.pos.y * cam.zoom}
	g.world_view_scale  = scale
	g.world_view_offset = offset
	shapes_set_view(&g.shapes, scale, offset)
}

gfx_clear_camera :: proc(g: ^Graphics) {
	shapes_set_view(&g.shapes, {1, 1}, {0, 0})
}

gfx_end :: proc(g: ^Graphics) {
	pass := sg.Pass{
		swapchain = sglue.swapchain(),
		action    = sg.Pass_Action{
			colors = {
				0 = {
					load_action = .CLEAR,
					clear_value = {
						g.renderer.clear_color.r,
						g.renderer.clear_color.g,
						g.renderer.clear_color.b,
						g.renderer.clear_color.a,
					},
				},
			},
		},
	}
	sg.begin_pass(pass)

	background_record(&g.bg, g.renderer, g.world_view_scale, g.world_view_offset, g.bg_time)
	shapes_record(&g.shapes, g.renderer)
	text_record(&g.text, g.renderer)

	sg.end_pass()
	sg.commit()
}

gfx_push_scissor :: proc(g: ^Graphics, x, y, w, h: f32) {
	parent := g.scissor_stack[len(g.scissor_stack) - 1]
	nx := i32(x); ny := i32(y); nw := i32(w); nh := i32(h)
	x0 := max(parent[0], nx)
	y0 := max(parent[1], ny)
	x1 := min(parent[0] + parent[2], nx + nw)
	y1 := min(parent[1] + parent[3], ny + nh)
	iw := x1 - x0; if iw < 0 do iw = 0
	ih := y1 - y0; if ih < 0 do ih = 0
	rect := [4]i32{x0, y0, iw, ih}
	append(&g.scissor_stack, rect)
	shapes_set_scissor(&g.shapes, rect)
	text_set_scissor(&g.text, rect)
}

gfx_pop_scissor :: proc(g: ^Graphics) {
	if len(g.scissor_stack) <= 1 do return
	pop(&g.scissor_stack)
	rect := g.scissor_stack[len(g.scissor_stack) - 1]
	shapes_set_scissor(&g.shapes, rect)
	text_set_scissor(&g.text, rect)
}

draw_rect :: proc(g: ^Graphics, x, y, w, h: f32, color: [4]f32) {
	shapes_push_rect(&g.shapes, x, y, w, h, color)
}

draw_circle :: proc(g: ^Graphics, cx, cy, radius: f32, color: [4]f32) {
	shapes_push_circle(&g.shapes, cx, cy, radius, color)
}

draw_line :: proc(g: ^Graphics, ax, ay, bx, by, thickness: f32, color: [4]f32) {
	shapes_push_line(&g.shapes, ax, ay, bx, by, thickness, color)
}

draw_text :: proc(g: ^Graphics, x, y: f32, s: string, color: [4]f32 = {1, 1, 1, 1}, font: Font_Size = .Small) {
	text_push(&g.text, x, y, s, color, font)
}
