package game

import "core:fmt"
import "core:math"

// Game owns all simulation + UI state. The host (win32, web, ...) constructs
// one of these, calls game_init, then drives game_update_and_render(g, p) each
// frame after filling in the per-frame fields of `p`.

Selection_Mode :: enum {
	Default,
	Place,
}

Game :: struct {
	world: World,
	cam:   Camera,
	ui:    UI,

	mode:          Selection_Mode,
	selected_kind: Tile_Kind,
	selected_tile: Hex_Coord,
	has_selection: bool,

	// Right-mouse pan: track the mouse position from last frame so we can
	// turn movement-while-RMB-held into camera panning. `rmb_drag_total` is
	// the accumulated pixel distance since RMB went down — if it stays below
	// RMB_CLICK_THRESHOLD, releasing RMB counts as a click (remove tile /
	// cancel place mode); otherwise it was a pan and the click is consumed.
	rmb_was_down:    bool,
	rmb_drag_total:  f32,
	prev_mouse:      [2]f32,
	prev_mouse_init: bool,

	hover_smoothed:      [2]f32,
	hover_smoothed_init: bool,

	// Fixed-step simulation accumulator.
	tick_accum: f32,

	// FPS readout.
	fps_accum:  f32,
	fps_frames: int,
	fps:        f32,
	frame_ms:   f32,
}

PANEL_W :: f32(240)
PANEL_H :: f32(220)

Cost_Sign :: enum { Spend, Gain }

// Button with a label followed by a signed cost and a food icon, e.g.
// "Upgrade  -15 [food]" or "Sell  +7 [food]". The label, number, and icon
// are centered together as one cluster so the spacing reads as a single tag.
button_with_food_cost :: proc(ui: ^UI, p: ^Platform, label: string, amount: i32, sign: Cost_Sign, x, y, w, h: f32) -> bool {
	hover := point_in_rect(p.mouse, x, y, w, h)
	held  := hover && p.mouse_left_down

	BASE  := [4]f32{0.18, 0.20, 0.26, 1.0}
	HOVER := [4]f32{0.26, 0.30, 0.40, 1.0}
	HELD  := [4]f32{0.10, 0.12, 0.16, 1.0}

	bg := BASE
	if held       do bg = HELD
	else if hover do bg = HOVER

	p->draw_rect(x, y, w, h, bg)
	p->draw_line(x, y,     x + w, y,     1, {1, 1, 1, 0.15})
	p->draw_line(x, y + h, x + w, y + h, 1, {0, 0, 0, 0.40})

	prefix := sign == .Spend ? "-" : "+"
	num_str := fmt.tprintf("%s%d", prefix, amount)

	gap_label_num := f32(12)
	gap_num_icon  := f32(4)
	icon_s        := f32(16)

	label_w := p->text_measure(label,   .Small)
	num_w   := p->text_measure(num_str, .Small)
	total_w := label_w + gap_label_num + num_w + gap_num_icon + icon_s

	cx0 := x + (w - total_w) * 0.5
	font_small := p->font_size_px(.Small)
	ty := y + h * 0.5 + font_small * 0.3

	tint := sign == .Spend ? [4]f32{1.0, 0.78, 0.78, 1} : [4]f32{0.85, 1.0, 0.80, 1}
	p->draw_text(cx0,                                        ty, label,   {1, 1, 1, 1}, .Small)
	p->draw_text(cx0 + label_w + gap_label_num,              ty, num_str, tint,         .Small)
	icon_x := cx0 + label_w + gap_label_num + num_w + gap_num_icon
	icon_y := y + (h - icon_s) * 0.5
	draw_food_icon(p, icon_x, icon_y, icon_s)

	return hover && p.mouse_left_pressed
}

TICK_HZ :: 10.0
TICK_DT :: f32(1.0 / TICK_HZ)

@(private="file")
HOTKEYS := [BUILDABLE_COUNT]Key{
	.Num1, .Num2, .Num3, .Num4, .Num5, .Num6,
}

game_init :: proc(g: ^Game) {
	g.cam = Camera{pos = {0, 0}, zoom = 1}
	g.selected_kind = .Farm
	g.mode = .Default
	world_init(&g.world)
	// Initial energization pass so the Core's energized flag is correct from frame 0.
	world_tick(&g.world, 0)
}

game_shutdown :: proc(g: ^Game) {
	world_shutdown(&g.world)
	ui_shutdown(&g.ui)
}

game_update_and_render :: proc(g: ^Game, p: ^Platform) {
	dt := p.dt
	sw := p.screen_w
	sh := p.screen_h

	// FPS readout (rolling, updated 4×/sec).
	g.fps_accum += dt
	g.fps_frames += 1
	if g.fps_accum >= 0.25 {
		g.fps = f32(g.fps_frames) / g.fps_accum
		g.frame_ms = (g.fps_accum / f32(g.fps_frames)) * 1000
		g.fps_accum = 0
		g.fps_frames = 0
	}

	ui_begin_frame(&g.ui)

	// Camera pan via WASD plus an edge-of-screen mouse pan.
	PAN_SPEED       :: f32(400)
	EDGE_MARGIN     :: f32(24)
	EDGE_PAN_SPEED  :: f32(550)
	pan: [2]f32
	if p->is_key_down(.W) do pan.y -= 1
	if p->is_key_down(.S) do pan.y += 1
	if p->is_key_down(.A) do pan.x -= 1
	if p->is_key_down(.D) do pan.x += 1
	if pan.x != 0 || pan.y != 0 {
		g.cam.pos += pan * (PAN_SPEED * dt / g.cam.zoom)
	}

	// Mouse edge scroll: only when the cursor is inside the window. Pan
	// speed ramps from 0 at EDGE_MARGIN inward to full speed at the edge.
	if p.mouse.x >= 0 && p.mouse.y >= 0 && p.mouse.x < sw && p.mouse.y < sh {
		edge: [2]f32
		if p.mouse.x < EDGE_MARGIN          do edge.x = -(1 - p.mouse.x / EDGE_MARGIN)
		else if p.mouse.x > sw - EDGE_MARGIN do edge.x =  1 - (sw - p.mouse.x) / EDGE_MARGIN
		if p.mouse.y < EDGE_MARGIN          do edge.y = -(1 - p.mouse.y / EDGE_MARGIN)
		else if p.mouse.y > sh - EDGE_MARGIN do edge.y =  1 - (sh - p.mouse.y) / EDGE_MARGIN
		if edge.x != 0 || edge.y != 0 {
			g.cam.pos += edge * (EDGE_PAN_SPEED * dt / g.cam.zoom)
		}
	}

	// Shift+Enter: toggle borderless fullscreen on the primary monitor.
	shift_down := p->is_key_down(.Left_Shift) || p->is_key_down(.Right_Shift)
	if shift_down && p->is_key_just_pressed(.Enter) {
		p->toggle_fullscreen()
	}

	if p.scroll_dy != 0 {
		before := camera_screen_to_world(&g.cam, p.mouse, sw, sh)
		zoom_factor := f32(1) + p.scroll_dy * 0.1
		g.cam.zoom *= zoom_factor
		if g.cam.zoom < 0.1 do g.cam.zoom = 0.1
		if g.cam.zoom > 8   do g.cam.zoom = 8
		after := camera_screen_to_world(&g.cam, p.mouse, sw, sh)
		g.cam.pos += before - after
	}

	for k, i in HOTKEYS {
		if p->is_key_just_pressed(k) {
			g.selected_kind = Tile_Kind(i)
			g.mode = .Place
			g.has_selection = false
		}
	}

	if p->is_key_just_pressed(.Escape) {
		g.mode = .Default
		g.has_selection = false
	}

	// Drop stale selection (tile sold or destroyed).
	if g.has_selection {
		if _, ok := g.world.tiles[g.selected_tile]; !ok do g.has_selection = false
	}

	if !g.world.game_over {
		if p->is_key_just_pressed(.C) do enemy_spawn(&g.world, .Crawler)
		if p->is_key_just_pressed(.B) do enemy_spawn(&g.world, .Brute)
		if p->is_key_just_pressed(.V) do enemy_spawn(&g.world, .Spitter)
	}

	if g.world.game_over && p->is_key_just_pressed(.R) {
		world_shutdown(&g.world)
		g.world = World{}
		world_init(&g.world)
		world_tick(&g.world, 0)
		g.cam = Camera{pos = {0, 0}, zoom = 1}
		g.selected_kind = .Farm
		g.mode = .Default
		g.tick_accum = 0
	}

	if !g.world.game_over {
		g.world.survive_time += dt

		g.tick_accum += dt
		for g.tick_accum >= TICK_DT {
			world_tick(&g.world, TICK_DT)
			g.tick_accum -= TICK_DT
		}

		waves_update(&g.world, &g.world.waves, dt)
		turrets_fire(&g.world, dt)
		projectiles_update(&g.world, dt)
		enemies_update(&g.world, dt)
		sweep_dead_enemies(&g.world)
		particles_update(&g.world, dt)

		if c, ok := g.world.tiles[g.world.core]; ok {
			if c.hp <= 0 do g.world.game_over = true
		}
	}

	// Picker bar layout (used both for hit-test and for drawing later)
	picker_h    := f32(56)
	picker_pad  := f32(8)
	picker_y    := sh - picker_h - 12
	picker_w    := f32(BUILDABLE_COUNT) * 132 + f32(BUILDABLE_COUNT - 1) * 8 + picker_pad * 2
	picker_x    := (sw - picker_w) * 0.5
	mouse_in_picker := point_in_rect(p.mouse, picker_x, picker_y, picker_w, picker_h)

	// Right-side selection panel (only visible when something is selected).
	panel_x := sw - PANEL_W - 12
	panel_y := f32(12)
	mouse_in_panel := g.has_selection && point_in_rect(p.mouse, panel_x, panel_y, PANEL_W, PANEL_H)

	// Hex under cursor
	mouse_world := camera_screen_to_world(&g.cam, p.mouse, sw, sh)
	hover := pixel_to_hex(mouse_world)

	// Right-mouse pan. While RMB is held, drag the camera by the mouse
	// delta (in world units, so the tile under the cursor stays under it).
	// On release, if the cursor barely moved we treat it as a click and
	// run the original remove-tile / cancel-place logic.
	RMB_CLICK_THRESHOLD :: f32(4) // pixels of total drag below which a release counts as a click
	if !g.prev_mouse_init {
		g.prev_mouse = p.mouse
		g.prev_mouse_init = true
	}
	mouse_delta := p.mouse - g.prev_mouse

	rmb_clicked := false
	if p.mouse_right_down {
		if !g.rmb_was_down {
			g.rmb_drag_total = 0
		} else if g.cam.zoom > 0 {
			// Pan opposite the drag direction so the world feels grabbed.
			g.cam.pos -= mouse_delta / g.cam.zoom
		}
		g.rmb_drag_total += abs(mouse_delta.x) + abs(mouse_delta.y)
	} else if g.rmb_was_down {
		// Release.
		if g.rmb_drag_total < RMB_CLICK_THRESHOLD do rmb_clicked = true
	}
	g.rmb_was_down = p.mouse_right_down

	// Place / remove via mouse on the world (suppressed when over the picker bar)
	lmb_just := p.mouse_left_pressed
	shift_held := p->is_key_down(.Left_Shift) || p->is_key_down(.Right_Shift)
	if !mouse_in_picker && !mouse_in_panel && !g.world.game_over {
		if lmb_just && g.mode == .Place {
			if world_place(&g.world, hover, g.selected_kind) {
				if !shift_held do g.mode = .Default
			}
		} else if lmb_just && g.mode == .Default {
			if _, ok := g.world.tiles[hover]; ok {
				g.selected_tile = hover
				g.has_selection = true
			} else {
				g.has_selection = false
			}
		}
		if rmb_clicked {
			if g.mode == .Place {
				g.mode = .Default
			} else {
				world_remove(&g.world, hover)
			}
		}
	}

	g.prev_mouse = p.mouse

	// Fog-of-war lighting: every tile contributes a world-space halo so the
	// background's dark fade stays anchored to what the player has built,
	// instead of the centre of the screen. Done before set_camera so it's
	// independent of the current 2D affine.
	p->fog_lights_clear()
	for coord, _ in g.world.tiles {
		c := hex_to_pixel(coord)
		p->fog_lights_push(c.x, c.y)
	}

	// World pass
	scale, offset := camera_view(&g.cam, sw, sh)
	p->set_camera(scale, offset)
	world_render(&g.world, p)
	enemies_render(&g.world, p)
	projectiles_render(&g.world, p)
	particles_render(&g.world, p)

	// Exponential smoothing toward the hovered hex's pixel centre.
	// a = lerp(a, B, 1 - exp(-dt * RATE)) — frame-rate independent.
	HOVER_SMOOTH_RATE :: f32(30)
	hover_target := hex_to_pixel(hover)
	if !g.hover_smoothed_init {
		g.hover_smoothed = hover_target
		g.hover_smoothed_init = true
	} else {
		t := 1 - math.exp(-dt * HOVER_SMOOTH_RATE)
		g.hover_smoothed.x += (hover_target.x - g.hover_smoothed.x) * t
		g.hover_smoothed.y += (hover_target.y - g.hover_smoothed.y) * t
	}

	if !g.world.game_over {
		world_render_hover(&g.world, p, hover, g.hover_smoothed, g.mode == .Place, g.selected_kind)

		if g.mode == .Default && !mouse_in_picker && !mouse_in_panel {
			if _, ok := g.world.tiles[hover]; ok {
				draw_hex_outline(p, hover, 2.5, {1, 1, 1, 0.9})
			}
		}
		if g.has_selection {
			// Influence halo first so the bright selection outline draws on top.
			world_render_selection_influence(&g.world, p, g.selected_tile)
			draw_hex_outline(p, g.selected_tile, 3, {1, 1, 1, 1})
		}
	}

	// UI / screen-space pass
	p->clear_camera()

	font_small := p->font_size_px(.Small)
	font_large := p->font_size_px(.Large)

	// Picker bar background
	p->draw_rect(picker_x, picker_y, picker_w, picker_h, {0.10, 0.11, 0.14, 0.85})
	bx := picker_x + picker_pad
	by := picker_y + picker_pad
	bw := f32(132)
	bh := picker_h - picker_pad * 2
	for i in 0 ..< BUILDABLE_COUNT {
		kind := Tile_Kind(i)
		cost := tile_cost(kind)
		x := bx + f32(i) * (bw + 8)
		affordable := g.world.food >= cost
		if ui_button(&g.ui, p, "", x, by, bw, bh) {
			g.selected_kind = kind
			g.mode = .Place
			g.has_selection = false
		}

		// Tile icon, left-center.
		draw_tile_icon(p, x + 32, by + bh * 0.5, kind, 1)

		// Cost (food icon + number) right-aligned.
		cost_str := fmt.tprintf("%.0f", cost)
		cw := p->text_measure(cost_str, .Small)
		text_x := x + bw - 8 - cw
		text_y := by + bh * 0.5 + font_small * 0.35
		cost_color := affordable ? [4]f32{1, 1, 1, 1} : [4]f32{1, 0.55, 0.55, 1}
		p->draw_text(text_x, text_y, cost_str, cost_color, .Small)
		icon_s := f32(16)
		draw_food_icon(p, text_x - icon_s - 4, by + (bh - icon_s) * 0.5, icon_s)

		if !affordable {
			p->draw_rect(x, by, bw, bh, {0, 0, 0, 0.45})
		}
		if g.mode == .Place && kind == g.selected_kind {
			_, stroke := tile_color(kind)
			p->draw_line(x,        by,        x + bw, by,        2, stroke)
			p->draw_line(x,        by + bh,   x + bw, by + bh,   2, stroke)
			p->draw_line(x,        by,        x,      by + bh,   2, stroke)
			p->draw_line(x + bw,   by,        x + bw, by + bh,   2, stroke)
		}
	}

	// Top-left HUD — icon + value per row.
	core_hp := f32(0)
	if c, ok := g.world.tiles[g.world.core]; ok do core_hp = c.hp
	hud_icon_s := f32(18)
	hud_icon_x := f32(12)
	hud_text_x := hud_icon_x + hud_icon_s + 6
	row_y :: proc(n: f32, line: f32) -> f32 { return 12 + line * n + 4 * (n - 1) }
	icon_top :: proc(baseline_y, icon_size, line: f32) -> f32 {
		return baseline_y - icon_size + (icon_size - line) * 0.5 + 1
	}
	y1 := row_y(1, font_small)
	y2 := row_y(2, font_small)
	y3 := row_y(3, font_small)
	y4 := row_y(4, font_small)
	draw_food_icon (p, hud_icon_x, icon_top(y1, hud_icon_s, font_small), hud_icon_s)
	draw_scrap_icon(p, hud_icon_x, icon_top(y2, hud_icon_s, font_small), hud_icon_s)
	draw_core_icon (p, hud_icon_x, icon_top(y3, hud_icon_s, font_small), hud_icon_s)
	draw_enemy_icon(p, hud_icon_x, icon_top(y4, hud_icon_s, font_small), hud_icon_s)
	p->draw_text(hud_text_x, y1, fmt.tprintf("%d", i32(g.world.food)),                                    {0.92, 0.98, 0.78, 1}, .Small)
	p->draw_text(hud_text_x, y2, fmt.tprintf("%d", g.world.scrap),                                        {0.72, 0.83, 0.96, 1}, .Small)
	p->draw_text(hud_text_x, y3, fmt.tprintf("%.0f", core_hp),                                            {0.85, 0.82, 0.99, 1}, .Small)
	p->draw_text(hud_text_x, y4, fmt.tprintf("%d  [C] crawler  [B] brute", len(g.world.enemies)),         {0.96, 0.78, 0.78, 1}, .Small)

	// Big timer at top-center.
	timer_str := fmt.tprintf("%.1fs", g.world.survive_time)
	tw_timer := p->text_measure(timer_str, .Large)
	timer_y := f32(16) + font_large
	p->draw_text((sw - tw_timer) * 0.5, timer_y, timer_str, {0.95, 0.95, 0.98, 1}, .Large)

	// Surge countdown directly underneath, with the current wave number.
	// During an active surge the wave is `last_surge_num` (the one firing);
	// otherwise it's `surge_index + 1` (the wave that's coming next).
	wave_num: i32
	if g.world.waves.surge_active {
		wave_num = g.world.waves.last_surge_num
	} else {
		wave_num = g.world.waves.surge_index + 1
	}
	if g.world.waves.surge_active {
		active_str := fmt.tprintf("WAVE %d  -  SURGE ACTIVE", wave_num)
		aw := p->text_measure(active_str, .Small)
		p->draw_text((sw - aw) * 0.5, timer_y + 14, active_str, {1.00, 0.55, 0.55, 1}, .Small)
	} else {
		rem := waves_time_to_next_surge(&g.world.waves)
		cd_str := fmt.tprintf("Wave %d  -  next surge in %.0fs", wave_num, rem)
		cw := p->text_measure(cd_str, .Small)
		p->draw_text((sw - cw) * 0.5, timer_y + 14, cd_str, {0.78, 0.82, 0.92, 1}, .Small)
	}

	// SURGE WAVE banner — flashes for ~3 seconds when a surge fires.
	if g.world.waves.banner_time > 0 {
		banner_str := fmt.tprintf("SURGE WAVE %d", g.world.waves.last_surge_num)
		bw_banner := p->text_measure(banner_str, .Large)
		alpha := g.world.waves.banner_time / WAVE_BANNER_DURATION
		if alpha > 1 do alpha = 1
		if alpha < 0 do alpha = 0
		p->draw_text((sw - bw_banner) * 0.5, sh * 0.5, banner_str, {1.00, 0.30, 0.30, alpha}, .Large)
	}

	// Selection panel.
	if g.has_selection {
		tile := g.world.tiles[g.selected_tile]
		max_hp := tile_max_hp(tile.kind, tile.tier)
		cost := tile_cost(tile.kind)

		p->draw_rect(panel_x, panel_y, PANEL_W, PANEL_H, {0.10, 0.11, 0.14, 0.92})
		p->draw_line(panel_x, panel_y, panel_x + PANEL_W, panel_y, 1, {1, 1, 1, 0.15})
		p->draw_line(panel_x, panel_y + PANEL_H, panel_x + PANEL_W, panel_y + PANEL_H, 1, {0, 0, 0, 0.40})

		title := tile_kind_name(tile.kind)
		tw_title := p->text_measure(title, .Large)
		p->draw_text(panel_x + (PANEL_W - tw_title) * 0.5, panel_y + 12 + font_large, title, {0.95, 0.95, 0.98, 1}, .Large)

		// Tier subtitle (e.g. "Tier 2 / 3"). Hidden for non-upgradeable kinds.
		if tile_is_upgradeable(tile.kind) {
			tier_str := fmt.tprintf("Tier %d / %d", tile.tier, tile_max_tier(tile.kind))
			tw_tier := p->text_measure(tier_str, .Small)
			p->draw_text(panel_x + (PANEL_W - tw_tier) * 0.5, panel_y + 12 + font_large + font_small + 4, tier_str, {0.78, 0.82, 0.92, 1}, .Small)
		}

		hp_y := panel_y + 12 + font_large + 24
		hp_str := fmt.tprintf("HP  %.0f / %.0f", tile.hp, max_hp)
		p->draw_text(panel_x + 16, hp_y + font_small, hp_str, {0.85, 0.90, 0.98, 1}, .Small)

		bar_x := panel_x + 16
		bar_y := hp_y + font_small + 8
		bar_w := PANEL_W - 32
		bar_h := f32(8)
		frac := max_hp > 0 ? tile.hp / max_hp : 0
		if frac < 0 do frac = 0
		if frac > 1 do frac = 1
		p->draw_rect(bar_x, bar_y, bar_w, bar_h, {0.05, 0.06, 0.08, 1})
		p->draw_rect(bar_x, bar_y, bar_w * frac, bar_h, {0.45, 0.85, 0.55, 1})

		btn_w := PANEL_W - 32
		btn_h := f32(36)
		btn_x := panel_x + 16
		sell_y := panel_y + PANEL_H - 16 - btn_h * 2 - 8
		upgrade_y := panel_y + PANEL_H - 16 - btn_h

		can_sell := tile.kind != .Core
		refund := i32(cost * 0.5)

		// Wire/Core have no upgrade path — collapse the layout so Sell takes
		// the bottom slot rather than leaving an empty button hovering.
		if !tile_is_upgradeable(tile.kind) {
			sell_y = upgrade_y
		}

		// Sell button: "Sell  +N <food icon>" (or "Sell  (locked)" for Core).
		if can_sell {
			if button_with_food_cost(&g.ui, p, "Sell", refund, .Gain, btn_x, sell_y, btn_w, btn_h) {
				world_sell(&g.world, g.selected_tile)
				g.has_selection = false
			}
		} else {
			ui_button_at(&g.ui, p, "Sell  (locked)", btn_x, sell_y, btn_w, btn_h)
		}

		if tile_is_upgradeable(tile.kind) {
			at_max := tile.tier >= tile_max_tier(tile.kind)
			up_cost := tile_upgrade_cost(tile.kind, tile.tier)
			can_up := !at_max && g.world.food >= up_cost
			clicked: bool
			switch {
			case at_max:
				ui_button_at(&g.ui, p, "Upgrade  (max)", btn_x, upgrade_y, btn_w, btn_h)
			case:
				clicked = button_with_food_cost(&g.ui, p, "Upgrade", i32(up_cost), .Spend, btn_x, upgrade_y, btn_w, btn_h)
			}
			if clicked && can_up {
				world_upgrade(&g.world, g.selected_tile)
			}
		}
	}

	mode_label := g.mode == .Place ? "PLACE (shift = multi)" : "SELECT"
	stats := fmt.tprintf("fps %.0f  %.2fms  zoom %.2f  hover (%d, %d)  mode: %s  kind: %s",
		g.fps, g.frame_ms, g.cam.zoom, hover.x, hover.y, mode_label, tile_kind_name(g.selected_kind))
	p->draw_text(12, sh - 12 - picker_h - 12 - font_small, stats, {0.65, 0.70, 0.78, 1}, .Small)

	if g.world.game_over {
		p->draw_rect(0, 0, sw, sh, {0, 0, 0, 0.65})
		head := "CORE DESTROYED"
		body := fmt.tprintf("Survived %.1fs   |   Scrap collected: %d", g.world.survive_time, g.world.scrap)
		tip  := "Press R to restart"
		hw := p->text_measure(head, .Large)
		bw := p->text_measure(body, .Small)
		tw := p->text_measure(tip,  .Small)
		cy := sh * 0.5
		p->draw_text((sw - hw) * 0.5, cy - 28, head, {1.00, 0.82, 0.82, 1}, .Large)
		p->draw_text((sw - bw) * 0.5, cy + 24, body, {0.96, 0.96, 0.96, 1},  .Small)
		p->draw_text((sw - tw) * 0.5, cy + 56, tip,  {0.78, 0.86, 1.00, 1},  .Small)
	}
}
