package main

import vk "vendor:vulkan"

Graphics :: struct {
	renderer:      ^Renderer,
	shapes:        Shape_Renderer,
	text:          Text_Renderer,
	cb:            vk.CommandBuffer,
	scissor_stack: [dynamic][4]i32,
}

gfx_init :: proc(g: ^Graphics, r: ^Renderer) -> bool {
	g.renderer = r
	if !shapes_init(&g.shapes, r) do return false
	if !text_init(&g.text, r) do return false
	return true
}

gfx_shutdown :: proc(g: ^Graphics) {
	if g.renderer == nil do return
	vk.DeviceWaitIdle(g.renderer.device)
	text_shutdown(&g.text, g.renderer)
	shapes_shutdown(&g.shapes, g.renderer)
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
	text_set_scissor(&g.text, full)
	return true
}

gfx_end :: proc(g: ^Graphics) {
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

draw_rect :: proc(g: ^Graphics, x, y, w, h: f32, color: [4]f32) {
	shapes_push_rect(&g.shapes, x, y, w, h, color)
}

draw_circle :: proc(g: ^Graphics, cx, cy, radius: f32, color: [4]f32) {
	shapes_push_circle(&g.shapes, cx, cy, radius, color)
}

draw_line :: proc(g: ^Graphics, ax, ay, bx, by, thickness: f32, color: [4]f32) {
	shapes_push_line(&g.shapes, ax, ay, bx, by, thickness, color)
}

draw_text :: proc(g: ^Graphics, x, y: f32, s: string, color: [4]f32 = {1, 1, 1, 1}) {
	text_push(&g.text, x, y, s, color)
}
