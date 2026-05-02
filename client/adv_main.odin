package main

import "core:fmt"
import "core:os"
import "core:time"
import "vendor:glfw"
import win "core:sys/windows"

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

	r: Renderer
	if !renderer_init(&r, window) {
		fmt.eprintln("failed to init renderer")
		os.exit(1)
	}
	defer renderer_shutdown(&r)

	g: Graphics
	if !gfx_init(&g, &r) {
		fmt.eprintln("failed to init graphics")
		os.exit(1)
	}
	defer gfx_shutdown(&g)

	ui: UI
	ui_init(&ui, window)
	defer ui_shutdown(&ui)

	input: Input
	input_init(&input, window)

	cam := Camera{pos = {0, 0}, zoom = 1}

	clicks := 0

	monitor := glfw.GetPrimaryMonitor()
	vid_mode := glfw.GetVideoMode(monitor)
	refresh_hz := vid_mode != nil ? i32(vid_mode.refresh_rate) : 60
	if refresh_hz <= 0 do refresh_hz = 60
	fmt.printfln("monitor: %dx%d @ %dHz", vid_mode != nil ? vid_mode.width : 0, vid_mode != nil ? vid_mode.height : 0, refresh_hz)

	target_dt := 1.0 / f64(refresh_hz)
	win.timeBeginPeriod(1)
	defer win.timeEndPeriod(1)

	last_time := glfw.GetTime()
	frame_dt: f64 = 0
	fps_accum: f64 = 0
	fps_frames := 0
	fps: f64 = 0
	frame_ms: f64 = 0

	for !glfw.WindowShouldClose(window) {
		now := glfw.GetTime()
		frame_dt = now - last_time
		last_time = now

		fps_accum += frame_dt
		fps_frames += 1
		if fps_accum >= 0.25 {
			fps = f64(fps_frames) / fps_accum
			frame_ms = (fps_accum / f64(fps_frames)) * 1000
			fps_accum = 0
			fps_frames = 0
		}

		input_update(&input)
		glfw.PollEvents()
		ui_update(&ui, window)

		sw := f32(r.swapchain_extent.width)
		sh := f32(r.swapchain_extent.height)

		dt := f32(frame_dt)
		PAN_SPEED :: f32(400)
		pan: [2]f32
		if input_is_down(&input, glfw.KEY_W) do pan.y -= 1
		if input_is_down(&input, glfw.KEY_S) do pan.y += 1
		if input_is_down(&input, glfw.KEY_A) do pan.x -= 1
		if input_is_down(&input, glfw.KEY_D) do pan.x += 1
		if pan.x != 0 || pan.y != 0 {
			cam.pos += pan * (PAN_SPEED * dt / cam.zoom)
		}

		if ui.scroll_dy != 0 {
			before := camera_screen_to_world(&cam, ui.mouse, sw, sh)
			zoom_factor := f32(1) + ui.scroll_dy * 0.1
			cam.zoom *= zoom_factor
			if cam.zoom < 0.1 do cam.zoom = 0.1
			if cam.zoom > 8   do cam.zoom = 8
			after := camera_screen_to_world(&cam, ui.mouse, sw, sh)
			cam.pos += before - after
		}

		if !gfx_begin(&g) do continue

		gfx_set_camera(&g, &cam)
		draw_rect(&g, -64, -64, 128, 128, {0.45, 0.55, 0.85, 1})
		draw_rect(&g, -4, -4, 8, 8, {1, 1, 1, 1})
		draw_line(&g, -200, 0, 200, 0, 1, {1, 0.4, 0.4, 0.6})
		draw_line(&g, 0, -200, 0, 200, 1, {0.4, 1, 0.4, 0.6})

		gfx_clear_camera(&g)

		bw, bh := f32(240), f32(72)
		bx := (sw - bw) * 0.5
		by := (sh - bh) * 0.5

		if ui_button(&ui, &g, "Click me!", bx, by, bw, bh) {
			clicks += 1
		}

		label := fmt.tprintf("clicks: %d", clicks)
		tw := text_measure(&g.text, label)
		draw_text(&g, (sw - tw) * 0.5, by - 24, label, {0.8, 0.9, 1.0, 1})

		stats := fmt.tprintf("fps %.0f  %.2fms  refresh %dHz  zoom %.2f  pos (%.0f, %.0f)", fps, frame_ms, refresh_hz, cam.zoom, cam.pos.x, cam.pos.y)
		draw_text(&g, 8, 8 + FONT_PIXEL_SIZE, stats, {0.7, 0.95, 0.7, 1})

		gfx_end(&g)
		free_all(context.temp_allocator)

		elapsed := glfw.GetTime() - now
		if elapsed < target_dt {
			time.sleep(time.Duration((target_dt - elapsed) * f64(time.Second)))
		}
	}
}
