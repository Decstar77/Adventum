package common

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

// Opaque, host-assigned texture handle. 0 is the invalid/not-loaded sentinel,
// so a zero-valued field reads as "no texture" without any explicit init.
Texture :: distinct u32

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
	Emp,
	Sell,
	Repair,
	Upgrade,
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
	// Host writes true while the window is in fullscreen (borderless on win32,
	// Fullscreen API on web). Edge scrolling gates on this — in windowed mode
	// the cursor can naturally leave the window, so the edge zone would pan
	// every time the player reached for another app.
	is_fullscreen:      bool,

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

	// Pixel-art textures. `path` is relative to the game's res/ folder (e.g.
	// "Guns/Pistols/Outlined/1Pistol01.png"); the host prefixes its own asset
	// root. Textures sample nearest-neighbour so pixel art stays crisp scaled
	// up. `load_texture` returns 0 on failure. On the web host the decode is
	// async — the handle is valid immediately but `texture_size` reads {0,0}
	// and `draw_texture` is a no-op until the image finishes loading.
	//
	// `draw_texture` fills the dest rect (x,y,w,h) in the same coordinate space
	// as draw_rect — world space under an active camera, else screen space —
	// with the texture multiplied by `tint` ({1,1,1,1} leaves it unmodified).
	load_texture:  proc(p: ^Platform, path: string) -> Texture,
	texture_size:  proc(p: ^Platform, tex: Texture) -> [2]f32,
	draw_texture:  proc(p: ^Platform, tex: Texture, x, y, w, h: f32, tint: [4]f32),

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

	// Embedded-host hooks (CrazyGames). No-ops on win32.
	//   request_midgame_ad — fired once on the rising edge of game_over so the
	//     SDK can show an interstitial between runs. The game-over screen is
	//     already up by the time this fires, so the ad never interrupts play.
	//   request_happytime  — fired once on victory; lets the SDK notify the
	//     player's friends / surface a "you won!" moment per CG guidelines.
	request_midgame_ad: proc(p: ^Platform),
	request_happytime:  proc(p: ^Platform),

	// Lifecycle hint for embedded hosts (e.g. CrazyGames gameplayStart/Stop,
	// ad SDKs). The game writes this each frame: true while the player is in
	// an active run, false while paused, on a game-over/victory screen, or
	// before the first frame. Hosts edge-detect on changes; setting it every
	// frame to the same value is cheap.
	gameplay_active: bool,

	// Simple key/value persistence. `key` is a UTF-8 string; the host stores
	// it across sessions (CrazyGames cloud save when available with a
	// localStorage fallback in the browser; no-op on win32 for now).
	save_f32: proc(p: ^Platform, key: string, value: f32),
	load_f32: proc(p: ^Platform, key: string, default_value: f32) -> f32,

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
	// Toggle a looping sound on/off and update its world-space emit position.
	// Idempotent on the active flag: calling with the state the loop is already
	// in is a no-op for start/stop, so the game can drive this from a per-frame
	// "is anything still firing?" boolean without bookkeeping. Position is
	// re-applied every call while the loop is active so the source tracks the
	// emitter as it (or its centroid) moves.
	set_sound_loop: proc(p: ^Platform, sound: Sound, active: bool, x, y: f32),
}
