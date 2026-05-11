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

// Sound families. The host owns the actual `.wav` assets and, where there are
// multiple variants of one family (e.g. three turret-shoot recordings), picks
// one at random per call so repeated plays don't sound mechanical.
Sound :: enum {
	None,
	Button_Hover,
	Button_Click,
	Place_Building,
	Building_Explode,
	Turret_Shoot,
	Enemy_Attack,
	Enemy_Die,
	// Looping family — driven by `set_sound_loop` rather than `play_sound`. The
	// underlying wav is designed as a continuous spray, so the host plays a
	// single looped instance that the game toggles on while any flak gun is
	// actively firing and off the moment they all stop.
	Flak_Cannon_Loop,
}

Key :: enum {
	Unknown,
	W, A, S, D,
	C, B, R, V, N, Q, E, F,
	Num1, Num2, Num3, Num4, Num5, Num6, Num7,
	Escape,
	Enter,
	Space,
	Left_Shift, Right_Shift,
	F6, // debug: force the next surge wave immediately
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

	// Audio. Game writes `master_volume` (0..1) each frame; the host applies
	// it to the underlying audio engine. `play_sound` is fire-and-forget —
	// the host is free to overlap copies of the same family.
	//
	// For spatial audio the game also writes the world-space listener position
	// (`listener_x` / `listener_y`) each frame, and emits positional sounds
	// via `play_sound_at`. Non-positional cues (UI clicks, hover) stay on
	// `play_sound`, which the host plays without attenuation or panning.
	master_volume:  f32,
	listener_x:     f32,
	listener_y:     f32,
	play_sound:     proc(p: ^Platform, sound: Sound),
	play_sound_at:  proc(p: ^Platform, sound: Sound, x, y: f32),
	// Toggle a looping sound on/off. Idempotent on both edges: calling with the
	// state the loop is already in is a no-op, so the game can drive this from
	// a per-frame "is anything still firing?" boolean without bookkeeping.
	set_sound_loop: proc(p: ^Platform, sound: Sound, active: bool),
}
