package game

import "core:math"

Tile_Kind :: enum {
	Farm,
	Generator,
	Turret,
	Wall,
	Relay,
	Mortar,
	Core,
}

TILE_KIND_COUNT :: len(Tile_Kind)
// Core is unique and granted at world init; only the rest are placeable.
BUILDABLE_COUNT :: TILE_KIND_COUNT - 1

// Mortar requires the Core to be at least this tier before it can be placed.
MORTAR_CORE_TIER_REQ :: i32(2)

// Repair conversion: 1 scrap restores this many HP. Repair is rounded up to
// whole scrap so a 1-HP top-up still costs at least one scrap.
REPAIR_HP_PER_SCRAP :: f32(4)

BUILD_RANGE :: 2
START_FOOD  :: f32(15)

Tile :: struct {
	kind:      Tile_Kind,
	tier:      i32, // 1..tile_max_tier(kind); always 1 on placement.
	hp:        f32,
	energized: bool,
	cooldown:  f32,
	aim_angle: f32, // turret barrel angle in radians (atan2 convention)
}

// Every tile is upgradeable now — Core's 3-tier path unlocks the Mortar and
// bumps its survivability.
tile_max_tier :: proc(kind: Tile_Kind) -> i32 {
	switch kind {
	case .Farm, .Generator, .Turret, .Wall, .Relay, .Mortar, .Core: return 3
	}
	return 1
}

tile_is_upgradeable :: proc(kind: Tile_Kind) -> bool {
	return tile_max_tier(kind) > 1
}

// Upgrade cost in food: scales with the destination tier.
tile_upgrade_cost :: proc(kind: Tile_Kind, current_tier: i32) -> f32 {
	if current_tier >= tile_max_tier(kind) do return 0
	// Core has no placement cost (`tile_cost(.Core)` is 0), so the base-times-
	// tier formula collapses to 0. Use a flat per-tier schedule instead so the
	// upgrade is a real investment that gates the Mortar.
	if kind == .Core {
		switch current_tier {
		case 1: return 40
		case 2: return 80
		}
		return 0
	}
	base := tile_cost(kind)
	// 1->2 costs base, 2->3 costs base * 2.
	return base * f32(current_tier)
}

// --- Tiered stats -----------------------------------------------------------

// Generator power radius in hexes.
generator_radius :: proc(tier: i32) -> i32 {
	switch tier {
	case 2: return 2
	case 3: return 3
	}
	return 1
}

// Per-Farm food production per second. Halved from the original 1.0/1.6/2.4
// curve — at the old rate a farm paid for itself in 5s, which trivialised the
// economy during the opening grace window. New payback at T1 is 10s, which
// still rewards an early eco rush but forces a real farm-vs-defense tradeoff.
farm_food_rate :: proc(tier: i32) -> f32 {
	switch tier {
	case 2: return 0.8
	case 3: return 1.2
	}
	return 0.5
}

// Relay build radius in hexes (overrides BUILD_RANGE for relays).
relay_build_radius :: proc(tier: i32) -> i32 {
	switch tier {
	case 2: return 3
	case 3: return 4
	}
	return BUILD_RANGE
}

turret_damage :: proc(tier: i32) -> f32 {
	switch tier {
	case 2, 3: return TURRET_DAMAGE * 1.6
	}
	return TURRET_DAMAGE
}

turret_has_back_gun :: proc(tier: i32) -> bool {
	return tier >= 3
}

// Mortar tuning. Long range, slow fire, area-of-effect splash. Upgrades widen
// the splash and grow the damage so a tier-3 mortar is a real cornerstone.
MORTAR_RANGE_PIXELS  :: f32(440)
MORTAR_FIRE_INTERVAL :: f32(2.4)
MORTAR_ROT_SPEED     :: f32(3.5)
MORTAR_AIM_TOLERANCE :: f32(0.25)
MORTAR_PROJ_SPEED    :: f32(320)
MORTAR_PROJ_LIFE     :: f32(3.0)
MORTAR_BASE_DAMAGE   :: f32(22)
MORTAR_BASE_SPLASH   :: f32(60)

mortar_damage :: proc(tier: i32) -> f32 {
	switch tier {
	case 2: return MORTAR_BASE_DAMAGE * 1.4
	case 3: return MORTAR_BASE_DAMAGE * 1.9
	}
	return MORTAR_BASE_DAMAGE
}

mortar_splash :: proc(tier: i32) -> f32 {
	switch tier {
	case 2: return MORTAR_BASE_SPLASH * 1.2
	case 3: return MORTAR_BASE_SPLASH * 1.5
	}
	return MORTAR_BASE_SPLASH
}

World :: struct {
	tiles:         map[Hex_Coord]Tile,
	core:          Hex_Coord,
	food:          f32,
	scrap:         i32,
	enemies:           [dynamic]Enemy,
	projectiles:       [dynamic]Projectile,
	// Projectiles fired *by* enemies (Spitter shots). Kept separate from the
	// player's `projectiles` so the hit-tests never accidentally cross — turret
	// bullets damage enemies, spitter shots damage tiles.
	enemy_projectiles: [dynamic]Enemy_Projectile,
	particles:     [dynamic]Particle,
	field_crawler: Path_Field,
	field_brute:   Path_Field,
	path_dirty:    bool,
	survive_time:  f32,
	game_over:     bool,
	waves:         Wave_State,

	// Sound effects queued by simulation code (turrets firing, enemies dying,
	// tiles being destroyed). `game_update_and_render` drains this each frame
	// and forwards the events to `Platform.play_sound` / `play_sound_at`. A
	// queued entry without `has_pos` plays unpositioned (UI-like); with one,
	// the host attenuates and pans by distance from the current listener.
	sound_queue:   [dynamic]Queued_Sound,

	// Core ability cooldowns (seconds remaining; 0 == ready). EMP doubles as a
	// world-wide "enemies are frozen" timer in `emp_time`.
	bomb_cooldown: f32,
	emp_cooldown:  f32,
	emp_time:      f32,
}

// Ability tuning. Both abilities cost food + scrap and share a cooldown each.
BOMB_FOOD_COST   :: f32(20)
BOMB_SCRAP_COST  :: i32(10)
BOMB_COOLDOWN    :: f32(30)
BOMB_RADIUS      :: f32(110)
BOMB_DAMAGE      :: f32(90)

EMP_FOOD_COST    :: f32(15)
EMP_SCRAP_COST   :: i32(8)
EMP_COOLDOWN     :: f32(40)
EMP_DURATION     :: f32(5)

Queued_Sound :: struct {
	kind:    Sound,
	pos:     [2]f32,
	has_pos: bool,
}

world_queue_sound :: proc(w: ^World, s: Sound) {
	append(&w.sound_queue, Queued_Sound{kind = s})
}

// Positional variant — the per-frame drain forwards (pos.x, pos.y) to the host
// so the underlying audio engine pans/attenuates by distance to the listener.
world_queue_sound_at :: proc(w: ^World, s: Sound, pos: [2]f32) {
	append(&w.sound_queue, Queued_Sound{kind = s, pos = pos, has_pos = true})
}

world_init :: proc(w: ^World) {
	w.core = {0, 0}
	w.tiles[w.core] = Tile{kind = .Core, tier = 1, hp = tile_max_hp(.Core, 1), energized = true}
	w.food = START_FOOD
	w.path_dirty = true
	waves_init(&w.waves)
}

world_shutdown :: proc(w: ^World) {
	delete(w.tiles)
	delete(w.enemies)
	delete(w.projectiles)
	delete(w.enemy_projectiles)
	delete(w.particles)
	delete(w.sound_queue)
	path_field_destroy(&w.field_crawler)
	path_field_destroy(&w.field_brute)
	waves_shutdown(&w.waves)
}

tile_cost :: proc(kind: Tile_Kind) -> f32 {
	switch kind {
	case .Core:      return 0
	case .Farm:      return 5
	case .Generator: return 10
	case .Turret:    return 15
	case .Wall:      return 5
	case .Relay:     return 8
	case .Mortar:    return 30
	}
	return 0
}

tile_consumes_energy :: proc(kind: Tile_Kind) -> bool {
	return kind == .Turret || kind == .Mortar
}

world_in_build_range :: proc(w: ^World, c: Hex_Coord) -> bool {
	if hex_distance(c, w.core) <= BUILD_RANGE do return true
	for coord, tile in w.tiles {
		if tile.kind != .Relay do continue
		if hex_distance(c, coord) <= relay_build_radius(tile.tier) do return true
	}
	return false
}

// Mortar is gated on the Core's current tier — at world init this is 1, so the
// Mortar is invisible-but-not-gone in the picker until the player invests in an
// upgrade. Keep the check broad: a missing Core (shouldn't happen mid-run) also
// counts as "not allowed".
mortar_unlocked :: proc(w: ^World) -> bool {
	core, ok := w.tiles[w.core]
	if !ok do return false
	return core.tier >= MORTAR_CORE_TIER_REQ
}

world_can_place :: proc(w: ^World, c: Hex_Coord, kind: Tile_Kind) -> bool {
	if kind == .Core do return false
	if c in w.tiles do return false
	if w.food < tile_cost(kind) do return false
	if kind == .Mortar && !mortar_unlocked(w) do return false
	return world_in_build_range(w, c)
}

world_place :: proc(w: ^World, c: Hex_Coord, kind: Tile_Kind) -> bool {
	if !world_can_place(w, c, kind) do return false
	w.food -= tile_cost(kind)
	tile := Tile{kind = kind, tier = 1, hp = tile_max_hp(kind, 1)}
	if kind == .Turret || kind == .Mortar {
		tile.aim_angle = -math.PI * 0.5 // start pointing up
	}
	w.tiles[c] = tile
	w.path_dirty = true
	world_queue_sound_at(w, .Place_Building, hex_to_pixel(c))
	return true
}

// Bump a tile up one tier. Costs food, scales hp by the new max-hp ratio so
// upgrades feel like a buff rather than a free heal.
world_can_upgrade :: proc(w: ^World, c: Hex_Coord) -> bool {
	t, ok := w.tiles[c]
	if !ok do return false
	if !tile_is_upgradeable(t.kind) do return false
	if t.tier >= tile_max_tier(t.kind) do return false
	if w.food < tile_upgrade_cost(t.kind, t.tier) do return false
	return true
}

world_upgrade :: proc(w: ^World, c: Hex_Coord) -> bool {
	if !world_can_upgrade(w, c) do return false
	t := w.tiles[c]
	cost := tile_upgrade_cost(t.kind, t.tier)
	old_max := tile_max_hp(t.kind, t.tier)
	t.tier += 1
	new_max := tile_max_hp(t.kind, t.tier)
	if old_max > 0 do t.hp *= new_max / old_max
	if t.hp > new_max do t.hp = new_max
	w.tiles[c] = t
	w.food -= cost
	// Relay range and generator coverage can change pathing/energization.
	w.path_dirty = true
	return true
}

world_remove :: proc(w: ^World, c: Hex_Coord) -> bool {
	t, ok := w.tiles[c]
	if !ok do return false
	if t.kind == .Core do return false
	delete_key(&w.tiles, c)
	w.path_dirty = true
	return true
}

// Repair pricing. Returns (missing_hp, scrap_cost). Round-up on scrap so a
// 1-HP nudge still costs the player something — otherwise a building at
// max-hp-minus-1 would be free to top up indefinitely.
tile_repair_quote :: proc(w: ^World, c: Hex_Coord) -> (missing: f32, scrap_cost: i32, ok: bool) {
	t, present := w.tiles[c]
	if !present do return 0, 0, false
	max_hp := tile_max_hp(t.kind, t.tier)
	missing = max_hp - t.hp
	if missing <= 0 do return 0, 0, false
	scrap_f := missing / REPAIR_HP_PER_SCRAP
	scrap_cost = i32(math.ceil(scrap_f))
	if scrap_cost < 1 do scrap_cost = 1
	return missing, scrap_cost, true
}

world_can_repair :: proc(w: ^World, c: Hex_Coord) -> bool {
	_, cost, ok := tile_repair_quote(w, c)
	if !ok do return false
	return w.scrap >= cost
}

world_repair :: proc(w: ^World, c: Hex_Coord) -> bool {
	missing, cost, ok := tile_repair_quote(w, c)
	if !ok do return false
	if w.scrap < cost do return false
	t := w.tiles[c]
	max_hp := tile_max_hp(t.kind, t.tier)
	t.hp += missing
	if t.hp > max_hp do t.hp = max_hp
	w.tiles[c] = t
	w.scrap -= cost
	return true
}

// Spend food + scrap to detonate a bomb centred at world-space `pos`. Damages
// every enemy in radius `BOMB_RADIUS` and emits an FX flash. Cooldown-gated so
// the player can't chain it across one wave.
world_can_use_bomb :: proc(w: ^World) -> bool {
	if w.bomb_cooldown > 0 do return false
	if w.food < BOMB_FOOD_COST do return false
	if w.scrap < BOMB_SCRAP_COST do return false
	return true
}

world_use_bomb :: proc(w: ^World, pos: [2]f32) -> bool {
	if !world_can_use_bomb(w) do return false
	w.food  -= BOMB_FOOD_COST
	w.scrap -= BOMB_SCRAP_COST
	w.bomb_cooldown = BOMB_COOLDOWN
	r2 := BOMB_RADIUS * BOMB_RADIUS
	for i in 0 ..< len(w.enemies) {
		e := &w.enemies[i]
		dx := e.pos.x - pos.x
		dy := e.pos.y - pos.y
		if dx*dx + dy*dy <= r2 do e.hp -= BOMB_DAMAGE
	}
	fx_emit_bomb(w, pos)
	world_queue_sound_at(w, .Building_Explode, pos)
	return true
}

world_can_use_emp :: proc(w: ^World) -> bool {
	if w.emp_cooldown > 0 do return false
	if w.food < EMP_FOOD_COST do return false
	if w.scrap < EMP_SCRAP_COST do return false
	return true
}

world_use_emp :: proc(w: ^World) -> bool {
	if !world_can_use_emp(w) do return false
	w.food  -= EMP_FOOD_COST
	w.scrap -= EMP_SCRAP_COST
	w.emp_cooldown = EMP_COOLDOWN
	w.emp_time     = EMP_DURATION
	world_queue_sound(w, .Turret_Shoot)
	return true
}

world_sell :: proc(w: ^World, c: Hex_Coord) -> bool {
	t, ok := w.tiles[c]
	if !ok do return false
	if t.kind == .Core do return false
	w.food += tile_cost(t.kind) * 0.5
	delete_key(&w.tiles, c)
	w.path_dirty = true
	return true
}

tile_max_hp :: proc(kind: Tile_Kind, tier: i32 = 1) -> f32 {
	base: f32
	switch kind {
	case .Core:      base = 200
	case .Wall:      base = 200
	case .Turret:    base = 80
	case .Mortar:    base = 70
	case .Generator: base = 60
	case .Relay:     base = 50
	case .Farm:      base = 50
	case:            base = 50
	}
	// Per-kind tier scaling. Walls scale aggressively; Farm/Generator get a
	// small bonus; everything else inherits a tiny default bump so upgrades
	// always feel meaningful.
	mult := f32(1)
	switch kind {
	case .Wall:
		switch tier {
		case 2: mult = 1.75
		case 3: mult = 2.50
		}
	case .Farm, .Generator:
		switch tier {
		case 2: mult = 1.15
		case 3: mult = 1.30
		}
	case .Turret, .Relay, .Mortar:
		switch tier {
		case 2: mult = 1.20
		case 3: mult = 1.40
		}
	case .Core:
		// Core upgrades grant a meaningful HP cushion — investing in tier 2
		// to unlock the Mortar should also feel like the base got tougher.
		switch tier {
		case 2: mult = 1.40
		case 3: mult = 1.80
		}
	}
	return base * mult
}

world_count_kind :: proc(w: ^World, kind: Tile_Kind) -> int {
	n := 0
	for _, tile in w.tiles {
		if tile.kind == kind do n += 1
	}
	return n
}

world_count_powered :: proc(w: ^World) -> (powered, total: int) {
	for _, tile in w.tiles {
		if !tile_consumes_energy(tile.kind) do continue
		total += 1
		if tile.energized do powered += 1
	}
	return
}

@(private="file")
world_recompute_energy :: proc(w: ^World) {
	// Pass 1: Generator and Core power themselves; everything else is dark.
	for coord, tile in w.tiles {
		t := tile
		t.energized = (tile.kind == .Generator || tile.kind == .Core)
		w.tiles[coord] = t
	}

	// Pass 2: every consumer within `generator_radius(tier)` of a Generator
	// lights up. With the Wire kind gone, generator coverage is the only way
	// power propagates — tiered generators project a wider field.
	for coord, tile in w.tiles {
		if tile.kind != .Generator do continue
		radius := generator_radius(tile.tier)
		for other_coord, other in w.tiles {
			if !tile_consumes_energy(other.kind) do continue
			if other.energized do continue
			if hex_distance(coord, other_coord) > radius do continue
			ot := other
			ot.energized = true
			w.tiles[other_coord] = ot
		}
	}
}

world_tick :: proc(w: ^World, dt: f32) {
	// Sum each farm's tiered output rather than count*1, so tier-2/3 farms
	// produce more food per second.
	food_rate := f32(0)
	for _, tile in w.tiles {
		if tile.kind == .Farm do food_rate += farm_food_rate(tile.tier)
	}
	w.food += food_rate * dt
	// Bleed ability timers. EMP_time fires once and decays; cooldowns count
	// down independently so the player sees a "ready" state distinct from
	// the in-flight stun window.
	if w.bomb_cooldown > 0 { w.bomb_cooldown -= dt; if w.bomb_cooldown < 0 do w.bomb_cooldown = 0 }
	if w.emp_cooldown  > 0 { w.emp_cooldown  -= dt; if w.emp_cooldown  < 0 do w.emp_cooldown  = 0 }
	if w.emp_time      > 0 { w.emp_time      -= dt; if w.emp_time      < 0 do w.emp_time      = 0 }
	world_recompute_energy(w)
	if w.path_dirty {
		build_path_field(w, &w.field_crawler, CRAWLER_WEIGHTS)
		build_path_field(w, &w.field_brute,   BRUTE_WEIGHTS)
		w.path_dirty = false
	}
}

tile_kind_name :: proc(kind: Tile_Kind) -> string {
	switch kind {
	case .Core:      return "Core"
	case .Farm:      return "Farm"
	case .Generator: return "Generator"
	case .Turret:    return "Turret"
	case .Wall:      return "Wall"
	case .Relay:     return "Relay"
	case .Mortar:    return "Mortar"
	}
	return "?"
}

tile_color :: proc(kind: Tile_Kind) -> (fill, stroke: [4]f32) {
	switch kind {
	case .Core:
		return {0.933, 0.929, 0.996, 1}, {0.325, 0.290, 0.718, 1}
	case .Farm:
		return {0.918, 0.953, 0.871, 1}, {0.231, 0.427, 0.067, 1}
	case .Generator:
		return {0.980, 0.933, 0.855, 1}, {0.522, 0.310, 0.043, 1}
	case .Turret:
		return {0.988, 0.922, 0.922, 1}, {0.639, 0.176, 0.176, 1}
	case .Wall:
		return {0.945, 0.937, 0.910, 1}, {0.373, 0.369, 0.353, 1}
	case .Relay:
		return {0.882, 0.961, 0.933, 1}, {0.059, 0.431, 0.337, 1}
	case .Mortar:
		// Dusky violet — distinct from the warm-red Turret palette so the two
		// firepower tiles read apart at a glance.
		return {0.918, 0.886, 0.969, 1}, {0.396, 0.255, 0.612, 1}
	}
	return {1, 1, 1, 1}, {0, 0, 0, 1}
}

draw_tile_icon :: proc(p: ^Platform, cx, cy: f32, kind: Tile_Kind, alpha: f32, aim_angle: f32 = -math.PI * 0.5, tier: i32 = 1) {
	_, stroke := tile_color(kind)
	stroke.a *= alpha

	switch kind {
	case .Core:
		p->draw_circle(cx, cy, 10, stroke)

	case .Farm:
		// Two rows of 9px blocks at the original size; column count grows
		// with tier. Cell pitch matches the original layout (9px block,
		// 4px gap), so the row just gets wider.
		light := [4]f32{0.388, 0.600, 0.133, alpha}
		cols: i32
		switch tier {
		case 2: cols = 3
		case 3: cols = 4
		case:   cols = 2
		}
		cell  := f32(9)
		gap   := f32(4)
		pitch := cell + gap
		total := cell * f32(cols) + gap * f32(cols - 1)
		x0    := cx - total * 0.5
		y_top := cy - 11
		y_bot := cy + 2
		for i in 0 ..< cols {
			x := x0 + f32(i) * pitch
			p->draw_rect(x, y_top, cell, cell, stroke)
			p->draw_rect(x, y_bot, cell, cell, light)
		}

	case .Generator:
		// Lightning Z at its original size; tier 2/3 add translated copies.
		amber := [4]f32{0.729, 0.459, 0.090, alpha}
		count: i32 = 1
		switch tier {
		case 2: count = 2
		case 3: count = 3
		}
		// Each Z spans -6..+6 horizontally; step centers by ~16 so adjacent
		// glyphs sit shoulder to shoulder without overlapping.
		step := f32(16)
		x0   := cx - step * f32(count - 1) * 0.5
		for i in 0 ..< count {
			zx := x0 + f32(i) * step
			p->draw_line(zx - 6, cy - 12, zx + 6, cy +  0, 3, amber)
			p->draw_line(zx + 6, cy +  0, zx - 4, cy + 12, 3, amber)
		}

	case .Turret:
		hot := [4]f32{0.886, 0.294, 0.290, alpha}
		p->draw_circle(cx, cy, 8, hot)
		barrel_len := f32(15)
		bx := cx + math.cos(aim_angle) * barrel_len
		by := cy + math.sin(aim_angle) * barrel_len
		p->draw_line(cx, cy, bx, by, 4, stroke)
		// (Tier-3 back gun is rendered separately by the world pass since
		// draw_tile_icon doesn't know the tile's tier.)

	case .Wall:
		// Brick stack at the original brick size (9×9 with 4px gaps).
		// Tier 1 = 3 bricks (2 top + 1 bottom — original look).
		// Tier 2 = 5 bricks (3 top + 2 bottom).
		// Tier 3 = 7 bricks (4 top + 3 bottom).
		mid := [4]f32{0.533, 0.529, 0.502, alpha}
		top_count, bot_count: i32
		switch tier {
		case 2: top_count, bot_count = 3, 2
		case 3: top_count, bot_count = 4, 3
		case:   top_count, bot_count = 2, 1
		}
		cell  := f32(9)
		gap   := f32(4)
		pitch := cell + gap
		total_top := cell * f32(top_count) + gap * f32(top_count - 1)
		total_bot := cell * f32(bot_count) + gap * f32(bot_count - 1)
		x0_top := cx - total_top * 0.5
		x0_bot := cx - total_bot * 0.5
		y_top  := cy - 8
		y_bot  := cy + 1
		for i in 0 ..< top_count {
			p->draw_rect(x0_top + f32(i) * pitch, y_top, cell, cell, mid)
		}
		for i in 0 ..< bot_count {
			p->draw_rect(x0_bot + f32(i) * pitch, y_bot, cell, cell, stroke)
		}

	case .Mortar:
		// Squat barrel angled along `aim_angle` plus a violet base disc. Tier 2
		// thickens the barrel and tier 3 grows the base to read as "bigger gun".
		violet := [4]f32{0.55, 0.38, 0.78, alpha}
		base_r: f32 = 8
		barrel_t: f32 = 6
		switch tier {
		case 2: barrel_t = 7
		case 3: base_r = 10; barrel_t = 8
		}
		p->draw_circle(cx, cy, base_r, violet)
		barrel_len := f32(13)
		bx := cx + math.cos(aim_angle) * barrel_len
		by := cy + math.sin(aim_angle) * barrel_len
		p->draw_line(cx, cy, bx, by, barrel_t, stroke)
		// Muzzle cap so the silhouette doesn't fade into a stripe at distance.
		p->draw_circle(bx, by, barrel_t * 0.55, stroke)

	case .Relay:
		// Concentric ring at full size (10/7/4); tiers add translated copies.
		// Tier 1 = 1 ring centered.
		// Tier 2 = 2 rings side by side.
		// Tier 3 = 3 rings arranged as a triangle (one top, two bottom).
		ring_outer := [4]f32{0.365, 0.792, 0.647, alpha}
		ring_inner := [4]f32{0.114, 0.620, 0.459, alpha}
		fill, _ := tile_color(kind)
		draw_ring :: proc(p: ^Platform, x, y: f32, c_outer, c_fill, c_inner: [4]f32) {
			p->draw_circle(x, y, 10, c_outer)
			p->draw_circle(x, y,  7, c_fill)
			p->draw_circle(x, y,  4, c_inner)
		}
		switch tier {
		case 2:
			draw_ring(p, cx - 12, cy, ring_outer, fill, ring_inner)
			draw_ring(p, cx + 12, cy, ring_outer, fill, ring_inner)
		case 3:
			draw_ring(p, cx,      cy - 12, ring_outer, fill, ring_inner)
			draw_ring(p, cx - 12, cy +  8, ring_outer, fill, ring_inner)
			draw_ring(p, cx + 12, cy +  8, ring_outer, fill, ring_inner)
		case:
			draw_ring(p, cx, cy, ring_outer, fill, ring_inner)
		}
	}
}

@(private="file")
draw_tile_marker :: proc(p: ^Platform, c: Hex_Coord, tile: Tile, alpha: f32) {
	center := hex_to_pixel(c)
	draw_tile_icon(p, center.x, center.y, tile.kind, alpha, tile.aim_angle, tile.tier)

	// Tier-3 turret: back gun mirrored across the body. Drawn here (not in
	// draw_tile_icon) so the picker bar's iconography stays unchanged.
	if tile.kind == .Turret && turret_has_back_gun(tile.tier) {
		_, stroke := tile_color(.Turret)
		stroke.a *= alpha
		barrel_len := f32(15)
		bx := center.x - math.cos(tile.aim_angle) * barrel_len
		by := center.y - math.sin(tile.aim_angle) * barrel_len
		p->draw_line(center.x, center.y, bx, by, 4, stroke)
	}
}

// Small HUD icons drawn within an `s` × `s` box anchored at top-left (x, y).
draw_food_icon :: proc(p: ^Platform, x, y, s: f32) {
	dark  := [4]f32{0.231, 0.427, 0.067, 1}
	light := [4]f32{0.388, 0.600, 0.133, 1}
	q := s * 0.45
	gap := s - q * 2
	p->draw_rect(x,             y,             q, q, dark)
	p->draw_rect(x + q + gap,   y,             q, q, dark)
	p->draw_rect(x,             y + q + gap,   q, q, light)
	p->draw_rect(x + q + gap,   y + q + gap,   q, q, light)
}

draw_scrap_icon :: proc(p: ^Platform, x, y, s: f32) {
	mid    := [4]f32{0.533, 0.529, 0.502, 1}
	stroke := [4]f32{0.373, 0.369, 0.353, 1}
	p->draw_rect(x + s * 0.10, y + s * 0.20, s * 0.80, s * 0.60, mid)
	p->draw_line(x + s * 0.10, y + s * 0.50, x + s * 0.90, y + s * 0.50, 2, stroke)
}

draw_core_icon :: proc(p: ^Platform, x, y, s: f32) {
	stroke := [4]f32{0.325, 0.290, 0.718, 1}
	fill   := [4]f32{0.733, 0.729, 0.996, 1}
	cx := x + s * 0.5
	cy := y + s * 0.5
	r  := s * 0.40
	p->draw_circle(cx, cy, r,        stroke)
	p->draw_circle(cx, cy, r * 0.65, fill)
}

draw_enemy_icon :: proc(p: ^Platform, x, y, s: f32) {
	hot   := [4]f32{0.886, 0.294, 0.290, 1}
	dark  := [4]f32{0.639, 0.176, 0.176, 1}
	cx := x + s * 0.5
	cy := y + s * 0.5
	p->draw_circle(cx, cy, s * 0.42, dark)
	p->draw_circle(cx, cy, s * 0.30, hot)
}

world_render :: proc(w: ^World, p: ^Platform) {
	for coord, tile in w.tiles {
		_, stroke := tile_color(tile.kind)
		alpha := f32(1)
		if tile_consumes_energy(tile.kind) && !tile.energized {
			alpha = 0.45
		}
		stroke.a *= alpha
		draw_hex_outline(p, coord, 2, stroke)
		draw_tile_marker(p, coord, tile, alpha)

		max_hp := tile_max_hp(tile.kind, tile.tier)
		center := hex_to_pixel(coord)
		draw_health_bar(p, center.x, center.y - HEX_APOTHEM + 6, 30, tile.hp, max_hp)
	}
}

@(private="file")
render_buildable_area :: proc(w: ^World, p: ^Platform) {
	blue := [4]f32{0.36, 0.62, 0.95, 0.25}
	visit :: proc(w: ^World, p: ^Platform, c: Hex_Coord, radius: i32, color: [4]f32, seen: ^map[Hex_Coord]bool) {
		for q in -radius ..= radius {
			for r in -radius ..= radius {
				n := Hex_Coord{c.x + q, c.y + r}
				if hex_distance(n, c) > radius do continue
				if n in seen^ do continue
				if n in w.tiles do continue
				seen^[n] = true
				draw_hex_outline(p, n, 1.5, color)
			}
		}
	}

	seen: map[Hex_Coord]bool
	defer delete(seen)
	visit(w, p, w.core, BUILD_RANGE, blue, &seen)
	for coord, tile in w.tiles {
		if tile.kind == .Relay {
			visit(w, p, coord, relay_build_radius(tile.tier), blue, &seen)
		}
	}
}

// Halo the hexes a Generator powers or a Relay extends build range over,
// so the player can see at a glance what a selected support tile actually
// covers. Renders nothing for kinds that have no area of influence.
world_render_selection_influence :: proc(w: ^World, p: ^Platform, c: Hex_Coord) {
	tile, ok := w.tiles[c]
	if !ok do return

	radius: i32
	color:  [4]f32
	switch tile.kind {
	case .Generator:
		radius = generator_radius(tile.tier)
		// Amber, matching the generator stroke palette.
		color = {0.98, 0.70, 0.25, 0.55}
	case .Relay:
		radius = relay_build_radius(tile.tier)
		// Teal, matching the relay stroke palette.
		color = {0.25, 0.85, 0.70, 0.55}
	case .Core, .Farm, .Turret, .Wall, .Mortar:
		return
	}
	if radius <= 0 do return

	for q in -radius ..= radius {
		for r in -radius ..= radius {
			n := Hex_Coord{c.x + q, c.y + r}
			if hex_distance(n, c) > radius do continue
			if n == c do continue
			draw_hex_outline(p, n, 1.5, color)
		}
	}
}

world_render_hover :: proc(w: ^World, p: ^Platform, hover: Hex_Coord, center: [2]f32, placing: bool, selected: Tile_Kind) {
	if !placing {
		return
	}

	render_buildable_area(w, p)

	occupied := hover in w.tiles
	can := !occupied && world_can_place(w, hover, selected)

	main_color: [4]f32
	switch {
	case occupied: main_color = {1, 1, 1, 0.35}
	case can:      main_color = {0.30, 0.85, 0.45, 0.85}
	case:          main_color = {0.85, 0.30, 0.30, 0.55}
	}
	draw_hex_outline_at(p, center, occupied ? 1.5 : 2.5, main_color)
}
