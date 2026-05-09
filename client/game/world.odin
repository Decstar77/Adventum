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
START_FOOD  :: f32(30)

Tile :: struct {
	kind:      Tile_Kind,
	hp:        f32,
	energized: bool,
	cooldown:  f32,
	aim_angle: f32, // turret barrel angle in radians (atan2 convention)
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
	w.tiles[w.core] = Tile{kind = .Core, hp = 200, energized = true}
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
	case .Wall:      return 3
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
		if hex_distance(c, coord) <= BUILD_RANGE do return true
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
	tile := Tile{kind = kind, hp = tile_max_hp(kind)}
	if kind == .Turret {
		tile.aim_angle = -math.PI * 0.5 // start pointing up
	}
	w.tiles[c] = tile
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

tile_max_hp :: proc(kind: Tile_Kind) -> f32 {
	switch kind {
	case .Core:      return 200
	case .Wall:      return 200
	case .Turret:    return 80
	case .Generator: return 60
	case .Wire:      return 30
	case .Relay:     return 50
	case .Farm:      return 50
	}
	return 50
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

	// Pass 3: any consumer adjacent to a powered conductor (Generator or
	// energized Wire) is energized.
	for coord, tile in w.tiles {
		is_conductor := tile.kind == .Generator || (tile.kind == .Wire && tile.energized)
		if !is_conductor do continue
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

world_tick :: proc(w: ^World, dt: f32) {
	farms := f32(world_count_kind(w, .Farm))
	w.food += farms * dt
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

draw_tile_icon :: proc(p: ^Platform, cx, cy: f32, kind: Tile_Kind, alpha: f32, aim_angle: f32 = -math.PI * 0.5) {
	_, stroke := tile_color(kind)
	stroke.a *= alpha

	switch kind {
	case .Core:
		p->draw_circle(cx, cy, 10, stroke)

	case .Farm:
		p->draw_rect(cx - 11, cy - 11, 9, 9, stroke)
		p->draw_rect(cx +  2, cy - 11, 9, 9, stroke)
		light := [4]f32{0.388, 0.600, 0.133, alpha}
		p->draw_rect(cx - 11, cy +  2, 9, 9, light)
		p->draw_rect(cx +  2, cy +  2, 9, 9, light)

	case .Generator:
		amber := [4]f32{0.729, 0.459, 0.090, alpha}
		p->draw_line(cx - 6, cy - 12, cx + 6, cy +  0, 3, amber)
		p->draw_line(cx + 6, cy +  0, cx - 4, cy + 12, 3, amber)

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

	case .Wall:
		mid := [4]f32{0.533, 0.529, 0.502, alpha}
		p->draw_rect(cx - 13, cy - 8, 9, 9, mid)
		p->draw_rect(cx +  4, cy - 8, 9, 9, mid)
		p->draw_rect(cx -  4, cy + 1, 9, 9, stroke)

	case .Relay:
		ring_outer := [4]f32{0.365, 0.792, 0.647, alpha}
		ring_inner := [4]f32{0.114, 0.620, 0.459, alpha}
		fill, _ := tile_color(kind)
		p->draw_circle(cx, cy, 10, ring_outer)
		p->draw_circle(cx, cy,  7, fill)
		p->draw_circle(cx, cy,  4, ring_inner)
	}
}

@(private="file")
draw_tile_marker :: proc(p: ^Platform, c: Hex_Coord, tile: Tile, alpha: f32) {
	center := hex_to_pixel(c)
	draw_tile_icon(p, center.x, center.y, tile.kind, alpha, tile.aim_angle)
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

		max_hp := tile_max_hp(tile.kind)
		center := hex_to_pixel(coord)
		draw_health_bar(p, center.x, center.y - HEX_APOTHEM + 6, 30, tile.hp, max_hp)
	}
}

@(private="file")
render_buildable_area :: proc(w: ^World, p: ^Platform) {
	blue := [4]f32{0.36, 0.62, 0.95, 0.25}
	visit :: proc(w: ^World, p: ^Platform, c: Hex_Coord, color: [4]f32, seen: ^map[Hex_Coord]bool) {
		for q in i32(-BUILD_RANGE) ..= i32(BUILD_RANGE) {
			for r in i32(-BUILD_RANGE) ..= i32(BUILD_RANGE) {
				n := Hex_Coord{c.x + q, c.y + r}
				if hex_distance(n, c) > BUILD_RANGE do continue
				if n in seen^ do continue
				if n in w.tiles do continue
				seen^[n] = true
				draw_hex_outline(p, n, 1.5, color)
			}
		}
	}

	seen: map[Hex_Coord]bool
	defer delete(seen)
	visit(w, p, w.core, blue, &seen)
	for coord, tile in w.tiles {
		if tile.kind == .Relay {
			visit(w, p, coord, blue, &seen)
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
