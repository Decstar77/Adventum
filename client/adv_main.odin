package main

import "core:fmt"
import "core:math"
import "base:runtime"

import sapp "sokol/app"
import slog "sokol/log"

Selection_Mode :: enum {
	Default,
	Place,
}

App :: struct {
	r:                Renderer,
	g:                Graphics,
	ui:               UI,
	input:            Input,
	cam:              Camera,
	world:            World,
	mode:             Selection_Mode,
	selected_kind:    Tile_Kind,
	selected_tile:    Hex_Coord,
	has_selection:    bool,

	hover_smoothed:      [2]f32,
	hover_smoothed_init: bool,

	tick_accum:       f64,
	last_time:        f64,
	fps_accum:        f64,
	fps_frames:       int,
	fps:              f64,
	frame_ms:         f64,
}

@(private="file") g_app: App
@(private="file") g_ctx: runtime.Context

PANEL_W :: f32(240)
PANEL_H :: f32(220)

TICK_HZ :: 10.0
TICK_DT :: 1.0 / TICK_HZ

HOTKEYS := [BUILDABLE_COUNT]sapp.Keycode{
	._1, ._2, ._3, ._4, ._5, ._6,
}

main :: proc() {
	sapp.run({
		init_cb      = init_cb,
		frame_cb     = frame_cb,
		event_cb     = event_cb,
		cleanup_cb   = cleanup_cb,
		width        = 1280,
		height       = 720,
		sample_count = 1,
		swap_interval = 1,
		window_title = "Adventum",
		logger       = {func = slog.func},
	})
}

@(private="file")
init_cb :: proc "c" () {
	context = runtime.default_context()
	g_ctx = context

	app := &g_app
	if !renderer_init(&app.r) {
		fmt.eprintln("failed to init renderer")
		sapp.quit()
		return
	}
	if !gfx_init(&app.g, &app.r) {
		fmt.eprintln("failed to init graphics")
		sapp.quit()
		return
	}
	ui_init(&app.ui)
	input_init(&app.input)

	app.cam = Camera{pos = {0, 0}, zoom = 1}
	world_init(&app.world)
	app.selected_kind = .Farm

	// Initial energization pass so the Core's energized flag is correct from frame 0.
	world_tick(&app.world, 0)
}

@(private="file")
cleanup_cb :: proc "c" () {
	context = g_ctx
	app := &g_app
	world_shutdown(&app.world)
	ui_shutdown(&app.ui)
	gfx_shutdown(&app.g)
	renderer_shutdown(&app.r)
}

@(private="file")
event_cb :: proc "c" (ev: ^sapp.Event) {
	context = g_ctx
	app := &g_app
	input_handle_event(&app.input, ev)
	ui_handle_event(&app.ui, ev)

	#partial switch ev.type {
	case .KEY_DOWN:
		if ev.key_repeat do return
		shift := (ev.modifiers & sapp.MODIFIER_SHIFT) != 0
		if shift && ev.key_code == .ENTER {
			sapp.toggle_fullscreen()
		}
	}
}

@(private="file")
frame_cb :: proc "c" () {
	context = g_ctx
	app := &g_app

	dt_f := sapp.frame_duration()
	if dt_f <= 0 do dt_f = 1.0 / 60.0
	if dt_f > 0.1 do dt_f = 0.1
	dt := f32(dt_f)

	app.fps_accum += dt_f
	app.fps_frames += 1
	if app.fps_accum >= 0.25 {
		app.fps = f64(app.fps_frames) / app.fps_accum
		app.frame_ms = (app.fps_accum / f64(app.fps_frames)) * 1000
		app.fps_accum = 0
		app.fps_frames = 0
	}

	// Snap current scroll delta into ui.scroll_dy and clear accumulator.
	app.ui.scroll_dy = app.ui.scroll_accum
	app.ui.scroll_accum = 0
	clear(&app.ui.layouts)

	world := &app.world
	cam := &app.cam
	ui := &app.ui
	input := &app.input

	sw := f32(sapp.width())
	sh := f32(sapp.height())

	PAN_SPEED       :: f32(400)
	EDGE_MARGIN     :: f32(24)
	EDGE_PAN_SPEED  :: f32(550)
	pan: [2]f32
	if input_is_down(input, .W) do pan.y -= 1
	if input_is_down(input, .S) do pan.y += 1
	if input_is_down(input, .A) do pan.x -= 1
	if input_is_down(input, .D) do pan.x += 1
	if pan.x != 0 || pan.y != 0 {
		cam.pos += pan * (PAN_SPEED * dt / cam.zoom)
	}

	if ui.mouse.x >= 0 && ui.mouse.y >= 0 && ui.mouse.x < sw && ui.mouse.y < sh {
		edge: [2]f32
		if ui.mouse.x < EDGE_MARGIN          do edge.x = -(1 - ui.mouse.x / EDGE_MARGIN)
		else if ui.mouse.x > sw - EDGE_MARGIN do edge.x =  1 - (sw - ui.mouse.x) / EDGE_MARGIN
		if ui.mouse.y < EDGE_MARGIN          do edge.y = -(1 - ui.mouse.y / EDGE_MARGIN)
		else if ui.mouse.y > sh - EDGE_MARGIN do edge.y =  1 - (sh - ui.mouse.y) / EDGE_MARGIN
		if edge.x != 0 || edge.y != 0 {
			cam.pos += edge * (EDGE_PAN_SPEED * dt / cam.zoom)
		}
	}

	if ui.scroll_dy != 0 {
		before := camera_screen_to_world(cam, ui.mouse, sw, sh)
		zoom_factor := f32(1) + ui.scroll_dy * 0.1
		cam.zoom *= zoom_factor
		if cam.zoom < 0.1 do cam.zoom = 0.1
		if cam.zoom > 8   do cam.zoom = 8
		after := camera_screen_to_world(cam, ui.mouse, sw, sh)
		cam.pos += before - after
	}

	for k, i in HOTKEYS {
		if input_just_pressed(input, k) {
			app.selected_kind = Tile_Kind(i)
			app.mode = .Place
			app.has_selection = false
		}
	}

	if input_just_pressed(input, .ESCAPE) {
		app.mode = .Default
		app.has_selection = false
	}

	if app.has_selection {
		if _, ok := world.tiles[app.selected_tile]; !ok do app.has_selection = false
	}

	if !world.game_over {
		if input_just_pressed(input, .C) do enemy_spawn(world, .Crawler)
		if input_just_pressed(input, .B) do enemy_spawn(world, .Brute)
	}

	if world.game_over && input_just_pressed(input, .R) {
		world_shutdown(world)
		world^ = World{}
		world_init(world)
		world_tick(world, 0)
		cam^ = Camera{pos = {0, 0}, zoom = 1}
		app.selected_kind = .Farm
		app.mode = .Default
		app.tick_accum = 0
	}

	if !world.game_over {
		world.survive_time += dt

		app.tick_accum += f64(dt)
		for app.tick_accum >= TICK_DT {
			world_tick(world, f32(TICK_DT))
			app.tick_accum -= TICK_DT
		}

		waves_update(world, &world.waves, dt)
		turrets_fire(world, dt)
		projectiles_update(world, dt)
		enemies_update(world, dt)
		sweep_dead_enemies(world)
		particles_update(world, dt)

		if c, ok := world.tiles[world.core]; ok {
			if c.hp <= 0 do world.game_over = true
		}
	}

	picker_h    := f32(56)
	picker_pad  := f32(8)
	picker_y    := sh - picker_h - 12
	picker_w    := f32(BUILDABLE_COUNT) * 132 + f32(BUILDABLE_COUNT - 1) * 8 + picker_pad * 2
	picker_x    := (sw - picker_w) * 0.5
	mouse_in_picker := point_in_rect(ui.mouse, picker_x, picker_y, picker_w, picker_h)

	panel_x := sw - PANEL_W - 12
	panel_y := f32(12)
	mouse_in_panel := app.has_selection && point_in_rect(ui.mouse, panel_x, panel_y, PANEL_W, PANEL_H)

	mouse_world := camera_screen_to_world(cam, ui.mouse, sw, sh)
	hover := pixel_to_hex(mouse_world)

	lmb_just := ui_mouse_just_pressed(ui)
	rmb_just := ui_rmb_just_pressed(ui)
	shift_held := input_is_down(input, .LEFT_SHIFT) || input_is_down(input, .RIGHT_SHIFT)
	if !mouse_in_picker && !mouse_in_panel && !world.game_over {
		if lmb_just && app.mode == .Place {
			if world_place(world, hover, app.selected_kind) {
				if !shift_held do app.mode = .Default
			}
		} else if lmb_just && app.mode == .Default {
			if _, ok := world.tiles[hover]; ok {
				app.selected_tile = hover
				app.has_selection = true
			} else {
				app.has_selection = false
			}
		}
		if rmb_just {
			if app.mode == .Place {
				app.mode = .Default
			} else {
				world_remove(world, hover)
			}
		}
	}

	if !gfx_begin(&app.g, dt) {
		// resize-to-zero or similar; finalize input bookkeeping and return.
		input_update(input)
		ui.mouse_was_down = ui.mouse_down
		ui.rmb_was_down   = ui.rmb_down
		free_all(context.temp_allocator)
		return
	}

	gfx_set_camera(&app.g, cam)
	world_render(world, &app.g)
	enemies_render(world, &app.g)
	projectiles_render(world, &app.g)
	particles_render(world, &app.g)

	HOVER_SMOOTH_RATE :: f32(30)
	hover_target := hex_to_pixel(hover)
	if !app.hover_smoothed_init {
		app.hover_smoothed = hover_target
		app.hover_smoothed_init = true
	} else {
		t := 1 - math.exp(-dt * HOVER_SMOOTH_RATE)
		app.hover_smoothed.x += (hover_target.x - app.hover_smoothed.x) * t
		app.hover_smoothed.y += (hover_target.y - app.hover_smoothed.y) * t
	}

	if !world.game_over {
		world_render_hover(world, &app.g, hover, app.hover_smoothed, app.mode == .Place, app.selected_kind)

		if app.mode == .Default && !mouse_in_picker && !mouse_in_panel {
			if _, ok := world.tiles[hover]; ok {
				draw_hex_outline(&app.g, hover, 2.5, {1, 1, 1, 0.9})
			}
		}
		if app.has_selection {
			draw_hex_outline(&app.g, app.selected_tile, 3, {1, 1, 1, 1})
		}
	}

	gfx_clear_camera(&app.g)

	draw_rect(&app.g, picker_x, picker_y, picker_w, picker_h, {0.10, 0.11, 0.14, 0.85})
	bx := picker_x + picker_pad
	by := picker_y + picker_pad
	bw := f32(132)
	bh := picker_h - picker_pad * 2
	for i in 0 ..< BUILDABLE_COUNT {
		kind := Tile_Kind(i)
		cost := tile_cost(kind)
		x := bx + f32(i) * (bw + 8)
		affordable := world.food >= cost
		if ui_button(ui, &app.g, "", x, by, bw, bh) {
			app.selected_kind = kind
			app.mode = .Place
			app.has_selection = false
		}

		draw_tile_icon(&app.g, x + 32, by + bh * 0.5, kind, 1)

		cost_str := fmt.tprintf("%.0f", cost)
		cw := text_measure(&app.g.text, cost_str)
		text_x := x + bw - 8 - cw
		text_y := by + bh * 0.5 + FONT_PIXEL_SIZE * 0.35
		cost_color := affordable ? [4]f32{1, 1, 1, 1} : [4]f32{1, 0.55, 0.55, 1}
		draw_text(&app.g, text_x, text_y, cost_str, cost_color)
		icon_s := f32(16)
		draw_food_icon(&app.g, text_x - icon_s - 4, by + (bh - icon_s) * 0.5, icon_s)

		if !affordable {
			draw_rect(&app.g, x, by, bw, bh, {0, 0, 0, 0.45})
		}
		if app.mode == .Place && kind == app.selected_kind {
			_, stroke := tile_color(kind)
			draw_line(&app.g, x,        by,        x + bw, by,        2, stroke)
			draw_line(&app.g, x,        by + bh,   x + bw, by + bh,   2, stroke)
			draw_line(&app.g, x,        by,        x,      by + bh,   2, stroke)
			draw_line(&app.g, x + bw,   by,        x + bw, by + bh,   2, stroke)
		}
	}

	core_hp := f32(0)
	if c, ok := world.tiles[world.core]; ok do core_hp = c.hp
	hud_icon_s := f32(18)
	hud_icon_x := f32(12)
	hud_text_x := hud_icon_x + hud_icon_s + 6
	row_y :: proc(n: f32) -> f32 { return 12 + FONT_PIXEL_SIZE * n + 4 * (n - 1) }
	icon_top :: proc(baseline_y, icon_size: f32) -> f32 {
		return baseline_y - icon_size + (icon_size - FONT_PIXEL_SIZE) * 0.5 + 1
	}
	y1 := row_y(1)
	y2 := row_y(2)
	y3 := row_y(3)
	y4 := row_y(4)
	draw_food_icon (&app.g, hud_icon_x, icon_top(y1, hud_icon_s), hud_icon_s)
	draw_scrap_icon(&app.g, hud_icon_x, icon_top(y2, hud_icon_s), hud_icon_s)
	draw_core_icon (&app.g, hud_icon_x, icon_top(y3, hud_icon_s), hud_icon_s)
	draw_enemy_icon(&app.g, hud_icon_x, icon_top(y4, hud_icon_s), hud_icon_s)
	draw_text(&app.g, hud_text_x, y1, fmt.tprintf("%d", i32(world.food)),                            {0.92, 0.98, 0.78, 1})
	draw_text(&app.g, hud_text_x, y2, fmt.tprintf("%d", world.scrap),                                {0.72, 0.83, 0.96, 1})
	draw_text(&app.g, hud_text_x, y3, fmt.tprintf("%.0f", core_hp),                                  {0.85, 0.82, 0.99, 1})
	draw_text(&app.g, hud_text_x, y4, fmt.tprintf("%d  [C] crawler  [B] brute", len(world.enemies)), {0.96, 0.78, 0.78, 1})

	timer_str := fmt.tprintf("%.1fs", world.survive_time)
	tw_timer := text_measure(&app.g.text, timer_str, .Large)
	timer_y := f32(16) + font_pixel_size(.Large)
	draw_text(&app.g, (sw - tw_timer) * 0.5, timer_y, timer_str, {0.95, 0.95, 0.98, 1}, .Large)

	if world.waves.surge_active {
		active_str := "SURGE ACTIVE"
		aw := text_measure(&app.g.text, active_str)
		draw_text(&app.g, (sw - aw) * 0.5, timer_y + 14, active_str, {1.00, 0.55, 0.55, 1})
	} else {
		rem := waves_time_to_next_surge(&world.waves)
		cd_str := fmt.tprintf("Next surge in %.0fs", rem)
		cw := text_measure(&app.g.text, cd_str)
		draw_text(&app.g, (sw - cw) * 0.5, timer_y + 14, cd_str, {0.78, 0.82, 0.92, 1})
	}

	if world.waves.banner_time > 0 {
		banner_str := fmt.tprintf("SURGE WAVE %d", world.waves.last_surge_num)
		bw_banner := text_measure(&app.g.text, banner_str, .Large)
		alpha := world.waves.banner_time / WAVE_BANNER_DURATION
		if alpha > 1 do alpha = 1
		if alpha < 0 do alpha = 0
		draw_text(&app.g, (sw - bw_banner) * 0.5, sh * 0.5, banner_str, {1.00, 0.30, 0.30, alpha}, .Large)
	}

	if app.has_selection {
		tile := world.tiles[app.selected_tile]
		max_hp := tile_max_hp(tile.kind)
		cost := tile_cost(tile.kind)

		draw_rect(&app.g, panel_x, panel_y, PANEL_W, PANEL_H, {0.10, 0.11, 0.14, 0.92})
		draw_line(&app.g, panel_x, panel_y, panel_x + PANEL_W, panel_y, 1, {1, 1, 1, 0.15})
		draw_line(&app.g, panel_x, panel_y + PANEL_H, panel_x + PANEL_W, panel_y + PANEL_H, 1, {0, 0, 0, 0.40})

		title := tile_kind_name(tile.kind)
		tw_title := text_measure(&app.g.text, title, .Large)
		draw_text(&app.g, panel_x + (PANEL_W - tw_title) * 0.5, panel_y + 12 + font_pixel_size(.Large), title, {0.95, 0.95, 0.98, 1}, .Large)

		hp_y := panel_y + 12 + font_pixel_size(.Large) + 24
		hp_str := fmt.tprintf("HP  %.0f / %.0f", tile.hp, max_hp)
		draw_text(&app.g, panel_x + 16, hp_y + FONT_PIXEL_SIZE, hp_str, {0.85, 0.90, 0.98, 1})

		bar_x := panel_x + 16
		bar_y := hp_y + FONT_PIXEL_SIZE + 8
		bar_w := PANEL_W - 32
		bar_h := f32(8)
		frac := max_hp > 0 ? tile.hp / max_hp : 0
		if frac < 0 do frac = 0
		if frac > 1 do frac = 1
		draw_rect(&app.g, bar_x, bar_y, bar_w, bar_h, {0.05, 0.06, 0.08, 1})
		draw_rect(&app.g, bar_x, bar_y, bar_w * frac, bar_h, {0.45, 0.85, 0.55, 1})

		btn_w := PANEL_W - 32
		btn_h := f32(36)
		btn_x := panel_x + 16
		sell_y := panel_y + PANEL_H - 16 - btn_h * 2 - 8
		upgrade_y := panel_y + PANEL_H - 16 - btn_h

		can_sell := tile.kind != .Core
		refund := i32(cost * 0.5)
		sell_label := can_sell ? fmt.tprintf("Sell  (+%d food)", refund) : "Sell  (locked)"
		if ui_button_at(ui, &app.g, sell_label, btn_x, sell_y, btn_w, btn_h) && can_sell {
			world_sell(world, app.selected_tile)
			app.has_selection = false
		}
		if ui_button_at(ui, &app.g, "Upgrade", btn_x, upgrade_y, btn_w, btn_h) {
			// TODO: implement upgrades.
		}
	}

	mode_label := app.mode == .Place ? "PLACE (shift = multi)" : "SELECT"
	stats := fmt.tprintf("fps %.0f  %.2fms  zoom %.2f  hover (%d, %d)  mode: %s  kind: %s",
		app.fps, app.frame_ms, cam.zoom, hover.x, hover.y, mode_label, tile_kind_name(app.selected_kind))
	draw_text(&app.g, 12, sh - 12 - picker_h - 12 - FONT_PIXEL_SIZE, stats, {0.65, 0.70, 0.78, 1})

	if world.game_over {
		draw_rect(&app.g, 0, 0, sw, sh, {0, 0, 0, 0.65})
		head := "CORE DESTROYED"
		body := fmt.tprintf("Survived %.1fs   |   Scrap collected: %d", world.survive_time, world.scrap)
		tip  := "Press R to restart"
		hw := text_measure(&app.g.text, head, .Large)
		bw := text_measure(&app.g.text, body)
		tw := text_measure(&app.g.text, tip)
		cy := sh * 0.5
		draw_text(&app.g, (sw - hw) * 0.5, cy - 28, head, {1.00, 0.82, 0.82, 1}, .Large)
		draw_text(&app.g, (sw - bw) * 0.5, cy + 24, body, {0.96, 0.96, 0.96, 1})
		draw_text(&app.g, (sw - tw) * 0.5, cy + 56, tip,  {0.78, 0.86, 1.00, 1})
	}

	gfx_end(&app.g)

	// End-of-frame edge-state snapshot. Events that arrive before the next
	// frame_cb update is_down/mouse_down on top of this snapshot, so
	// just_pressed = is_down && !was_down works correctly next frame.
	input_update(input)
	ui.mouse_was_down = ui.mouse_down
	ui.rmb_was_down   = ui.rmb_down

	free_all(context.temp_allocator)
}
