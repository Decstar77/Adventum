package main

import "vendor:glfw"

UI :: struct {
	mouse:          [2]f32,
	mouse_down:     bool,
	mouse_was_down: bool,
}

ui_update :: proc(ui: ^UI, window: glfw.WindowHandle) {
	x, y := glfw.GetCursorPos(window)
	ui.mouse = {f32(x), f32(y)}
	ui.mouse_was_down = ui.mouse_down
	ui.mouse_down = glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS
}

ui_mouse_released :: proc(ui: ^UI) -> bool {
	return !ui.mouse_down && ui.mouse_was_down
}

ui_mouse_just_pressed :: proc( ui: ^UI ) -> bool {
	return ui.mouse_down && !ui.mouse_was_down
}

point_in_rect :: proc(p: [2]f32, x, y, w, h: f32) -> bool {
	return p.x >= x && p.x <= x + w && p.y >= y && p.y <= y + h
}

ui_button :: proc(ui: ^UI, g: ^Graphics, label: string, x, y, w, h: f32) -> bool {
	hover := point_in_rect(ui.mouse, x, y, w, h)
	held  := hover && ui.mouse_down

	BASE  := [4]f32{0.18, 0.20, 0.26, 1.0}
	HOVER := [4]f32{0.26, 0.30, 0.40, 1.0}
	HELD  := [4]f32{0.10, 0.12, 0.16, 1.0}

	bg := BASE
	if held       do bg = HELD
	else if hover do bg = HOVER

	draw_rect(g, x, y, w, h, bg)
	draw_line(g, x,     y,     x + w, y,     1, {1, 1, 1, 0.15})
	draw_line(g, x,     y + h, x + w, y + h, 1, {0, 0, 0, 0.40})

	tw := text_measure(&g.text, label)
	tx := x + (w - tw) * 0.5
	ty := y + h * 0.5 + FONT_PIXEL_SIZE * 0.3
	draw_text(g, tx, ty, label, {1, 1, 1, 1})

	return hover && ui_mouse_just_pressed(ui)
}
