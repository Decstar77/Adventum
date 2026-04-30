package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"

LOG_MAX_ENTRIES :: 512
LOG_TOAST_LIFETIME :: f32(5.0)
LOG_TOAST_FADE :: f32(1.0)
LOG_PADDING :: f32(8)
LOG_SCROLLBAR_W :: f32(6)
LOG_OPEN_SPEED :: f32(10) // 1/seconds (exponential approach)
LOG_MAX_TOASTS :: 8

LogLevel :: enum {
	INFO,
	WARN,
	ERROR,
}

LogEntry :: struct {
	msg:   string, // owned
	time:  f64,
	level: LogLevel,
}

log_entries: [LOG_MAX_ENTRIES]LogEntry
log_head: int // next slot to write
log_total: int // total ever written

log_console_open: bool
log_console_anim: f32 // 0 = closed, 1 = fully open
log_scroll_y: f32 // pixels from bottom (0 = newest at bottom)
log_last_time: f64

log_push :: proc(level: LogLevel, msg: string) {
	fmt.println(msg)

	idx := log_head
	if log_total >= LOG_MAX_ENTRIES {
		delete(log_entries[idx].msg)
	}
	log_entries[idx] = LogEntry {
		msg   = strings.clone(msg),
		time  = seconds_since_init(),
		level = level,
	}
	log_head = (log_head + 1) % LOG_MAX_ENTRIES
	log_total += 1
}

log_info :: proc(args: ..any) {
	s := fmt.tprint(..args)
	log_push(.INFO, s)
}

log_warn :: proc(args: ..any) {
	s := fmt.tprint(..args)
	log_push(.WARN, s)
}

log_err :: proc(args: ..any) {
	s := fmt.tprint(..args)
	log_push(.ERROR, s)
}

log_infof :: proc(format: string, args: ..any) {
	s := fmt.tprintf(format, ..args)
	log_push(.INFO, s)
}

log_warnf :: proc(format: string, args: ..any) {
	s := fmt.tprintf(format, ..args)
	log_push(.WARN, s)
}

log_errf :: proc(format: string, args: ..any) {
	s := fmt.tprintf(format, ..args)
	log_push(.ERROR, s)
}

log_count :: proc() -> int {
	return min(log_total, LOG_MAX_ENTRIES)
}

// age 0 = newest entry
log_get :: proc(age: int) -> LogEntry {
	n := log_count()
	if age < 0 || age >= n {return {}}
	idx := (log_head - 1 - age + LOG_MAX_ENTRIES * 2) % LOG_MAX_ENTRIES
	return log_entries[idx]
}

log_toggle_console :: proc() {
	log_console_open = !log_console_open
	if !log_console_open {
		log_scroll_y = 0
	}
}

log_handle_scroll :: proc(delta_y: f32) {
	if !log_console_open {return}
	line_h := f32(font.font_height)
	log_scroll_y += delta_y * line_h * 3
	if log_scroll_y < 0 {log_scroll_y = 0}
}

log_color :: proc(level: LogLevel) -> v4 {
	switch level {
	case .INFO:
		return v4{0.92, 0.92, 0.92, 1}
	case .WARN:
		return v4{1.00, 0.85, 0.40, 1}
	case .ERROR:
		return v4{1.00, 0.45, 0.45, 1}
	}
	return COLOR_WHITE
}

log_render :: proc() {
	now := seconds_since_init()
	dt := f32(now - log_last_time)
	if log_last_time == 0 || dt > 0.25 {dt = 1.0 / 60.0}
	log_last_time = now

	target: f32 = log_console_open ? 1 : 0
	step := math.min(f32(1), LOG_OPEN_SPEED * dt)
	log_console_anim += (target - log_console_anim) * step
	if math.abs(target - log_console_anim) < 0.001 {log_console_anim = target}

	// install GUI-space projection (pixel coords, Y-up, origin bottom-left)
	saved_proj := draw_frame.projection
	saved_cam := draw_frame.camera_xform

	w := f32(window_w)
	h := f32(window_h)
	draw_frame.projection = linalg.matrix_ortho3d_f32(0, w, 0, h, -1, 1)
	draw_frame.camera_xform = Matrix4(1)

	line_h := f32(font.font_height)

	if log_console_anim > 0.001 {
		log_render_console(w, h, line_h)
	}

	if log_console_anim < 0.999 {
		log_render_toasts(w, h, line_h, now)
	}

	draw_frame.projection = saved_proj
	draw_frame.camera_xform = saved_cam
}

log_render_console :: proc(w, h, line_h: f32) {
	// panel slides down from above the screen — anim=1 covers full window
	panel_top := h
	panel_bottom := h * (1 - log_console_anim)

	bg := v4{0.05, 0.05, 0.07, 0.92 * log_console_anim}
	draw_rect_aabb(v2{0, panel_bottom}, v2{w, panel_top}, col = bg)

	pad := LOG_PADDING
	text_left := pad
	text_top := panel_top - pad
	text_bottom := panel_bottom + pad
	track_x := w - pad - LOG_SCROLLBAR_W
	visible_h := text_top - text_bottom
	if visible_h <= 0 {return}

	n := log_count()
	content_h := f32(n) * line_h

	max_scroll: f32 = 0
	if content_h > visible_h {max_scroll = content_h - visible_h}
	if log_scroll_y > max_scroll {log_scroll_y = max_scroll}

	// newest at the bottom of the visible area; older lines stack upwards.
	for age in 0 ..< n {
		y := text_bottom + log_scroll_y + f32(age) * line_h
		if y > text_top {break}
		if y + line_h < text_bottom {continue}
		entry := log_get(age)
		col := log_color(entry.level)
		col.a *= log_console_anim
		draw_text(v2{text_left, y}, entry.msg, scale = 1.0, col = col)
	}

	if content_h > visible_h {
		track_top := text_top
		track_bottom := text_bottom
		track_h := track_top - track_bottom
		draw_rect_aabb(
			v2{track_x, track_bottom},
			v2{track_x + LOG_SCROLLBAR_W, track_top},
			col = v4{1, 1, 1, 0.10 * log_console_anim},
		)

		thumb_h := math.max(line_h, track_h * (visible_h / content_h))
		t := log_scroll_y / max_scroll
		thumb_bottom := track_bottom + (track_h - thumb_h) * t
		draw_rect_aabb(
			v2{track_x, thumb_bottom},
			v2{track_x + LOG_SCROLLBAR_W, thumb_bottom + thumb_h},
			col = v4{1, 1, 1, 0.55 * log_console_anim},
		)
	}
}

log_render_toasts :: proc(w, h, line_h: f32, now: f64) {
	fade_mult := 1 - log_console_anim
	y := h - LOG_PADDING - line_h
	n := log_count()
	limit := math.min(n, LOG_MAX_TOASTS)
	for age in 0 ..< limit {
		entry := log_get(age)
		age_s := f32(now - entry.time)
		if age_s > LOG_TOAST_LIFETIME {break}

		alpha: f32 = 1
		if age_s > LOG_TOAST_LIFETIME - LOG_TOAST_FADE {
			alpha = (LOG_TOAST_LIFETIME - age_s) / LOG_TOAST_FADE
		}

		col := log_color(entry.level)
		col.a *= alpha * fade_mult
		draw_text(v2{LOG_PADDING, y}, entry.msg, scale = 1.0, col = col)
		y -= line_h
		if y < 0 {break}
	}
}
