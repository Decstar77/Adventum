package game

import "core:fmt"
import "core:math"

// Game owns all simulation + UI state. The host (win32, web, ...) constructs
// one of these, calls game_init, then drives game_update_and_render(g, p) each
// frame after filling in the per-frame fields of `p`.

Selection_Mode :: enum {
	Default,
	Place,
	// Bomb-targeting cursor — the next world click drops a bomb at the hovered
	// hex's pixel centre (instead of the usual selection). Cleared by clicking,
	// escape, RMB, or pressing Q again.
	Target_Bomb,
}

Game :: struct {
	world: World,
	cam:   Camera,
	ui:    UI,

	mode:          Selection_Mode,
	selected_kind: Tile_Kind,
	selected_tile: Hex_Coord,
	has_selection: bool,

	// Pause menu. Volume persists across sessions via the host's save_f32
	// (CrazyGames cloud save / localStorage on web).
	paused:           bool,
	show_controls:    bool,
	volume:           f32,
	volume_dragging:  bool,
	volume_was_dragging: bool, // edge-detect drag release to trigger save

	// Best survival time across runs. Loaded at game_init via the host's
	// load_f32, written on game-over / victory when the current run beats it.
	best_time:        f32,
	run_result_saved: bool, // one-shot guard so we only save once per run

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
PANEL_H :: f32(280)

Cost_Sign :: enum { Spend, Gain }

// Button with a label followed by a signed cost and a food icon, e.g.
// "Upgrade  -15 [food]" or "Sell  +7 [food]". The label, number, and icon
// are centered together as one cluster so the spacing reads as a single tag.
button_with_food_cost :: proc(ui: ^UI, p: ^Platform, label: string, amount: i32, sign: Cost_Sign, x, y, w, h: f32, disabled: bool = false) -> bool {
	hover := !disabled && point_in_rect(p.mouse, x, y, w, h)
	held  := hover && p.mouse_left_down
	ui_track_hover(ui, p, hover, ui_button_key(x, y))

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

	label_tint := disabled ? [4]f32{0.7, 0.7, 0.75, 1} : [4]f32{1, 1, 1, 1}
	tint_spend := disabled ? [4]f32{0.9, 0.6, 0.6, 1} : [4]f32{1.0, 0.78, 0.78, 1}
	tint_gain  := disabled ? [4]f32{0.7, 0.85, 0.7, 1} : [4]f32{0.85, 1.0, 0.80, 1}
	tint := sign == .Spend ? tint_spend : tint_gain
	p->draw_text(cx0,                                        ty, label,   label_tint, .Small)
	p->draw_text(cx0 + label_w + gap_label_num,              ty, num_str, tint,       .Small)
	icon_x := cx0 + label_w + gap_label_num + num_w + gap_num_icon
	icon_y := y + (h - icon_s) * 0.5
	draw_food_icon(p, icon_x, icon_y, icon_s)

	if disabled {
		p->draw_rect(x, y, w, h, {0, 0, 0, 0.40})
	}

	clicked := hover && p.mouse_left_pressed
	if clicked do p->play_sound(.Button_Click)
	return clicked
}

// Same shape as button_with_food_cost but renders the cost in scrap. Repair is
// the only scrap-spend button on the selection panel right now, but the helper
// is generic so it can host future scrap-priced actions without copy/paste.
button_with_scrap_cost :: proc(ui: ^UI, p: ^Platform, label: string, amount: i32, x, y, w, h: f32, disabled: bool = false) -> bool {
	hover := !disabled && point_in_rect(p.mouse, x, y, w, h)
	held  := hover && p.mouse_left_down
	ui_track_hover(ui, p, hover, ui_button_key(x, y))

	BASE  := [4]f32{0.18, 0.20, 0.26, 1.0}
	HOVER := [4]f32{0.26, 0.30, 0.40, 1.0}
	HELD  := [4]f32{0.10, 0.12, 0.16, 1.0}

	bg := BASE
	if held       do bg = HELD
	else if hover do bg = HOVER

	p->draw_rect(x, y, w, h, bg)
	p->draw_line(x, y,     x + w, y,     1, {1, 1, 1, 0.15})
	p->draw_line(x, y + h, x + w, y + h, 1, {0, 0, 0, 0.40})

	num_str := fmt.tprintf("-%d", amount)
	gap_label_num := f32(12)
	gap_num_icon  := f32(4)
	icon_s        := f32(16)

	label_w := p->text_measure(label,   .Small)
	num_w   := p->text_measure(num_str, .Small)
	total_w := label_w + gap_label_num + num_w + gap_num_icon + icon_s

	cx0 := x + (w - total_w) * 0.5
	font_small := p->font_size_px(.Small)
	ty := y + h * 0.5 + font_small * 0.3

	label_tint := disabled ? [4]f32{0.7, 0.7, 0.75, 1} : [4]f32{1, 1, 1, 1}
	num_tint   := disabled ? [4]f32{0.9, 0.6, 0.6, 1}  : [4]f32{0.78, 0.86, 1.00, 1}
	p->draw_text(cx0,                                        ty, label,   label_tint, .Small)
	p->draw_text(cx0 + label_w + gap_label_num,              ty, num_str, num_tint,   .Small)
	icon_x := cx0 + label_w + gap_label_num + num_w + gap_num_icon
	icon_y := y + (h - icon_s) * 0.5
	draw_scrap_icon(p, icon_x, icon_y, icon_s)

	if disabled {
		p->draw_rect(x, y, w, h, {0, 0, 0, 0.40})
	}

	clicked := hover && p.mouse_left_pressed
	if clicked do p->play_sound(.Button_Click)
	return clicked
}

TICK_HZ :: 10.0
TICK_DT :: f32(1.0 / TICK_HZ)

@(private="file")
HOTKEYS := [BUILDABLE_COUNT]Key{
	.Num1, .Num2, .Num3, .Num4, .Num5, .Num6, .Num7,
}

game_init :: proc(g: ^Game, p: ^Platform) {
	g.cam = Camera{pos = {0, 0}, zoom = 1}
	g.selected_kind = .Farm
	g.mode = .Default
	g.volume = p.load_f32 != nil ? p->load_f32("volume", 0.1) : 0.1
	if g.volume < 0 do g.volume = 0
	if g.volume > 1 do g.volume = 1
	g.best_time = p.load_f32 != nil ? p->load_f32("best_time", 0) : 0
	world_init(&g.world)
	// Initial energization pass so the Core's energized flag is correct from frame 0.
	world_tick(&g.world, 0)
}

game_shutdown :: proc(g: ^Game) {
	world_shutdown(&g.world)
	ui_shutdown(&g.ui)
}

// Reset the world to a fresh start. Used by the game-over `R` shortcut and the
// pause-menu Restart button. Volume is preserved across restarts.
game_restart :: proc(g: ^Game) {
	world_shutdown(&g.world)
	g.world = World{}
	world_init(&g.world)
	world_tick(&g.world, 0)
	g.cam = Camera{pos = {0, 0}, zoom = 1}
	g.selected_kind = .Farm
	g.mode = .Default
	g.has_selection = false
	g.tick_accum = 0
	g.paused = false
	g.show_controls = false
	g.run_result_saved = false
}

// Stylised gear icon for the pause-menu button — four cardinal teeth, a body
// disc, and a darker hole. We don't have rotated quads, so the teeth sit on
// the axes; that's enough to read as a gear at this size.
// Fullscreen toggle icon — four L-shaped corner brackets pointing outward,
// matching the universal "expand to fullscreen" glyph. We draw the same shape
// regardless of current fullscreen state since the host doesn't tell us back
// whether we're in fullscreen.
draw_fullscreen_icon :: proc(p: ^Platform, cx, cy, s: f32, color: [4]f32) {
	r := s * 0.5      // half-extent
	t := s * 0.12     // bracket thickness
	l := s * 0.28     // bracket arm length
	// Top-left corner: horizontal bar + vertical bar meeting at (cx-r, cy-r).
	p->draw_rect(cx - r,       cy - r,       l, t, color)
	p->draw_rect(cx - r,       cy - r,       t, l, color)
	// Top-right corner.
	p->draw_rect(cx + r - l,   cy - r,       l, t, color)
	p->draw_rect(cx + r - t,   cy - r,       t, l, color)
	// Bottom-left corner.
	p->draw_rect(cx - r,       cy + r - t,   l, t, color)
	p->draw_rect(cx - r,       cy + r - l,   t, l, color)
	// Bottom-right corner.
	p->draw_rect(cx + r - l,   cy + r - t,   l, t, color)
	p->draw_rect(cx + r - t,   cy + r - l,   t, l, color)
}

draw_gear_icon :: proc(p: ^Platform, cx, cy, s: f32, color: [4]f32) {
	r := s * 0.5
	tw := s * 0.20
	th := s * 0.22
	p->draw_rect(cx - tw*0.5, cy - r,        tw, th, color)
	p->draw_rect(cx - tw*0.5, cy + r - th,   tw, th, color)
	p->draw_rect(cx - r,        cy - tw*0.5, th, tw, color)
	p->draw_rect(cx + r - th,   cy - tw*0.5, th, tw, color)
	p->draw_circle(cx, cy, r * 0.78, color)
	p->draw_circle(cx, cy, r * 0.28, {0.10, 0.11, 0.14, 1})
}

game_update_and_render :: proc(g: ^Game, p: ^Platform) {
	dt := p.dt
	sw := p.screen_w
	sh := p.screen_h

	// Push the current master volume to the host so the audio engine tracks the
	// pause-menu slider in real time. Done first so any sounds emitted this
	// frame (button clicks, simulation events) play at the right level.
	p.master_volume = g.volume

	// Lifecycle hint for embedded hosts (CrazyGames gameplayStart/Stop, ad
	// SDKs). Active iff a run is in progress and the player isn't on a modal
	// (pause menu, game-over, victory). Hosts edge-detect on transitions.
	p.gameplay_active = !g.paused && !g.world.game_over && !g.world.victory

	// Persist volume on slider release. Saving every frame during drag would
	// be wasteful (and CrazyGames cloud save is rate-limited), so we wait for
	// the drag to end and write once.
	if g.volume_was_dragging && !g.volume_dragging {
		if p.save_f32 != nil do p->save_f32("volume", g.volume)
	}
	g.volume_was_dragging = g.volume_dragging

	// Persist best survival time once per run when the run resolves. Both
	// game-over and victory count — survival is survival.
	if !g.run_result_saved && (g.world.game_over || g.world.victory) {
		if g.world.survive_time > g.best_time {
			g.best_time = g.world.survive_time
			if p.save_f32 != nil do p->save_f32("best_time", g.best_time)
		}
		// CrazyGames hooks. Midgame interstitial on death (between runs, never
		// between waves); happytime only on victory (final wave cleared). Both
		// gated by `run_result_saved` so they fire exactly once per run.
		if g.world.game_over && p.request_midgame_ad != nil {
			p->request_midgame_ad()
		}
		if g.world.victory && p.request_happytime != nil {
			p->request_happytime()
		}
		g.run_result_saved = true
	}

	// Listener position: the camera centre, in the same world-pixel space the
	// simulation queues sounds in. Zoom is deliberately ignored — the audio
	// "ear" stays at fixed scale even when the player zooms out, which keeps
	// the panning intuitive (a sound at the right edge of the screen still
	// reads as "to the right") regardless of how much world is on screen.
	p.listener_x = g.cam.pos.x
	p.listener_y = g.cam.pos.y

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

	// Escape opens the pause menu when nothing else needs cancelling. If the
	// player is mid-placement or has a tile selected, escape clears that first
	// (preserves the long-standing muscle memory) — second press pauses.
	if p->is_key_just_pressed(.Escape) {
		switch {
		case g.paused && g.show_controls:
			g.show_controls = false
		case g.paused:
			g.paused = false
		case g.mode == .Place || g.mode == .Target_Bomb || g.has_selection:
			g.mode = .Default
			g.has_selection = false
		case:
			g.paused = true
		}
	}

	paused := g.paused

	// Camera pan via WASD plus an edge-of-screen mouse pan.
	PAN_SPEED       :: f32(400)
	EDGE_MARGIN     :: f32(24)
	EDGE_PAN_SPEED  :: f32(550)
	pan: [2]f32
	if !paused && p->is_key_down(.W) do pan.y -= 1
	if !paused && p->is_key_down(.S) do pan.y += 1
	if !paused && p->is_key_down(.A) do pan.x -= 1
	if !paused && p->is_key_down(.D) do pan.x += 1
	if pan.x != 0 || pan.y != 0 {
		g.cam.pos += pan * (PAN_SPEED * dt / g.cam.zoom)
	}

	// Mouse edge scroll: only when the cursor is inside the window. Pan
	// speed ramps from 0 at EDGE_MARGIN inward to full speed at the edge.
	// Suppressed while RMB is held — that gesture is already a pan, and on
	// touch (where a drag synthesises RMB) the finger sitting at the screen
	// edge during a pan would otherwise double the camera velocity.
	if !paused && !p.mouse_right_down && p.mouse.x >= 0 && p.mouse.y >= 0 && p.mouse.x < sw && p.mouse.y < sh {
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
	if !paused && shift_down && p->is_key_just_pressed(.Enter) {
		p->toggle_fullscreen()
	}

	if !paused && p.scroll_dy != 0 {
		before := camera_screen_to_world(&g.cam, p.mouse, sw, sh)
		zoom_factor := f32(1) + p.scroll_dy * 0.1
		g.cam.zoom *= zoom_factor
		if g.cam.zoom < 0.6 do g.cam.zoom = 0.6
		if g.cam.zoom > 1.2   do g.cam.zoom = 1.2
		after := camera_screen_to_world(&g.cam, p.mouse, sw, sh)
		g.cam.pos += before - after
	}

	if !paused {
		for k, i in HOTKEYS {
			if p->is_key_just_pressed(k) {
				g.selected_kind = Tile_Kind(i)
				g.mode = .Place
				g.has_selection = false
			}
		}
	}

	// Drop stale selection (tile sold or destroyed).
	if g.has_selection {
		if _, ok := g.world.tiles[g.selected_tile]; !ok do g.has_selection = false
	}

	if !paused && !g.world.game_over && !g.world.victory {
		if p->is_key_just_pressed(.C) do enemy_spawn(&g.world, .Crawler)
		if p->is_key_just_pressed(.B) do enemy_spawn(&g.world, .Brute)
		if p->is_key_just_pressed(.V) do enemy_spawn(&g.world, .Spitter)
		if p->is_key_just_pressed(.N) do enemy_spawn(&g.world, .Swarmer)
		if p->is_key_just_pressed(.F) do enemy_spawn(&g.world, .Flyer)

		// Ability hotkeys. Q enters bomb-target mode (acts like Place but for
		// a one-shot AoE); E fires the EMP instantly. Both gate on the
		// affordability checks inside their `world_use_*` procs.
		if p->is_key_just_pressed(.Q) && world_can_use_bomb(&g.world) {
			g.mode = .Target_Bomb
			g.has_selection = false
		}
		if p->is_key_just_pressed(.E) {
			if world_use_emp(&g.world) {
				p->play_sound(.Emp)
			}
		}
		// F6: skip the surge cooldown and fire the next wave on this frame.
		// Also latches Core invincibility on so the debug fast-forward can't
		// kill the run mid-test. Press again to re-fire surges; invincibility
		// stays on until the next `game_restart`.
		if p->is_key_just_pressed(.F6) {
			waves_force_next_surge(&g.world.waves)
			g.world.core_invincible = true
			g.world.food  = 10000
			g.world.scrap = 10000
			g.world.bomb_cooldown = 0 
		}

		// Space upgrades the selected tile — same affordability/cap rules as
		// the panel's Upgrade button, just bound to a hotkey for convenience.
		if g.has_selection && p->is_key_just_pressed(.Space) {
			if tile, ok := g.world.tiles[g.selected_tile]; ok && tile_is_upgradeable(tile.kind) {
				if tile.tier < tile_max_tier(tile.kind) && g.world.food >= tile_upgrade_cost(tile.kind, tile.tier) {
					world_upgrade(&g.world, g.selected_tile)
					p->play_sound(.Upgrade)
				}
			}
		}
	}

	if !paused && (g.world.game_over || g.world.victory) && p->is_key_just_pressed(.R) {
		game_restart(g)
	}

	if !paused && !g.world.game_over && !g.world.victory {
		g.world.survive_time += dt

		g.tick_accum += dt
		for g.tick_accum >= TICK_DT {
			world_tick(&g.world, TICK_DT)
			g.tick_accum -= TICK_DT
		}

		waves_update(&g.world, &g.world.waves, dt)
		turrets_fire(&g.world, dt)
		mortars_fire(&g.world, dt)
		flaks_fire(&g.world, dt)
		projectiles_update(&g.world, dt)
		enemy_projectiles_update(&g.world, dt)
		enemies_update(&g.world, dt)
		sweep_dead_enemies(&g.world)
		particles_update(&g.world, dt)

		if c, ok := g.world.tiles[g.world.core]; ok {
			if g.world.core_invincible {
				c.hp = tile_max_hp(.Core, c.tier)
				g.world.tiles[g.world.core] = c
			} else if c.hp <= 0 {
				g.world.game_over = true
			}
		}

		// Victory: the final wave fired, ended, and every enemy on the field is
		// dead. Trickle still ticks past the final surge — but the early-return
		// in `waves_update` blocks any further surges, so once the player
		// catches up to the trickle the field genuinely clears.
		if !g.world.game_over &&
		   g.world.waves.surge_index > FINAL_WAVE_INDEX &&
		   !g.world.waves.surge_active &&
		   len(g.world.enemies) == 0 {
			g.world.victory = true
		}
	} else {
		// While paused / game-over `flaks_fire` doesn't run, so its per-frame
		// reset never happens. Force the engaged flag down so the looped audio
		// definitely stops the moment gameplay halts.
		g.world.flak_firing = false
	}

	// Drive the looped flak-cannon SFX. Idempotent on both edges — the host
	// only starts/stops the underlying voice on a transition, so calling this
	// every frame is cheap.
	p->set_sound_loop(.Flak_Cannon_Loop, g.world.flak_firing, g.world.flak_firing_pos.x, g.world.flak_firing_pos.y)

	// Flush the simulation's queued sounds. Positional entries are forwarded
	// to `play_sound_at` so the host can pan/attenuate; non-positional ones
	// (UI cues, EMP cast) go to `play_sound`. We cap how many *positional*
	// plays per family fire in one frame — eighteen turrets firing on the
	// same tick used to be a wall of noise; now we play at most a couple so
	// spatial diversity remains while bounded. UI / non-positional families
	// collapse to one play per frame as before. Even with this cap the host
	// applies its own per-family cooldown + concurrent-voice cap, so the
	// effective rate per family is much lower than `LIMIT × fps` would
	// suggest.
	POSITIONAL_PER_FAMILY_LIMIT :: 2
	pos_count:    [Sound]i32
	seen_nonpos:  [Sound]bool
	for q in g.world.sound_queue {
		if q.has_pos {
			if pos_count[q.kind] >= POSITIONAL_PER_FAMILY_LIMIT do continue
			pos_count[q.kind] += 1
			p->play_sound_at(q.kind, q.pos.x, q.pos.y)
		} else {
			if seen_nonpos[q.kind] do continue
			seen_nonpos[q.kind] = true
			p->play_sound(q.kind)
		}
	}
	clear(&g.world.sound_queue)

	// Picker bar layout (used both for hit-test and for drawing later)
	picker_h    := f32(56)
	picker_pad  := f32(8)
	picker_y    := sh - picker_h - 12
	picker_w    := f32(BUILDABLE_COUNT) * 132 + f32(BUILDABLE_COUNT - 1) * 8 + picker_pad * 2
	picker_x    := (sw - picker_w) * 0.5
	mouse_in_picker := point_in_rect(p.mouse, picker_x, picker_y, picker_w, picker_h)

	// Right-side selection panel (only visible when something is selected).
	// Vertically centred on the right edge so it sits clear of the gear +
	// ability stack in the top-right corner.
	panel_x := sw - PANEL_W - 12
	panel_y := (sh - PANEL_H) * 0.5
	mouse_in_panel := g.has_selection && point_in_rect(p.mouse, panel_x, panel_y, PANEL_W, PANEL_H)

	// Gear button (top-right). Always above other UI so the player can pause
	// even mid-placement; we suppress world clicks underneath it as well.
	GEAR_S := f32(36)
	gear_x := sw - 12 - GEAR_S
	gear_y := f32(12)
	mouse_in_gear := point_in_rect(p.mouse, gear_x, gear_y, GEAR_S, GEAR_S)
	ui_track_hover(&g.ui, p, mouse_in_gear, ui_button_key(gear_x, gear_y))
	if !paused && mouse_in_gear && p.mouse_left_pressed {
		g.paused = true
		p->play_sound(.Button_Click)
	}

	// Fullscreen toggle sits immediately left of the gear at the same size.
	// Shift+Enter is the keyboard equivalent; this button exists for players
	// on touch / CrazyGames reviewers who don't know that shortcut.
	fs_x := gear_x - GEAR_S - 8
	fs_y := gear_y
	mouse_in_fs := point_in_rect(p.mouse, fs_x, fs_y, GEAR_S, GEAR_S)
	ui_track_hover(&g.ui, p, mouse_in_fs, ui_button_key(fs_x, fs_y))
	if !paused && mouse_in_fs && p.mouse_left_pressed {
		p->toggle_fullscreen()
		p->play_sound(.Button_Click)
	}

	// Core ability buttons live directly under the gear: [Bomb (Q)] [EMP (E)].
	// Wider than the gear so the cost lines and cooldown text fit; placed
	// before the world hit-tests so clicks on them don't fall through to the
	// hex grid underneath.
	ABIL_W :: f32(112)
	ABIL_H :: f32(52)
	ABIL_GAP :: f32(6)
	bomb_x := sw - 12 - ABIL_W
	bomb_y := gear_y + GEAR_S + 10
	emp_x  := bomb_x
	emp_y  := bomb_y + ABIL_H + ABIL_GAP
	mouse_in_bomb := point_in_rect(p.mouse, bomb_x, bomb_y, ABIL_W, ABIL_H)
	mouse_in_emp  := point_in_rect(p.mouse, emp_x,  emp_y,  ABIL_W, ABIL_H)
	mouse_in_abilities := mouse_in_bomb || mouse_in_emp
	ui_track_hover(&g.ui, p, mouse_in_bomb, ui_button_key(bomb_x, bomb_y))
	ui_track_hover(&g.ui, p, mouse_in_emp,  ui_button_key(emp_x,  emp_y))
	if !paused && !g.world.game_over && !g.world.victory {
		if mouse_in_bomb && p.mouse_left_pressed && world_can_use_bomb(&g.world) {
			g.mode = .Target_Bomb
			g.has_selection = false
			p->play_sound(.Button_Click)
		}
		if mouse_in_emp && p.mouse_left_pressed {
			if world_use_emp(&g.world) do p->play_sound(.Emp)
		}
	}

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
	if !paused && p.mouse_right_down {
		if !g.rmb_was_down {
			g.rmb_drag_total = 0
		} else if g.cam.zoom > 0 {
			// Pan opposite the drag direction so the world feels grabbed.
			g.cam.pos -= mouse_delta / g.cam.zoom
		}
		g.rmb_drag_total += abs(mouse_delta.x) + abs(mouse_delta.y)
	} else if !paused && g.rmb_was_down {
		// Release.
		if g.rmb_drag_total < RMB_CLICK_THRESHOLD do rmb_clicked = true
	}
	g.rmb_was_down = !paused && p.mouse_right_down

	// Place / remove via mouse on the world (suppressed when over the picker bar)
	lmb_just := p.mouse_left_pressed
	shift_held := p->is_key_down(.Left_Shift) || p->is_key_down(.Right_Shift)
	if !paused && !mouse_in_picker && !mouse_in_panel && !mouse_in_gear && !mouse_in_fs && !mouse_in_abilities && !g.world.game_over && !g.world.victory {
		if lmb_just && g.mode == .Target_Bomb {
			// Drop the bomb at the hovered hex's pixel centre so the AoE
			// reads as anchored to a tile rather than a cursor pixel.
			tgt := hex_to_pixel(hover)
			if world_use_bomb(&g.world, tgt) {
				g.mode = .Default
			}
		} else if lmb_just && g.mode == .Place {
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
			// Mirror Escape: clear placement/target mode and drop any tile
			// selection. Right-click no longer removes tiles — selling lives on
			// the selection panel, and accidental RMB-removes were too easy.
			g.mode = .Default
			g.has_selection = false
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
	enemy_projectiles_render(&g.world, p)
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

	if !g.world.game_over && !g.world.victory {
		world_render_hover(&g.world, p, hover, g.hover_smoothed, g.mode == .Place, g.selected_kind)

		// Bomb-target preview: orange ring at exactly the damage radius so the
		// player knows what they're about to vaporise.
		if g.mode == .Target_Bomb {
			tgt := hex_to_pixel(hover)
			ring := [4]f32{1.0, 0.55, 0.20, 0.85}
			p->draw_circle(tgt.x, tgt.y, BOMB_RADIUS,        {1.0, 0.55, 0.20, 0.18})
			draw_hex_outline_at(p, tgt, 2.5, ring)
			// Coarse ring approximation using line segments.
			SEG :: 36
			prev_x := tgt.x + BOMB_RADIUS
			prev_y := tgt.y
			for i in 1 ..= SEG {
				a := f32(i) * (2 * math.PI / SEG)
				nx := tgt.x + math.cos(a) * BOMB_RADIUS
				ny := tgt.y + math.sin(a) * BOMB_RADIUS
				p->draw_line(prev_x, prev_y, nx, ny, 2, ring)
				prev_x, prev_y = nx, ny
			}
		}

		if g.mode == .Default && !mouse_in_picker && !mouse_in_panel && !mouse_in_gear && !mouse_in_fs && !mouse_in_abilities && !paused {
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
	mortar_locked := !mortar_unlocked(&g.world)
	flak_locked   := !flak_unlocked(&g.world)
	for i in 0 ..< BUILDABLE_COUNT {
		kind := Tile_Kind(i)
		cost := tile_cost(kind)
		x := bx + f32(i) * (bw + 8)
		affordable := g.world.food >= cost
		// Mortar / Flak read as locked until the Core hits the required tier —
		// clicks are silently consumed so the player can't enter Place mode and
		// stare at red placement outlines wondering why nothing drops.
		locked := (kind == .Mortar && mortar_locked) || (kind == .Flak && flak_locked)
		clicked := ui_button(&g.ui, p, "", x, by, bw, bh)
		if clicked && !locked {
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

		if !affordable || locked {
			p->draw_rect(x, by, bw, bh, {0, 0, 0, 0.45})
		}
		if locked {
			// Tag the slot with the unlock requirement so the lockout reads
			// as a tier gate rather than just "you're broke".
			req := kind == .Flak ? FLAK_CORE_TIER_REQ : MORTAR_CORE_TIER_REQ
			tag := fmt.tprintf("Core T%d", req)
			tw_tag := p->text_measure(tag, .Small)
			p->draw_text(x + (bw - tw_tag) * 0.5, by + 14, tag, {0.95, 0.85, 0.55, 1}, .Small)
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
	// Per-kind tally so a "huge" total can be read at a glance — useful for
	// spotting trickle pile-up vs. a fresh surge. Hotkeys live on the same row
	// since they're a debug spawn aid that pairs with the same vocabulary.
	enemy_crawlers, enemy_brutes, enemy_spitters, enemy_swarmers, enemy_flyers, enemy_bosses: i32
	for e in g.world.enemies {
		switch e.kind {
		case .Crawler:      enemy_crawlers += 1
		case .Brute:        enemy_brutes   += 1
		case .Spitter:      enemy_spitters += 1
		case .Swarmer:      enemy_swarmers += 1
		case .Flyer:        enemy_flyers   += 1
		case .Brute_Boss, .Spitter_Boss, .Flyer_Boss: enemy_bosses += 1
		}
	}
	count_str: string
	if enemy_bosses > 0 {
		count_str = fmt.tprintf("%d  (C %d  B %d  V %d  N %d  F %d  BOSS %d)", len(g.world.enemies), enemy_crawlers, enemy_brutes, enemy_spitters, enemy_swarmers, enemy_flyers, enemy_bosses)
	} else {
		count_str = fmt.tprintf("%d  (C %d  B %d  V %d  N %d  F %d)", len(g.world.enemies), enemy_crawlers, enemy_brutes, enemy_spitters, enemy_swarmers, enemy_flyers)
	}
	p->draw_text(hud_text_x, y4, count_str, {0.96, 0.78, 0.78, 1}, .Small)

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
		// Stack from the bottom: Upgrade (bottom-most for upgradeable tiles),
		// Sell above it, Repair above Sell. Non-upgradeable tiles collapse the
		// upgrade slot so Repair/Sell pack flush.
		upgrade_y := panel_y + PANEL_H - 16 - btn_h
		sell_y    := upgrade_y - btn_h - 8
		repair_y  := sell_y    - btn_h - 8

		can_sell := tile.kind != .Core
		refund := i32(cost * 0.5)

		if !tile_is_upgradeable(tile.kind) {
			sell_y    = upgrade_y
			repair_y  = sell_y - btn_h - 8
		}

		// Repair: spend scrap to top this tile back up to full HP. Disabled
		// when at max-HP or short on scrap.
		_, repair_cost, repairable := tile_repair_quote(&g.world, g.selected_tile)
		can_repair := repairable && g.world.scrap >= repair_cost
		label := repairable ? "Repair" : "Repair  (full)"
		if button_with_scrap_cost(&g.ui, p, label, repair_cost, btn_x, repair_y, btn_w, btn_h, !can_repair) {
			if can_repair {
				world_repair(&g.world, g.selected_tile)
				p->play_sound(.Repair)
			}
		}

		// Sell button: "Sell  +N <food icon>" (or "Sell  (locked)" for Core).
		if can_sell {
			if button_with_food_cost(&g.ui, p, "Sell", refund, .Gain, btn_x, sell_y, btn_w, btn_h) {
				world_sell(&g.world, g.selected_tile)
				p->play_sound(.Sell)
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
				clicked = button_with_food_cost(&g.ui, p, "Upgrade", i32(up_cost), .Spend, btn_x, upgrade_y, btn_w, btn_h, !can_up)
			}
			if clicked && can_up {
				world_upgrade(&g.world, g.selected_tile)
				p->play_sound(.Upgrade)
			}
		}
	}

	mode_label := g.mode == .Place ? "PLACE (shift = multi)" : "SELECT"
	stats := fmt.tprintf("fps %.0f  %.2fms  zoom %.2f  hover (%d, %d)  mode: %s  kind: %s",
		g.fps, g.frame_ms, g.cam.zoom, hover.x, hover.y, mode_label, tile_kind_name(g.selected_kind))
	p->draw_text(12, sh - 12 - picker_h - 12 - font_small, stats, {0.65, 0.70, 0.78, 1}, .Small)

	if g.world.game_over || g.world.victory {
		p->draw_rect(0, 0, sw, sh, {0, 0, 0, 0.65})
		head_color: [4]f32
		head: string
		if g.world.game_over {
			head = "CORE DESTROYED"
			head_color = {1.00, 0.82, 0.82, 1}
		} else {
			head = "CORE HELD  -  ALL WAVES CLEARED"
			head_color = {0.78, 1.00, 0.82, 1}
		}
		body := fmt.tprintf("Survived %.1fs   |   Scrap collected: %d", g.world.survive_time, g.world.scrap)
		best_str: string
		if g.world.survive_time >= g.best_time && g.best_time > 0 && g.run_result_saved {
			best_str = fmt.tprintf("NEW BEST  %.1fs", g.best_time)
		} else if g.best_time > 0 {
			best_str = fmt.tprintf("Best  %.1fs", g.best_time)
		}
		tip  := "Press R to restart"
		hw := p->text_measure(head, .Large)
		bw := p->text_measure(body, .Small)
		tw := p->text_measure(tip,  .Small)
		cy := sh * 0.5
		p->draw_text((sw - hw) * 0.5, cy - 28, head, head_color, .Large)
		p->draw_text((sw - bw) * 0.5, cy + 24, body, {0.96, 0.96, 0.96, 1},  .Small)
		if best_str != "" {
			best_color := head_color
			if g.world.survive_time >= g.best_time && g.run_result_saved {
				best_color = {1.00, 0.92, 0.55, 1}
			}
			best_w := p->text_measure(best_str, .Small)
			p->draw_text((sw - best_w) * 0.5, cy + 44, best_str, best_color, .Small)
		}
		p->draw_text((sw - tw) * 0.5, cy + 72, tip,  {0.78, 0.86, 1.00, 1},  .Small)
	}

	// Ability buttons. Drawn here so they sit above the HUD and selection
	// panel. Each shows label, hotkey, the dual food/scrap cost on one line,
	// and — while on cooldown — a translucent overlay with the seconds left.
	{
		draw_ability :: proc(p: ^Platform, label, hotkey: string, x, y, w, h: f32,
			ready, hover, held: bool, cooldown, cooldown_max: f32,
			food_cost: i32, scrap_cost: i32) {
			BASE  := [4]f32{0.18, 0.20, 0.26, 0.92}
			HOVER := [4]f32{0.26, 0.30, 0.40, 0.95}
			HELD  := [4]f32{0.10, 0.12, 0.16, 0.95}
			bg := BASE
			if ready {
				if held       do bg = HELD
				else if hover do bg = HOVER
			}
			p->draw_rect(x, y, w, h, bg)
			p->draw_line(x, y,     x + w, y,     1, {1, 1, 1, 0.15})
			p->draw_line(x, y + h, x + w, y + h, 1, {0, 0, 0, 0.40})

			font_small := p->font_size_px(.Small)
			// Two stacked rows: label/hotkey on top, food+scrap cost cluster
			// underneath. We split the inner height evenly so the rows can't
			// overlap as long as `h >= 2*font_small + a bit of padding`.
			pad_y    := f32(4)
			row_h    := (h - pad_y * 2) * 0.5
			top_y    := y + pad_y + row_h * 0.5            // vertical centre of top row
			bot_y    := y + pad_y + row_h + row_h * 0.5    // vertical centre of bottom row

			// Top line: "<label>  [<hotkey>]"
			head := fmt.tprintf("%s  [%s]", label, hotkey)
			hw := p->text_measure(head, .Small)
			p->draw_text(x + (w - hw) * 0.5, top_y + font_small * 0.35, head, {0.95, 0.95, 0.98, 1}, .Small)

			// Bottom line: cost cluster "Nfood Mscrap" centred.
			icon_s := f32(12)
			food_str  := fmt.tprintf("%d", food_cost)
			scrap_str := fmt.tprintf("%d", scrap_cost)
			fw := p->text_measure(food_str,  .Small)
			sw := p->text_measure(scrap_str, .Small)
			gap := f32(4)
			cluster_w := icon_s + gap + fw + 10 + icon_s + gap + sw
			cx0 := x + (w - cluster_w) * 0.5
			text_baseline := bot_y + font_small * 0.35
			icon_y := bot_y - icon_s * 0.5
			draw_food_icon(p, cx0, icon_y, icon_s)
			p->draw_text(cx0 + icon_s + gap, text_baseline, food_str, {0.92, 0.98, 0.78, 1}, .Small)
			sx0 := cx0 + icon_s + gap + fw + 10
			draw_scrap_icon(p, sx0, icon_y, icon_s)
			p->draw_text(sx0 + icon_s + gap, text_baseline, scrap_str, {0.78, 0.86, 1.00, 1}, .Small)

			if !ready && cooldown_max > 0 {
				// Dark overlay shrinking from the right as the cooldown elapses,
				// so the button visually "refills" left-to-darkening-only — the
				// lit (right) portion grows toward the left as `cooldown` drains.
				progress := 1 - cooldown / cooldown_max
				if progress < 0 do progress = 0
				if progress > 1 do progress = 1
				dark_w := w * (1 - progress)
				if dark_w > 0 do p->draw_rect(x, y, dark_w, h, {0, 0, 0, 0.55})
			}
		}
		bomb_ready := world_can_use_bomb(&g.world)
		emp_ready  := world_can_use_emp(&g.world)
		draw_ability(p, "Bomb", "Q", bomb_x, bomb_y, ABIL_W, ABIL_H,
			bomb_ready, mouse_in_bomb, mouse_in_bomb && p.mouse_left_down,
			g.world.bomb_cooldown, BOMB_COOLDOWN, i32(BOMB_FOOD_COST), BOMB_SCRAP_COST)
		draw_ability(p, "EMP",  "E", emp_x,  emp_y,  ABIL_W, ABIL_H,
			emp_ready, mouse_in_emp, mouse_in_emp && p.mouse_left_down,
			g.world.emp_cooldown,  EMP_COOLDOWN,  i32(EMP_FOOD_COST),  EMP_SCRAP_COST)
		// While the EMP is freezing the field, paint a faint cyan vignette over
		// the screen as feedback that the world is paused for enemies.
		if g.world.emp_time > 0 {
			a := g.world.emp_time / EMP_DURATION
			if a > 1 do a = 1
			p->draw_rect(0, 0, sw, sh, {0.40, 0.85, 1.00, 0.10 * a})
			label := fmt.tprintf("EMP  %.1fs", g.world.emp_time)
			lw := p->text_measure(label, .Small)
			p->draw_text((sw - lw) * 0.5, 90, label, {0.55, 0.95, 1.00, 1}, .Small)
		}
	}

	// Gear button (top-right). Drawn after everything else so it sits above the
	// HUD and selection panel; the click was already consumed up top.
	{
		gear_hover := mouse_in_gear
		gear_held  := gear_hover && p.mouse_left_down
		bg := [4]f32{0.18, 0.20, 0.26, 0.85}
		if gear_held       do bg = {0.10, 0.12, 0.16, 0.95}
		else if gear_hover do bg = {0.26, 0.30, 0.40, 0.95}
		p->draw_rect(gear_x, gear_y, GEAR_S, GEAR_S, bg)
		draw_gear_icon(p, gear_x + GEAR_S*0.5, gear_y + GEAR_S*0.5, GEAR_S * 0.7, {0.95, 0.95, 0.98, 1})
	}

	// Fullscreen button — same chrome as the gear, sits immediately to its
	// left. Click handler already consumed at the top of the frame.
	{
		fs_hover := mouse_in_fs
		fs_held  := fs_hover && p.mouse_left_down
		bg := [4]f32{0.18, 0.20, 0.26, 0.85}
		if fs_held       do bg = {0.10, 0.12, 0.16, 0.95}
		else if fs_hover do bg = {0.26, 0.30, 0.40, 0.95}
		p->draw_rect(fs_x, fs_y, GEAR_S, GEAR_S, bg)
		draw_fullscreen_icon(p, fs_x + GEAR_S*0.5, fs_y + GEAR_S*0.5, GEAR_S * 0.55, {0.95, 0.95, 0.98, 1})
	}

	// Pause menu — modal overlay on top of everything. Gameplay input has
	// already been gated above via `paused`; here we only render and process
	// the menu's own controls.
	if g.paused {
		p->draw_rect(0, 0, sw, sh, {0, 0, 0, 0.55})

		PMW := f32(360)
		PMH := f32(360)
		px := (sw - PMW) * 0.5
		py := (sh - PMH) * 0.5

		p->draw_rect(px, py, PMW, PMH, {0.10, 0.11, 0.14, 0.95})
		p->draw_line(px,       py,       px + PMW, py,       1, {1, 1, 1, 0.15})
		p->draw_line(px,       py + PMH, px + PMW, py + PMH, 1, {0, 0, 0, 0.40})

		if !g.show_controls {
			title := "Paused"
			tw := p->text_measure(title, .Large)
			p->draw_text(px + (PMW - tw) * 0.5, py + 16 + font_large, title, {0.95, 0.95, 0.98, 1}, .Large)

			// Volume slider — stub; no audio hooked up yet.
			vol_label := fmt.tprintf("Volume   %d%%", i32(g.volume * 100 + 0.5))
			p->draw_text(px + 24, py + 16 + font_large + 36 + font_small, vol_label, {0.85, 0.90, 0.98, 1}, .Small)

			track_x := px + 24
			track_w := PMW - 48
			track_h := f32(8)
			track_y := py + 16 + font_large + 36 + font_small + 14
			p->draw_rect(track_x, track_y, track_w,                 track_h, {0.05, 0.06, 0.08, 1})
			p->draw_rect(track_x, track_y, track_w * g.volume,      track_h, {0.45, 0.85, 0.55, 1})
			knob_cx := track_x + track_w * g.volume
			knob_cy := track_y + track_h * 0.5
			p->draw_circle(knob_cx, knob_cy, 9, {0.95, 0.95, 0.98, 1})

			// Hit area is the track expanded vertically so the knob is easy to grab.
			hit_x := track_x
			hit_y := track_y - 12
			hit_w := track_w
			hit_h := track_h + 24
			if p.mouse_left_pressed && point_in_rect(p.mouse, hit_x, hit_y, hit_w, hit_h) {
				g.volume_dragging = true
			}
			if g.volume_dragging {
				t := (p.mouse.x - track_x) / track_w
				if t < 0 do t = 0
				if t > 1 do t = 1
				g.volume = t
			}
		}

		if !p.mouse_left_down do g.volume_dragging = false

		btn_w := PMW - 48
		btn_h := f32(40)
		bx    := px + 24
		restart_y  := py + PMH - 16 - btn_h*3 - 20
		controls_y := py + PMH - 16 - btn_h*2 - 10
		resume_y   := py + PMH - 16 - btn_h
		if !g.show_controls {
			if ui_button(&g.ui, p, "Restart",  bx, restart_y,  btn_w, btn_h) {
				game_restart(g)
			}
			if ui_button(&g.ui, p, "Controls", bx, controls_y, btn_w, btn_h) {
				g.show_controls = true
			}
			if ui_button(&g.ui, p, "Resume",   bx, resume_y,   btn_w, btn_h) {
				g.paused = false
			}
		}

		// Controls modal — drawn on top of the pause panel; its own buttons
		// are gated above so clicks don't fall through.
		if g.show_controls {
			CMW := f32(440)
			CMH := f32(440)
			cx := (sw - CMW) * 0.5
			cy := (sh - CMH) * 0.5

			p->draw_rect(0, 0, sw, sh, {0, 0, 0, 0.35})
			p->draw_rect(cx, cy, CMW, CMH, {0.10, 0.11, 0.14, 0.98})
			p->draw_line(cx,       cy,       cx + CMW, cy,       1, {1, 1, 1, 0.15})
			p->draw_line(cx,       cy + CMH, cx + CMW, cy + CMH, 1, {0, 0, 0, 0.40})

			ctitle := "Controls"
			ctw := p->text_measure(ctitle, .Large)
			p->draw_text(cx + (CMW - ctw) * 0.5, cy + 16 + font_large, ctitle, {0.95, 0.95, 0.98, 1}, .Large)

			rows := [?][2]string{
				{"W A S D",        "Pan camera"},
				{"Mouse Wheel",    "Zoom"},
				{"Right Mouse",    "Pan / cancel placement"},
				{"Left Mouse",     "Place tile / select"},
				{"1 - 7",          "Select tile to build"},
				{"Space",          "Upgrade selected tile"},
				{"Q",              "Bomb (target then click)"},
				{"E",              "EMP"},
				{"R",              "Restart (on game over)"},
				{"Shift + Enter",  "Toggle fullscreen"},
				{"Escape",         "Cancel / pause"},
			}

			row_h := font_small + 10
			list_y := cy + 16 + font_large + 24
			key_x  := cx + 24
			desc_x := cx + 180
			for row, i in rows {
				ry := list_y + f32(i) * row_h
				p->draw_text(key_x,  ry, row[0], {0.85, 0.90, 0.98, 1}, .Small)
				p->draw_text(desc_x, ry, row[1], {0.95, 0.95, 0.98, 1}, .Small)
			}

			cb_w := CMW - 48
			cb_h := f32(40)
			cb_x := cx + 24
			cb_y := cy + CMH - 16 - cb_h
			if ui_button(&g.ui, p, "Back", cb_x, cb_y, cb_w, cb_h) {
				g.show_controls = false
			}
		}
	}
}
