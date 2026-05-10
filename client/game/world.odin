package game

import "core:math"

Tile_Kind :: enum {
	Farm,
	Generator,
	Wire,
	Turret,
	Wall,
	Relay,
	Core,
}

TILE_KIND_COUNT :: len(Tile_Kind)
// Core is unique and granted at world init; only the rest are placeable.
BUILDABLE_COUNT :: TILE_KIND_COUNT - 1

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

// Wire/Core are not upgradeable. Everything else maxes at tier 3.
tile_max_tier :: proc(kind: Tile_Kind) -> i32 {
	switch kind {
	case .Wire, .Core: return 1
	case .Farm, .Generator, .Turret, .Wall, .Relay: return 3
	}
	return 1
}

tile_is_upgradeable :: proc(kind: Tile_Kind) -> bool {
	return tile_max_tier(kind) > 1
}

// Upgrade cost in food: scales with the destination tier.
tile_upgrade_cost :: proc(kind: Tile_Kind, current_tier: i32) -> f32 {
	if current_tier >= tile_max_tier(kind) do return 0
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

World :: struct {
	tiles:         map[Hex_Coord]Tile,
	core:          Hex_Coord,
	food:          f32,
	scrap:         i32,
	enemies:       [dynamic]Enemy,
	projectiles:   [dynamic]Projectile,
	particles:     [dynamic]Particle,
	field_crawler: Path_Field,
	field_brute:   Path_Field,
	path_dirty:    bool,
	survive_time:  f32,
	game_over:     bool,
	waves:         Wave_State,
}

world_init :: proc(w: ^World) {
	w.core = {0, 0}
	w.tiles[w.core] = Tile{kind = .Core, tier = 1, hp = 200, energized = true}
	w.food = START_FOOD
	w.path_dirty = true
	waves_init(&w.waves)
}

world_shutdown :: proc(w: ^World) {
	delete(w.tiles)
	delete(w.enemies)
	delete(w.projectiles)
	delete(w.particles)
	path_field_destroy(&w.field_crawler)
	path_field_destroy(&w.field_brute)
	waves_shutdown(&w.waves)
}

tile_cost :: proc(kind: Tile_Kind) -> f32 {
	switch kind {
	case .Core:      return 0
	case .Farm:      return 5
	case .Generator: return 10
	case .Wire:      return 4
	case .Turret:    return 15
	case .Wall:      return 5
	case .Relay:     return 8
	}
	return 0
}

tile_consumes_energy :: proc(kind: Tile_Kind) -> bool {
	return kind == .Turret
}

world_in_build_range :: proc(w: ^World, c: Hex_Coord) -> bool {
	if hex_distance(c, w.core) <= BUILD_RANGE do return true
	for coord, tile in w.tiles {
		if tile.kind != .Relay do continue
		if hex_distance(c, coord) <= relay_build_radius(tile.tier) do return true
	}
	return false
}

world_can_place :: proc(w: ^World, c: Hex_Coord, kind: Tile_Kind) -> bool {
	if kind == .Core do return false
	if c in w.tiles do return false
	if w.food < tile_cost(kind) do return false
	return world_in_build_range(w, c)
}

world_place :: proc(w: ^World, c: Hex_Coord, kind: Tile_Kind) -> bool {
	if !world_can_place(w, c, kind) do return false
	w.food -= tile_cost(kind)
	tile := Tile{kind = kind, tier = 1, hp = tile_max_hp(kind, 1)}
	if kind == .Turret {
		tile.aim_angle = -math.PI * 0.5 // start pointing up
	}
	w.tiles[c] = tile
	w.path_dirty = true
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
	case .Generator: base = 60
	case .Wire:      base = 30
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
	case .Turret, .Relay:
		switch tier {
		case 2: mult = 1.20
		case 3: mult = 1.40
		}
	case .Wire, .Core:
		// Not upgradeable.
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
	// Pass 1: only Generator and Core start energized.
	for coord, tile in w.tiles {
		t := tile
		t.energized = (tile.kind == .Generator || tile.kind == .Core)
		w.tiles[coord] = t
	}

	// Pass 2: BFS power along Wire tiles starting from each Generator.
	queue: [dynamic]Hex_Coord
	defer delete(queue)
	for coord, tile in w.tiles {
		if tile.kind == .Generator do append(&queue, coord)
	}
	for i := 0; i < len(queue); i += 1 {
		coord := queue[i]
		for d in HEX_NEIGHBOR_OFFSETS {
			n := Hex_Coord{coord.x + d.x, coord.y + d.y}
			nt, ok := w.tiles[n]
			if !ok do continue
			if nt.kind == .Wire && !nt.energized {
				nt.energized = true
				w.tiles[n] = nt
				append(&queue, n)
			}
		}
	}

	// Pass 3: any consumer adjacent to an energized wire is energized, and
	// any consumer within `generator_radius(tier)` hexes of a Generator is
	// energized directly. Tiered generators project a wider field.
	for coord, tile in w.tiles {
		if tile.kind == .Wire && tile.energized {
			for d in HEX_NEIGHBOR_OFFSETS {
				n := Hex_Coord{coord.x + d.x, coord.y + d.y}
				nt, ok := w.tiles[n]
				if !ok do continue
				if !tile_consumes_energy(nt.kind) do continue
				if nt.energized do continue
				nt.energized = true
				w.tiles[n] = nt
			}
		}
	}
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
	case .Wire:      return "Wire"
	case .Turret:    return "Turret"
	case .Wall:      return "Wall"
	case .Relay:     return "Relay"
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
	case .Wire:
		return {0.980, 0.933, 0.855, 1}, {0.522, 0.310, 0.043, 1}
	case .Turret:
		return {0.988, 0.922, 0.922, 1}, {0.639, 0.176, 0.176, 1}
	case .Wall:
		return {0.945, 0.937, 0.910, 1}, {0.373, 0.369, 0.353, 1}
	case .Relay:
		return {0.882, 0.961, 0.933, 1}, {0.059, 0.431, 0.337, 1}
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

	case .Wire:
		spark := [4]f32{0.729, 0.459, 0.090, alpha}
		p->draw_line(cx - 10, cy, cx + 10, cy, 3, spark)
		p->draw_line(cx, cy - 10, cx, cy + 10, 3, spark)
		p->draw_circle(cx, cy, 3, stroke)

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
		if (tile_consumes_energy(tile.kind) || tile.kind == .Wire) && !tile.energized {
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
	case .Core, .Farm, .Wire, .Turret, .Wall:
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
