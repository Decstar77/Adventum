package game

// Platform — the only seam between the game and the host (win32, web, ...).
//
// The host fills in this struct each frame: per-frame state up top, capability
// function pointers below. Game code only ever sees a `^Platform`; it never
// touches GLFW, Vulkan, or any of the renderer types directly.
//
// Use the `->` shorthand at call sites: `p->draw_rect(x, y, w, h, color)`
// desugars to `p.draw_rect(p, x, y, w, h, color)`.

Font_Size :: enum {
	Small,
	Large,
}

Key :: enum {
	Unknown,
	W, A, S, D,
	C, B, R, V,
	Num1, Num2, Num3, Num4, Num5, Num6,
	Escape,
	Enter,
	Left_Shift, Right_Shift,
}

KEY_COUNT :: len(Key)

Platform :: struct {
	user_data: rawptr,

	// Per-frame state (host writes; game reads).
	screen_w, screen_h: f32,
	dt:                 f32, // seconds since last frame
	time:               f32, // seconds since start
	mouse:              [2]f32,
	scroll_dy:          f32,
	mouse_left_down,    mouse_left_pressed:  bool,
	mouse_right_down,   mouse_right_pressed: bool,
	should_close:       bool,

	// Input ----------------------------------------------------------------
	is_key_down:         proc "contextless" (p: ^Platform, key: Key) -> bool,
	is_key_just_pressed: proc "contextless" (p: ^Platform, key: Key) -> bool,

	// Drawing primitives (screen-space unless a camera transform is active).
	draw_rect:    proc(p: ^Platform, x, y, w, h: f32, color: [4]f32),
	draw_circle:  proc(p: ^Platform, cx, cy, r: f32, color: [4]f32),
	draw_line:    proc(p: ^Platform, ax, ay, bx, by, thickness: f32, color: [4]f32),
	draw_text:    proc(p: ^Platform, x, y: f32, s: string, color: [4]f32, font: Font_Size),
	text_measure: proc(p: ^Platform, s: string, font: Font_Size) -> f32,
	font_size_px: proc(p: ^Platform, font: Font_Size) -> f32,

	// View / clipping. set_camera applies a 2D affine: world -> screen via
	// pos*scale + offset. clear_camera resets to identity (screen-space).
	set_camera:   proc(p: ^Platform, scale, offset: [2]f32),
	clear_camera: proc(p: ^Platform),
	push_scissor: proc(p: ^Platform, x, y, w, h: f32),
	pop_scissor:  proc(p: ^Platform),

	// Fog-of-war lighting points (world space). The host draws a soft halo
	// around each one in the background pass, anchored to the world so it pans
	// with the camera. The game pushes one per visible building each frame.
	fog_lights_clear: proc(p: ^Platform),
	fog_lights_push:  proc(p: ^Platform, x, y: f32),

	// Window
	toggle_fullscreen: proc(p: ^Platform),
	request_quit:      proc(p: ^Platform),
}
