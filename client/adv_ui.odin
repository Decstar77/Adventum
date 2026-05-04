package main

import sapp "sokol/app"

LAYOUT_FILL :: f32(-1)

Layout_Kind :: enum {
	Vertical,
	Horizontal,
	Stack,
	Grid,
	Scroll,
}

Layout_Frame :: struct {
	kind:           Layout_Kind,
	cx, cy:         f32,
	cw, ch:         f32,
	cursor:         f32,
	gap_x, gap_y:   f32,
	cols, rows:     int,
	cell_index:     int,
	scroll_off:     ^f32,
	pushed_scissor: bool,
}

UI :: struct {
	mouse:           [2]f32,
	mouse_down:      bool,
	mouse_was_down:  bool,
	rmb_down:        bool,
	rmb_was_down:    bool,
	scroll_dy:       f32,
	scroll_accum:    f32,
	layouts:         [dynamic]Layout_Frame,
}

ui_init :: proc(ui: ^UI) {}

ui_shutdown :: proc(ui: ^UI) {
	delete(ui.layouts)
}

ui_handle_event :: proc(ui: ^UI, ev: ^sapp.Event) {
	#partial switch ev.type {
	case .MOUSE_MOVE:
		ui.mouse = {ev.mouse_x, ev.mouse_y}
	case .MOUSE_DOWN:
		ui.mouse = {ev.mouse_x, ev.mouse_y}
		#partial switch ev.mouse_button {
		case .LEFT:  ui.mouse_down = true
		case .RIGHT: ui.rmb_down = true
		}
	case .MOUSE_UP:
		ui.mouse = {ev.mouse_x, ev.mouse_y}
		#partial switch ev.mouse_button {
		case .LEFT:  ui.mouse_down = false
		case .RIGHT: ui.rmb_down = false
		}
	case .MOUSE_SCROLL:
		ui.scroll_accum += ev.scroll_y
	}
}

ui_update :: proc(ui: ^UI) {
	ui.mouse_was_down = ui.mouse_down
	ui.rmb_was_down   = ui.rmb_down
	ui.scroll_dy      = ui.scroll_accum
	ui.scroll_accum   = 0
	clear(&ui.layouts)
}

// Edge state read at end of frame (after game logic). Kept simple:
ui_post_update :: proc(ui: ^UI) {
	ui.mouse_was_down = ui.mouse_down
	ui.rmb_was_down   = ui.rmb_down
}

ui_mouse_released :: proc(ui: ^UI) -> bool {
	return !ui.mouse_down && ui.mouse_was_down
}

ui_mouse_just_pressed :: proc(ui: ^UI) -> bool {
	return ui.mouse_down && !ui.mouse_was_down
}

ui_rmb_just_pressed :: proc(ui: ^UI) -> bool {
	return ui.rmb_down && !ui.rmb_was_down
}

point_in_rect :: proc(p: [2]f32, x, y, w, h: f32) -> bool {
	return p.x >= x && p.x <= x + w && p.y >= y && p.y <= y + h
}

ui_begin_vertical :: proc(ui: ^UI, x, y, w, h: f32, gap: f32 = 0, padding: [4]f32 = {}) {
	append(&ui.layouts, Layout_Frame{
		kind  = .Vertical,
		cx    = x + padding[0],
		cy    = y + padding[1],
		cw    = w - padding[0] - padding[2],
		ch    = h - padding[1] - padding[3],
		gap_y = gap,
	})
}

ui_begin_horizontal :: proc(ui: ^UI, x, y, w, h: f32, gap: f32 = 0, padding: [4]f32 = {}) {
	append(&ui.layouts, Layout_Frame{
		kind  = .Horizontal,
		cx    = x + padding[0],
		cy    = y + padding[1],
		cw    = w - padding[0] - padding[2],
		ch    = h - padding[1] - padding[3],
		gap_x = gap,
	})
}

ui_begin_stack :: proc(ui: ^UI, x, y, w, h: f32, padding: [4]f32 = {}) {
	append(&ui.layouts, Layout_Frame{
		kind = .Stack,
		cx   = x + padding[0],
		cy   = y + padding[1],
		cw   = w - padding[0] - padding[2],
		ch   = h - padding[1] - padding[3],
	})
}

ui_begin_grid :: proc(ui: ^UI, x, y, w, h: f32, cols, rows: int, gap_x: f32 = 0, gap_y: f32 = 0, padding: [4]f32 = {}) {
	c := cols; if c < 1 do c = 1
	r := rows; if r < 1 do r = 1
	append(&ui.layouts, Layout_Frame{
		kind  = .Grid,
		cx    = x + padding[0],
		cy    = y + padding[1],
		cw    = w - padding[0] - padding[2],
		ch    = h - padding[1] - padding[3],
		gap_x = gap_x,
		gap_y = gap_y,
		cols  = c,
		rows  = r,
	})
}

ui_begin_scroll :: proc(ui: ^UI, g: ^Graphics, x, y, w, h: f32, content_h: f32, offset: ^f32, gap: f32 = 0, padding: [4]f32 = {}) {
	visible_h := h - padding[1] - padding[3]

	if point_in_rect(ui.mouse, x, y, w, h) && ui.scroll_dy != 0 {
		offset^ -= ui.scroll_dy * 32
	}
	max_off := content_h - visible_h
	if max_off < 0 do max_off = 0
	if offset^ < 0 do offset^ = 0
	if offset^ > max_off do offset^ = max_off

	gfx_push_scissor(g, x, y, w, h)

	append(&ui.layouts, Layout_Frame{
		kind           = .Scroll,
		cx             = x + padding[0],
		cy             = y + padding[1] - offset^,
		cw             = w - padding[0] - padding[2],
		ch             = content_h,
		gap_y          = gap,
		scroll_off     = offset,
		pushed_scissor = true,
	})
}

ui_end :: proc(ui: ^UI, g: ^Graphics) {
	n := len(ui.layouts)
	if n == 0 do return
	f := ui.layouts[n-1]
	if f.pushed_scissor do gfx_pop_scissor(g)
	pop(&ui.layouts)
}

ui_slot :: proc(ui: ^UI, w: f32 = LAYOUT_FILL, h: f32 = LAYOUT_FILL) -> (rx, ry, rw, rh: f32) {
	n := len(ui.layouts)
	if n == 0 do return
	f := &ui.layouts[n-1]
	switch f.kind {
	case .Vertical, .Scroll:
		rw = w == LAYOUT_FILL ? f.cw : w
		remaining := f.ch - f.cursor
		if remaining < 0 do remaining = 0
		rh = h == LAYOUT_FILL ? remaining : h
		rx = f.cx
		ry = f.cy + f.cursor
		f.cursor += rh + f.gap_y
	case .Horizontal:
		remaining := f.cw - f.cursor
		if remaining < 0 do remaining = 0
		rw = w == LAYOUT_FILL ? remaining : w
		rh = h == LAYOUT_FILL ? f.ch : h
		rx = f.cx + f.cursor
		ry = f.cy
		f.cursor += rw + f.gap_x
	case .Stack:
		rw = w == LAYOUT_FILL ? f.cw : w
		rh = h == LAYOUT_FILL ? f.ch : h
		rx = f.cx
		ry = f.cy
	case .Grid:
		cell_w := (f.cw - f.gap_x * f32(f.cols - 1)) / f32(f.cols)
		cell_h := (f.ch - f.gap_y * f32(f.rows - 1)) / f32(f.rows)
		col := f.cell_index % f.cols
		row := f.cell_index / f.cols
		rx = f.cx + f32(col) * (cell_w + f.gap_x)
		ry = f.cy + f32(row) * (cell_h + f.gap_y)
		rw = cell_w
		rh = cell_h
		f.cell_index += 1
	}
	return
}

ui_button_at :: proc(ui: ^UI, g: ^Graphics, label: string, x, y, w, h: f32) -> bool {
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

ui_button_slot :: proc(ui: ^UI, g: ^Graphics, label: string, w: f32 = LAYOUT_FILL, h: f32 = LAYOUT_FILL) -> bool {
	x, y, w_, h_ := ui_slot(ui, w, h)
	return ui_button_at(ui, g, label, x, y, w_, h_)
}

ui_button :: proc{ui_button_at, ui_button_slot}
