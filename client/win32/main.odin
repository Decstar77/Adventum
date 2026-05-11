package main

import "core:fmt"
import "core:os"
import "core:time"
import "vendor:glfw"
import win "core:sys/windows"

import "../game"

// Win32/GLFW/Vulkan host. Owns the window, the Vulkan renderer, the input
// snapshot, and a Platform of function pointers it hands to the game each
// frame. The game never sees this file.

App :: struct {
	window:   glfw.WindowHandle,
	renderer: Renderer,
	graphics: Graphics,
	audio:    Audio,

	// Input snapshot built up by GLFW callbacks; sampled into Platform fields
	// once per frame.
	keys_down:        [game.KEY_COUNT]bool,
	keys_was_down:    [game.KEY_COUNT]bool,
	scroll_accum:     f64,
	mouse:            [2]f32,
	mouse_left_down,  mouse_left_was_down:  bool,
	mouse_right_down, mouse_right_was_down: bool,

	// Fullscreen toggle state.
	is_fullscreen:                                bool,
	windowed_x, windowed_y, windowed_w, windowed_h: i32,

	should_quit: bool,
}

// File-private singleton so GLFW's `"c"` callbacks can find their state. The
// userdata pointer on the window already points at this; we duplicate it here
// for callbacks that take other handles (the scroll callback, in particular).
@(private="file") g_app: ^App

main :: proc() {
	if !bool(glfw.Init()) {
		fmt.eprintln("failed to init GLFW")
		os.exit(1)
	}
	defer glfw.Terminate()

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, 0)

	window := glfw.CreateWindow(1280, 720, "Adventum", nil, nil)
	if window == nil {
		fmt.eprintln("failed to create window")
		os.exit(1)
	}
	defer glfw.DestroyWindow(window)

	app := App{
		window           = window,
		windowed_w       = 1280,
		windowed_h       = 720,
	}
	g_app = &app
	glfw.SetWindowUserPointer(window, &app)
	glfw.SetKeyCallback(window, key_cb)
	glfw.SetScrollCallback(window, scroll_cb)

	if !renderer_init(&app.renderer, window) {
		fmt.eprintln("failed to init renderer")
		os.exit(1)
	}
	defer renderer_shutdown(&app.renderer)

	if !gfx_init(&app.graphics, &app.renderer) {
		fmt.eprintln("failed to init graphics")
		os.exit(1)
	}
	defer gfx_shutdown(&app.graphics)

	// Audio init failure is non-fatal — the game runs silently.
	if !audio_init(&app.audio) {
		fmt.eprintln("audio disabled")
	}
	defer audio_shutdown(&app.audio)

	// Build the Platform once; per-frame state is refreshed at the top of the
	// loop, fn pointers stay constant.
	platform := game.Platform{
		user_data           = &app,
		is_key_down         = plat_is_key_down,
		is_key_just_pressed = plat_is_key_just_pressed,
		draw_rect           = plat_draw_rect,
		draw_circle         = plat_draw_circle,
		draw_line           = plat_draw_line,
		draw_text           = plat_draw_text,
		text_measure        = plat_text_measure,
		font_size_px        = plat_font_size_px,
		set_camera          = plat_set_camera,
		clear_camera        = plat_clear_camera,
		push_scissor        = plat_push_scissor,
		pop_scissor         = plat_pop_scissor,
		fog_lights_clear    = plat_fog_lights_clear,
		fog_lights_push     = plat_fog_lights_push,
		toggle_fullscreen   = plat_toggle_fullscreen,
		request_quit        = plat_request_quit,
		play_sound          = plat_play_sound,
		play_sound_at       = plat_play_sound_at,
		set_sound_loop      = plat_set_sound_loop,
	}

	g: game.Game
	game.game_init(&g)
	defer game.game_shutdown(&g)

	monitor := glfw.GetPrimaryMonitor()
	vid_mode := glfw.GetVideoMode(monitor)
	refresh_hz := vid_mode != nil ? i32(vid_mode.refresh_rate) : 60
	if refresh_hz <= 0 do refresh_hz = 60
	fmt.printfln("monitor: %dx%d @ %dHz",
		vid_mode != nil ? vid_mode.width  : 0,
		vid_mode != nil ? vid_mode.height : 0,
		refresh_hz)

	target_dt := 1.0 / f64(refresh_hz)
	win.timeBeginPeriod(1)
	defer win.timeEndPeriod(1)

	last_time := glfw.GetTime()
	start_time := last_time

	for !glfw.WindowShouldClose(window) && !app.should_quit {
		now := glfw.GetTime()
		frame_dt := now - last_time
		last_time = now

		// Sample input edges by snapshotting the current "down" arrays before
		// PollEvents runs the callbacks.
		app.keys_was_down       = app.keys_down
		app.mouse_left_was_down  = app.mouse_left_down
		app.mouse_right_was_down = app.mouse_right_down

		glfw.PollEvents()

		// Mouse position is queried directly (not via callback).
		mx, my := glfw.GetCursorPos(window)
		app.mouse = {f32(mx), f32(my)}
		app.mouse_left_down  = glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_LEFT)  == glfw.PRESS
		app.mouse_right_down = glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_RIGHT) == glfw.PRESS

		scroll_dy := f32(app.scroll_accum)
		app.scroll_accum = 0

		platform.screen_w           = f32(app.renderer.swapchain_extent.width)
		platform.screen_h           = f32(app.renderer.swapchain_extent.height)
		platform.dt                 = f32(frame_dt)
		platform.time               = f32(now - start_time)
		platform.mouse              = app.mouse
		platform.mouse_left_down    = app.mouse_left_down
		platform.mouse_left_pressed = app.mouse_left_down && !app.mouse_left_was_down
		platform.mouse_right_down   = app.mouse_right_down
		platform.mouse_right_pressed = app.mouse_right_down && !app.mouse_right_was_down
		platform.scroll_dy          = scroll_dy
		platform.should_close       = false

		if !gfx_begin(&app.graphics) {
			// Lost the swapchain; the recreate path runs from the fullscreen
			// toggle, otherwise just spin until the next acquire succeeds.
			continue
		}

		game.game_update_and_render(&g, &platform)

		// The game writes its current master volume into the platform each
		// frame; mirror it into the audio engine so the pause-menu slider
		// updates immediately. Also push the listener position so positional
		// plays from this frame's queue pan/attenuate against the latest
		// camera, and sweep any finished positional instances.
		audio_set_master_volume(&app.audio, platform.master_volume)
		audio_set_listener(&app.audio, platform.listener_x, platform.listener_y)
		audio_tick(&app.audio)

		gfx_end(&app.graphics)
		free_all(context.temp_allocator)

		// Manual frame pacing — sleep the remainder of a frame at the monitor's
		// refresh rate. timeBeginPeriod(1) keeps the sleep granularity tight.
		elapsed := glfw.GetTime() - now
		if elapsed < target_dt {
			time.sleep(time.Duration((target_dt - elapsed) * f64(time.Second)))
		}
	}
}

// ---------------------------------------------------------------------------
// GLFW callbacks

@(private="file")
key_cb :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	app := cast(^App)glfw.GetWindowUserPointer(window)
	if app == nil do return
	gk := glfw_key_to_game(key)
	if gk == .Unknown do return
	idx := int(gk)
	switch action {
	case glfw.PRESS:   app.keys_down[idx] = true
	case glfw.RELEASE: app.keys_down[idx] = false
	}
}

@(private="file")
scroll_cb :: proc "c" (window: glfw.WindowHandle, xoff, yoff: f64) {
	if g_app != nil do g_app.scroll_accum += yoff
}

@(private="file")
glfw_key_to_game :: proc "contextless" (k: i32) -> game.Key {
	switch k {
	case glfw.KEY_W:           return .W
	case glfw.KEY_A:           return .A
	case glfw.KEY_S:           return .S
	case glfw.KEY_D:           return .D
	case glfw.KEY_C:           return .C
	case glfw.KEY_B:           return .B
	case glfw.KEY_R:           return .R
	case glfw.KEY_V:           return .V
	case glfw.KEY_N:           return .N
	case glfw.KEY_Q:           return .Q
	case glfw.KEY_E:           return .E
	case glfw.KEY_F:           return .F
	case glfw.KEY_1:           return .Num1
	case glfw.KEY_2:           return .Num2
	case glfw.KEY_3:           return .Num3
	case glfw.KEY_4:           return .Num4
	case glfw.KEY_5:           return .Num5
	case glfw.KEY_6:           return .Num6
	case glfw.KEY_7:           return .Num7
	case glfw.KEY_ESCAPE:      return .Escape
	case glfw.KEY_ENTER:       return .Enter
	case glfw.KEY_SPACE:       return .Space
	case glfw.KEY_LEFT_SHIFT:  return .Left_Shift
	case glfw.KEY_RIGHT_SHIFT: return .Right_Shift
	case glfw.KEY_F6:          return .F6
	}
	return .Unknown
}

// ---------------------------------------------------------------------------
// Platform fn-pointer implementations. Each takes ^Platform and finds the App
// via the user_data pointer set up at init.

@(private="file")
app_of :: #force_inline proc "contextless" (p: ^game.Platform) -> ^App {
	return cast(^App)p.user_data
}

@(private="file")
to_native_font :: #force_inline proc "contextless" (f: game.Font_Size) -> Font_Size {
	switch f {
	case .Small: return .Small
	case .Large: return .Large
	}
	return .Small
}

@(private="file")
plat_is_key_down :: proc "contextless" (p: ^game.Platform, key: game.Key) -> bool {
	a := app_of(p)
	idx := int(key)
	if idx < 0 || idx >= game.KEY_COUNT do return false
	return a.keys_down[idx]
}

@(private="file")
plat_is_key_just_pressed :: proc "contextless" (p: ^game.Platform, key: game.Key) -> bool {
	a := app_of(p)
	idx := int(key)
	if idx < 0 || idx >= game.KEY_COUNT do return false
	return a.keys_down[idx] && !a.keys_was_down[idx]
}

@(private="file")
plat_draw_rect :: proc(p: ^game.Platform, x, y, w, h: f32, color: [4]f32) {
	gfx_push_rect(&app_of(p).graphics, x, y, w, h, color)
}

@(private="file")
plat_draw_circle :: proc(p: ^game.Platform, cx, cy, r: f32, color: [4]f32) {
	gfx_push_circle(&app_of(p).graphics, cx, cy, r, color)
}

@(private="file")
plat_draw_line :: proc(p: ^game.Platform, ax, ay, bx, by, t: f32, color: [4]f32) {
	gfx_push_line(&app_of(p).graphics, ax, ay, bx, by, t, color)
}

@(private="file")
plat_draw_text :: proc(p: ^game.Platform, x, y: f32, s: string, color: [4]f32, font: game.Font_Size) {
	text_push(&app_of(p).graphics.text, x, y, s, color, to_native_font(font))
}

@(private="file")
plat_text_measure :: proc(p: ^game.Platform, s: string, font: game.Font_Size) -> f32 {
	return text_measure(&app_of(p).graphics.text, s, to_native_font(font))
}

@(private="file")
plat_font_size_px :: proc(p: ^game.Platform, font: game.Font_Size) -> f32 {
	return font_pixel_size(to_native_font(font))
}

@(private="file")
plat_set_camera :: proc(p: ^game.Platform, scale, offset: [2]f32) {
	gfx_set_view(&app_of(p).graphics, scale, offset)
}

@(private="file")
plat_clear_camera :: proc(p: ^game.Platform) {
	gfx_clear_view(&app_of(p).graphics)
}

@(private="file")
plat_push_scissor :: proc(p: ^game.Platform, x, y, w, h: f32) {
	gfx_push_scissor(&app_of(p).graphics, x, y, w, h)
}

@(private="file")
plat_pop_scissor :: proc(p: ^game.Platform) {
	gfx_pop_scissor(&app_of(p).graphics)
}

@(private="file")
plat_fog_lights_clear :: proc(p: ^game.Platform) {
	gfx_clear_fog_lights(&app_of(p).graphics)
}

@(private="file")
plat_fog_lights_push :: proc(p: ^game.Platform, x, y: f32) {
	gfx_push_fog_light(&app_of(p).graphics, x, y)
}

@(private="file")
plat_toggle_fullscreen :: proc(p: ^game.Platform) {
	a := app_of(p)
	if !a.is_fullscreen {
		a.windowed_x, a.windowed_y = glfw.GetWindowPos(a.window)
		a.windowed_w, a.windowed_h = glfw.GetWindowSize(a.window)
		mon := glfw.GetPrimaryMonitor()
		vm  := glfw.GetVideoMode(mon)
		if mon == nil || vm == nil do return
		glfw.SetWindowMonitor(a.window, mon, 0, 0, vm.width, vm.height, vm.refresh_rate)
		a.is_fullscreen = true
	} else {
		glfw.SetWindowMonitor(a.window, nil, a.windowed_x, a.windowed_y, a.windowed_w, a.windowed_h, 0)
		a.is_fullscreen = false
	}
	// Defer the swapchain rebuild to the next `renderer_begin_frame`. Doing it
	// inline here is racy: SetWindowMonitor's WM_SIZE has only just been
	// dispatched, and on some drivers the surface caps it returns right now
	// still describe the previous mode. The renderer treats `swapchain_dirty`
	// as a "skip one frame, rebuild, try again" signal — that frame's
	// PollEvents at the top of the loop is what flushes the size message.
	a.renderer.swapchain_dirty = true
}

@(private="file")
plat_request_quit :: proc(p: ^game.Platform) {
	app_of(p).should_quit = true
}

@(private="file")
plat_play_sound :: proc(p: ^game.Platform, sound: game.Sound) {
	audio_play(&app_of(p).audio, sound)
}

@(private="file")
plat_play_sound_at :: proc(p: ^game.Platform, sound: game.Sound, x, y: f32) {
	audio_play_at(&app_of(p).audio, sound, x, y)
}

@(private="file")
plat_set_sound_loop :: proc(p: ^game.Platform, sound: game.Sound, active: bool) {
	audio_set_loop(&app_of(p).audio, sound, active)
}
