package main

import vk "vendor:vulkan"

Graphics :: struct {
	renderer: ^Renderer,
	shapes:   Shape_Renderer,
	text:     Text_Renderer,
	cb:       vk.CommandBuffer,
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
}

gfx_begin :: proc(g: ^Graphics) -> bool {
	cb, ok := renderer_begin_frame(g.renderer)
	if !ok do return false
	g.cb = cb
	return true
}

gfx_end :: proc(g: ^Graphics) {
	shapes_record(&g.shapes, g.renderer, g.cb)
	text_record(&g.text, g.renderer, g.cb)
	renderer_end_frame(g.renderer)
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
