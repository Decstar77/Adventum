package main

import vk "vendor:vulkan"

// Graphics is the win32-side render aggregate. It owns the per-frame state and
// the three sub-renderers (background, shapes, text). The Platform wrapper in
// main.odin drives this via the gfx_*/draw_* helpers below.

Graphics :: struct {
	renderer:           ^Renderer,
	bg:                 Background_Renderer,
	shapes:             Shape_Renderer,
	text:               Text_Renderer,
	cb:                 vk.CommandBuffer,
	scissor_stack:      [dynamic][4]i32,
	world_view_scale:   [2]f32,
	world_view_offset:  [2]f32,
}

gfx_init :: proc(g: ^Graphics, r: ^Renderer) -> bool {
	g.renderer = r
	if !background_init(&g.bg, r) do return false
	if !shapes_init(&g.shapes, r) do return false
	if !text_init(&g.text, r) do return false
	return true
}

gfx_shutdown :: proc(g: ^Graphics) {
	if g.renderer == nil do return
	vk.DeviceWaitIdle(g.renderer.device)
	text_shutdown(&g.text, g.renderer)
	shapes_shutdown(&g.shapes, g.renderer)
	background_shutdown(&g.bg, g.renderer)
	delete(g.scissor_stack)
}

gfx_begin :: proc(g: ^Graphics) -> bool {
	cb, ok := renderer_begin_frame(g.renderer)
	if !ok do return false
	g.cb = cb

	clear(&g.scissor_stack)
	full := [4]i32{
		0, 0,
		i32(g.renderer.swapchain_extent.width),
		i32(g.renderer.swapchain_extent.height),
	}
	append(&g.scissor_stack, full)
	shapes_set_scissor(&g.shapes, full)
	shapes_set_view(&g.shapes, {1, 1}, {0, 0})
	text_set_scissor(&g.text, full)
	g.world_view_scale  = {1, 1}
	g.world_view_offset = {0, 0}
	return true
}

gfx_set_view :: proc(g: ^Graphics, scale, offset: [2]f32) {
	g.world_view_scale  = scale
	g.world_view_offset = offset
	shapes_set_view(&g.shapes, scale, offset)
}

gfx_clear_view :: proc(g: ^Graphics) {
	gfx_set_view(g, {1, 1}, {0, 0})
}

gfx_end :: proc(g: ^Graphics) {
	background_record(&g.bg, g.renderer, g.cb, g.world_view_scale, g.world_view_offset)
	shapes_record(&g.shapes, g.renderer, g.cb)
	text_record(&g.text, g.renderer, g.cb)
	renderer_end_frame(g.renderer)
}

gfx_push_scissor :: proc(g: ^Graphics, x, y, w, h: f32) {
	parent := g.scissor_stack[len(g.scissor_stack) - 1]
	nx := i32(x)
	ny := i32(y)
	nw := i32(w)
	nh := i32(h)
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

gfx_push_rect :: proc(g: ^Graphics, x, y, w, h: f32, color: [4]f32) {
	shapes_push_rect(&g.shapes, x, y, w, h, color)
}

gfx_push_circle :: proc(g: ^Graphics, cx, cy, radius: f32, color: [4]f32) {
	shapes_push_circle(&g.shapes, cx, cy, radius, color)
}

gfx_push_line :: proc(g: ^Graphics, ax, ay, bx, by, thickness: f32, color: [4]f32) {
	shapes_push_line(&g.shapes, ax, ay, bx, by, thickness, color)
}
