package main

// Browser host for Adventum. Same Game/Platform contract as the win32 build —
// the only differences are how drawing primitives reach the screen (HTML5
// Canvas 2D via foreign imports) and how the frame loop is driven (the JS
// host calls `web_frame` from requestAnimationFrame).
//
// Built with `-target:js_wasm32`. The companion `host.js` wires up the
// imports declared below and forwards browser events into `web_key`.

import "base:runtime"
import "../common"
import game "../game2"

foreign import "host"

@(default_calling_convention="contextless")
foreign host {
	js_draw_rect         :: proc(x, y, w, h: f32, r, g, b, a: f32) ---
	js_draw_circle       :: proc(cx, cy, rad: f32, r, g, b, a: f32) ---
	js_draw_line         :: proc(ax, ay, bx, by, t: f32, r, g, b, a: f32) ---
	js_draw_text         :: proc(x, y: f32, ptr: rawptr, len: i32, r, g, b, a: f32, font: i32) ---
	js_text_measure      :: proc(ptr: rawptr, len: i32, font: i32) -> f32 ---
	// Pixel-art textures. `js_load_texture` kicks off an async Image load and
	// returns a 1-based handle immediately; `js_texture_w/h` read 0 until the
	// decode finishes, and `js_draw_texture` is a no-op while not ready. RGB
	// tint is ignored on the canvas path (alpha is applied via globalAlpha).
	js_load_texture      :: proc(ptr: rawptr, len: i32) -> i32 ---
	js_texture_w         :: proc(tex: i32) -> f32 ---
	js_texture_h         :: proc(tex: i32) -> f32 ---
	js_draw_texture      :: proc(tex: i32, x, y, w, h: f32, r, g, b, a: f32) ---
	js_set_camera        :: proc(sx, sy, ox, oy: f32) ---
	js_clear_camera      :: proc() ---
	js_push_scissor      :: proc(x, y, w, h: f32) ---
	js_pop_scissor       :: proc() ---
	js_toggle_fullscreen :: proc() ---
	js_request_quit      :: proc() ---
	// Audio. Sound is identified by its `common.Sound` enum index; the JS host
	// owns the per-family variant lists and picks one at random per call.
	// miniaudio compiled to wasm could replace this in future, but the browser's
	// HTMLAudioElement is sufficient for fire-and-forget SFX and avoids pulling
	// the C library through emscripten.
	js_play_sound        :: proc(sound: i32) ---
	js_play_sound_at     :: proc(sound: i32, x, y: f32) ---
	js_set_sound_loop    :: proc(sound: i32, active: i32, x, y: f32) ---
	js_set_listener      :: proc(x, y: f32) ---
	js_set_master_volume :: proc(v: f32) ---
	// Fog-of-war lights drive the background shader (host.js renderBackground).
	// World-space coordinates; the host transforms them with the latched
	// camera so they pan/zoom with the scene.
	js_fog_lights_clear  :: proc() ---
	js_fog_lights_push   :: proc(x, y: f32) ---
	// CrazyGames SDK lifecycle hint. Host edge-detects on the boolean and
	// calls gameplayStart() / gameplayStop().
	js_set_gameplay_active :: proc(active: i32) ---
	// CrazyGames midgame ad + happytime. The host gates both on SDK readiness
	// and falls back to a no-op when the SDK isn't loaded (local dev server).
	js_request_midgame_ad  :: proc() ---
	js_request_happytime   :: proc() ---
	// Persistence. Host writes via CrazyGames SDK cloud save with a
	// localStorage fallback; reads with the same fallback chain.
	js_save_f32          :: proc(key_ptr: rawptr, key_len: i32, value: f32) ---
	js_load_f32          :: proc(key_ptr: rawptr, key_len: i32, default_value: f32) -> f32 ---
}

App :: struct {
	keys_down:     [common.KEY_COUNT]bool,
	keys_was_down: [common.KEY_COUNT]bool,
}

@(private="file") g_app:      App
@(private="file") g_game:     game.Game
@(private="file") g_platform: common.Platform
@(private="file") g_started:  bool

// Odin's `js_wasm32` build needs a main proc; the browser drives the loop via
// requestAnimationFrame, so this is just a stub. JS calls `web_init` once.
main :: proc() {}

@(export)
web_init :: proc "c" () {
	context = runtime.default_context()
	if g_started do return
	g_platform = make_platform()
	game.game_init(&g_game, &g_platform)
	g_started = true
}

// Called from JS when the browser tab loses focus or becomes hidden. game2 has
// no pause state yet, so this is a no-op for now — the dt clamp in host.js's
// frame loop already guards against the huge-dt jump on the frame after a tab
// regains focus. Wire a pause here once game2 grows a run/pause concept.
@(export)
web_blur :: proc "c" () {
	context = runtime.default_context()
	if !g_started do return
}

// Called from JS keydown/keyup. `down` is 1 for press, 0 for release.
@(export)
web_key :: proc "c" (key: i32, down: i32) {
	if key <= 0 || key >= common.KEY_COUNT do return
	g_app.keys_down[key] = down != 0
}

@(export)
web_frame :: proc "c" (
	dt, t, sw, sh: f32,
	mx, my, scroll_dy: f32,
	mouse_left, mouse_right: i32,
	is_fullscreen: i32,
) {
	context = runtime.default_context()
	if !g_started do return

	g_platform.dt        = dt
	g_platform.time      = t
	g_platform.screen_w  = sw
	g_platform.screen_h  = sh
	g_platform.mouse     = {mx, my}
	g_platform.scroll_dy = scroll_dy

	new_left  := mouse_left  != 0
	new_right := mouse_right != 0
	g_platform.mouse_left_pressed  = new_left  && !g_platform.mouse_left_down
	g_platform.mouse_right_pressed = new_right && !g_platform.mouse_right_down
	g_platform.mouse_left_down  = new_left
	g_platform.mouse_right_down = new_right
	g_platform.is_fullscreen    = is_fullscreen != 0

	game.game_update_and_render(&g_game, &g_platform)

	// Mirror the game's current volume into the JS host so the slider drives
	// the audio level without any extra plumbing. Listener position pairs
	// with `js_play_sound_at` for spatial panning/attenuation.
	js_set_master_volume(g_platform.master_volume)
	js_set_listener(g_platform.listener_x, g_platform.listener_y)
	// Lifecycle hint for the CrazyGames SDK (gameplayStart/Stop edge-detected
	// host-side). Cheap to push every frame.
	js_set_gameplay_active(g_platform.gameplay_active ? 1 : 0)

	// Edge-detect at end of frame: events that arrive between frames update
	// keys_down only — keys_was_down still reflects last frame, so the first
	// poll of just_pressed in the next frame fires correctly.
	g_app.keys_was_down = g_app.keys_down

	free_all(context.temp_allocator)
}

make_platform :: proc() -> common.Platform {
	return common.Platform{
		is_key_down         = plat_is_key_down,
		is_key_just_pressed = plat_is_key_just_pressed,
		draw_rect           = plat_draw_rect,
		draw_circle         = plat_draw_circle,
		draw_line           = plat_draw_line,
		draw_text           = plat_draw_text,
		text_measure        = plat_text_measure,
		font_size_px        = plat_font_size_px,
		load_texture        = plat_load_texture,
		texture_size        = plat_texture_size,
		draw_texture        = plat_draw_texture,
		set_camera          = plat_set_camera,
		clear_camera        = plat_clear_camera,
		push_scissor        = plat_push_scissor,
		pop_scissor         = plat_pop_scissor,
		fog_lights_clear    = plat_fog_lights_clear,
		fog_lights_push     = plat_fog_lights_push,
		toggle_fullscreen   = plat_toggle_fullscreen,
		request_quit        = plat_request_quit,
		request_midgame_ad  = plat_request_midgame_ad,
		request_happytime   = plat_request_happytime,
		play_sound          = plat_play_sound,
		play_sound_at       = plat_play_sound_at,
		set_sound_loop      = plat_set_sound_loop,
		save_f32            = plat_save_f32,
		load_f32            = plat_load_f32,
	}
}

@(private="file")
plat_save_f32 :: proc(p: ^common.Platform, key: string, value: f32) {
	js_save_f32(raw_data(key), i32(len(key)), value)
}

@(private="file")
plat_load_f32 :: proc(p: ^common.Platform, key: string, default_value: f32) -> f32 {
	return js_load_f32(raw_data(key), i32(len(key)), default_value)
}

@(private="file")
plat_play_sound :: proc(p: ^common.Platform, sound: common.Sound) {
	js_play_sound(i32(sound))
}

@(private="file")
plat_play_sound_at :: proc(p: ^common.Platform, sound: common.Sound, x, y: f32) {
	js_play_sound_at(i32(sound), x, y)
}

@(private="file")
plat_set_sound_loop :: proc(p: ^common.Platform, sound: common.Sound, active: bool, x, y: f32) {
	js_set_sound_loop(i32(sound), active ? 1 : 0, x, y)
}

@(private="file")
plat_fog_lights_clear :: proc(p: ^common.Platform) { js_fog_lights_clear() }
@(private="file")
plat_fog_lights_push  :: proc(p: ^common.Platform, x, y: f32) { js_fog_lights_push(x, y) }

@(private="file")
plat_is_key_down :: proc "contextless" (p: ^common.Platform, key: common.Key) -> bool {
	idx := int(key)
	if idx < 0 || idx >= common.KEY_COUNT do return false
	return g_app.keys_down[idx]
}

@(private="file")
plat_is_key_just_pressed :: proc "contextless" (p: ^common.Platform, key: common.Key) -> bool {
	idx := int(key)
	if idx < 0 || idx >= common.KEY_COUNT do return false
	return g_app.keys_down[idx] && !g_app.keys_was_down[idx]
}

@(private="file")
plat_draw_rect :: proc(p: ^common.Platform, x, y, w, h: f32, color: [4]f32) {
	js_draw_rect(x, y, w, h, color[0], color[1], color[2], color[3])
}

@(private="file")
plat_draw_circle :: proc(p: ^common.Platform, cx, cy, r: f32, color: [4]f32) {
	js_draw_circle(cx, cy, r, color[0], color[1], color[2], color[3])
}

@(private="file")
plat_draw_line :: proc(p: ^common.Platform, ax, ay, bx, by, t: f32, color: [4]f32) {
	js_draw_line(ax, ay, bx, by, t, color[0], color[1], color[2], color[3])
}

@(private="file")
plat_draw_text :: proc(p: ^common.Platform, x, y: f32, s: string, color: [4]f32, font: common.Font_Size) {
	js_draw_text(x, y, raw_data(s), i32(len(s)), color[0], color[1], color[2], color[3], i32(font))
}

@(private="file")
plat_text_measure :: proc(p: ^common.Platform, s: string, font: common.Font_Size) -> f32 {
	return js_text_measure(raw_data(s), i32(len(s)), i32(font))
}

@(private="file")
plat_font_size_px :: proc(p: ^common.Platform, font: common.Font_Size) -> f32 {
	switch font {
	case .Small: return 16
	case .Large: return 32
	}
	return 16
}

@(private="file")
plat_load_texture :: proc(p: ^common.Platform, path: string) -> common.Texture {
	return common.Texture(js_load_texture(raw_data(path), i32(len(path))))
}

@(private="file")
plat_texture_size :: proc(p: ^common.Platform, tex: common.Texture) -> [2]f32 {
	return {js_texture_w(i32(tex)), js_texture_h(i32(tex))}
}

@(private="file")
plat_draw_texture :: proc(p: ^common.Platform, tex: common.Texture, x, y, w, h: f32, tint: [4]f32) {
	js_draw_texture(i32(tex), x, y, w, h, tint[0], tint[1], tint[2], tint[3])
}

@(private="file")
plat_set_camera :: proc(p: ^common.Platform, scale, offset: [2]f32) {
	js_set_camera(scale[0], scale[1], offset[0], offset[1])
}

@(private="file")
plat_clear_camera :: proc(p: ^common.Platform) { js_clear_camera() }

@(private="file")
plat_push_scissor :: proc(p: ^common.Platform, x, y, w, h: f32) { js_push_scissor(x, y, w, h) }

@(private="file")
plat_pop_scissor :: proc(p: ^common.Platform) { js_pop_scissor() }

@(private="file")
plat_toggle_fullscreen :: proc(p: ^common.Platform) { js_toggle_fullscreen() }

@(private="file")
plat_request_quit :: proc(p: ^common.Platform) { js_request_quit() }

@(private="file")
plat_request_midgame_ad :: proc(p: ^common.Platform) { js_request_midgame_ad() }

@(private="file")
plat_request_happytime :: proc(p: ^common.Platform) { js_request_happytime() }
