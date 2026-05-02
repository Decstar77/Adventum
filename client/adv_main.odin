package main

import "core:fmt"
import "core:os"
import "core:time"
import "vendor:glfw"
import win "core:sys/windows"

Selection_Mode :: enum {
	Default,
	Place,
}

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

	world: World
	world_init(&world)
	defer world_shutdown(&world)

	mode          := Selection_Mode.Default
	selected_kind := Tile_Kind.Farm

	rmb_down     := false
	rmb_was_down := false

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

	TICK_HZ   :: 10.0
	TICK_DT   :: 1.0 / TICK_HZ
	tick_accum: f64 = 0

	// Initial energization pass so the Core's energized flag is correct from frame 0.
	world_tick(&world, 0)

	HOTKEYS := [TILE_KIND_COUNT]i32{
		glfw.KEY_1, glfw.KEY_2, glfw.KEY_3,
		glfw.KEY_4, glfw.KEY_5, glfw.KEY_6,
	}

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
		rmb_was_down = rmb_down
		rmb_down = glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_RIGHT) == glfw.PRESS

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

		for k, i in HOTKEYS {
			if input_just_pressed(&input, k) {
				selected_kind = Tile_Kind(i)
				mode = .Place
			}
		}

		if input_just_pressed(&input, glfw.KEY_ESCAPE) {
			mode = .Default
		}

		if !world.game_over {
			if input_just_pressed(&input, glfw.KEY_C) do enemy_spawn(&world, .Crawler)
			if input_just_pressed(&input, glfw.KEY_B) do enemy_spawn(&world, .Brute)
		}

		if world.game_over && input_just_pressed(&input, glfw.KEY_R) {
			world_shutdown(&world)
			world = World{}
			world_init(&world)
			world_tick(&world, 0)
			cam = Camera{pos = {0, 0}, zoom = 1}
			selected_kind = .Farm
			mode = .Default
			tick_accum = 0
		}

		if !world.game_over {
			world.survive_time += dt

			tick_accum += frame_dt
			for tick_accum >= TICK_DT {
				world_tick(&world, f32(TICK_DT))
				tick_accum -= TICK_DT
			}

			waves_update(&world, &world.waves, dt)
			turrets_fire(&world, dt)
			projectiles_update(&world, dt)
			enemies_update(&world, dt)
			sweep_dead_enemies(&world)

			if c, ok := world.tiles[world.core]; ok {
				if c.hp <= 0 do world.game_over = true
			}
		}

		// Picker bar layout (used both for hit-test and for drawing later)
		picker_h    := f32(56)
		picker_pad  := f32(8)
		picker_y    := sh - picker_h - 12
		picker_w    := f32(TILE_KIND_COUNT) * 132 + f32(TILE_KIND_COUNT - 1) * 8 + picker_pad * 2
		picker_x    := (sw - picker_w) * 0.5
		mouse_in_picker := point_in_rect(ui.mouse, picker_x, picker_y, picker_w, picker_h)

		// Hex under cursor
		mouse_world := camera_screen_to_world(&cam, ui.mouse, sw, sh)
		hover := pixel_to_hex(mouse_world)

		// Place / remove via mouse on the world (suppressed when over the picker bar)
		lmb_just := ui_mouse_just_pressed(&ui)
		rmb_just := rmb_down && !rmb_was_down
		shift_held := input_is_down(&input, glfw.KEY_LEFT_SHIFT) || input_is_down(&input, glfw.KEY_RIGHT_SHIFT)
		if !mouse_in_picker && !world.game_over {
			if lmb_just && mode == .Place {
				if world_place(&world, hover, selected_kind) {
					if !shift_held do mode = .Default
				}
			}
			if rmb_just {
				if mode == .Place {
					mode = .Default
				} else {
					world_remove(&world, hover)
				}
			}
		}

		if !gfx_begin(&g) do continue

		// World pass
		gfx_set_camera(&g, &cam)
		world_render(&world, &g)
		enemies_render(&world, &g)
		projectiles_render(&world, &g)
		if !world.game_over {
			world_render_hover(&world, &g, hover, mode == .Place, selected_kind)
		}

		// UI / screen-space pass
		gfx_clear_camera(&g)

		// Picker bar background
		draw_rect(&g, picker_x, picker_y, picker_w, picker_h, {0.10, 0.11, 0.14, 0.85})
		bx := picker_x + picker_pad
		by := picker_y + picker_pad
		bw := f32(132)
		bh := picker_h - picker_pad * 2
		for i in 0 ..< TILE_KIND_COUNT {
			kind := Tile_Kind(i)
			cost := tile_cost(kind)
			label := fmt.tprintf("%d %s  -%.0ff", i + 1, tile_kind_name(kind), cost)
			x := bx + f32(i) * (bw + 8)
			affordable := world.food >= cost
			if ui_button(&ui, &g, label, x, by, bw, bh) {
				selected_kind = kind
				mode = .Place
			}
			if !affordable {
				draw_rect(&g, x, by, bw, bh, {0, 0, 0, 0.45})
			}
			if mode == .Place && kind == selected_kind {
				_, stroke := tile_color(kind)
				draw_line(&g, x,        by,        x + bw, by,        2, stroke)
				draw_line(&g, x,        by + bh,   x + bw, by + bh,   2, stroke)
				draw_line(&g, x,        by,        x,      by + bh,   2, stroke)
				draw_line(&g, x + bw,   by,        x + bw, by + bh,   2, stroke)
			}
		}

		// Top-left HUD
		core_hp := f32(0)
		if c, ok := world.tiles[world.core]; ok do core_hp = c.hp
		power_remaining := world_power_remaining(&world)
		food_line  := fmt.tprintf("Food:  %d", i32(world.food))
		scrap_line := fmt.tprintf("Scrap: %d", world.scrap)
		power_line := fmt.tprintf("Power: %d", power_remaining)
		core_line  := fmt.tprintf("Core:  %.0f", core_hp)
		power_color := [4]f32{0.96, 0.86, 0.62, 1}
		if power_remaining < 0 do power_color = {1.00, 0.36, 0.36, 1}
		enemy_line := fmt.tprintf("Enemies: %d  [C] crawler  [B] brute", len(world.enemies))
		draw_text(&g, 12, 12 + FONT_PIXEL_SIZE,             food_line,  {0.92, 0.98, 0.78, 1})
		draw_text(&g, 12, 12 + FONT_PIXEL_SIZE * 2 + 4,     scrap_line, {0.72, 0.83, 0.96, 1})
		draw_text(&g, 12, 12 + FONT_PIXEL_SIZE * 3 + 8,     power_line, power_color)
		draw_text(&g, 12, 12 + FONT_PIXEL_SIZE * 4 + 12,    core_line,  {0.85, 0.82, 0.99, 1})
		draw_text(&g, 12, 12 + FONT_PIXEL_SIZE * 5 + 16,    enemy_line, {0.96, 0.78, 0.78, 1})

		// Big timer at top-center.
		timer_str := fmt.tprintf("%.1fs", world.survive_time)
		tw_timer := text_measure(&g.text, timer_str, .Large)
		timer_y := f32(16) + font_pixel_size(.Large)
		draw_text(&g, (sw - tw_timer) * 0.5, timer_y, timer_str, {0.95, 0.95, 0.98, 1}, .Large)

		// Surge countdown directly underneath.
		if world.waves.surge_active {
			active_str := "SURGE ACTIVE"
			aw := text_measure(&g.text, active_str)
			draw_text(&g, (sw - aw) * 0.5, timer_y + 14, active_str, {1.00, 0.55, 0.55, 1})
		} else {
			rem := waves_time_to_next_surge(&world.waves)
			cd_str := fmt.tprintf("Next surge in %.0fs", rem)
			cw := text_measure(&g.text, cd_str)
			draw_text(&g, (sw - cw) * 0.5, timer_y + 14, cd_str, {0.78, 0.82, 0.92, 1})
		}

		// SURGE WAVE banner — flashes for ~3 seconds when a surge fires.
		if world.waves.banner_time > 0 {
			banner_str := fmt.tprintf("SURGE WAVE %d", world.waves.last_surge_num)
			bw_banner := text_measure(&g.text, banner_str, .Large)
			alpha := world.waves.banner_time / WAVE_BANNER_DURATION
			if alpha > 1 do alpha = 1
			if alpha < 0 do alpha = 0
			draw_text(&g, (sw - bw_banner) * 0.5, sh * 0.5, banner_str, {1.00, 0.30, 0.30, alpha}, .Large)
		}

		mode_label := mode == .Place ? "PLACE (shift = multi)" : "SELECT"
		stats := fmt.tprintf("fps %.0f  %.2fms  zoom %.2f  hover (%d, %d)  mode: %s  kind: %s",
			fps, frame_ms, cam.zoom, hover.x, hover.y, mode_label, tile_kind_name(selected_kind))
		draw_text(&g, 12, sh - 12 - picker_h - 12 - FONT_PIXEL_SIZE, stats, {0.65, 0.70, 0.78, 1})

		if world.game_over {
			draw_rect(&g, 0, 0, sw, sh, {0, 0, 0, 0.65})
			head := "CORE DESTROYED"
			body := fmt.tprintf("Survived %.1fs   |   Scrap collected: %d", world.survive_time, world.scrap)
			tip  := "Press R to restart"
			hw := text_measure(&g.text, head, .Large)
			bw := text_measure(&g.text, body)
			tw := text_measure(&g.text, tip)
			cy := sh * 0.5
			draw_text(&g, (sw - hw) * 0.5, cy - 28, head, {1.00, 0.82, 0.82, 1}, .Large)
			draw_text(&g, (sw - bw) * 0.5, cy + 24, body, {0.96, 0.96, 0.96, 1})
			draw_text(&g, (sw - tw) * 0.5, cy + 56, tip,  {0.78, 0.86, 1.00, 1})
		}

		gfx_end(&g)
		free_all(context.temp_allocator)

		elapsed := glfw.GetTime() - now
		if elapsed < target_dt {
			time.sleep(time.Duration((target_dt - elapsed) * f64(time.Second)))
		}
	}
}
