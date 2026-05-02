package main

Tile_Kind :: enum {
	Core,
	Farm,
	Generator,
	Turret,
	Wall,
	Relay,
}

TILE_KIND_COUNT :: len(Tile_Kind)

BUILD_RANGE       :: 2
GENERATOR_OUTPUT  :: 3
START_FOOD        :: f32(30)

Tile :: struct {
	kind:      Tile_Kind,
	hp:        f32,
	energized: bool,
	cooldown:  f32,
}

World :: struct {
	tiles:         map[Hex_Coord]Tile,
	core:          Hex_Coord,
	food:          f32,
	scrap:         i32,
	enemies:       [dynamic]Enemy,
	projectiles:   [dynamic]Projectile,
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
	w.tiles[c] = Tile{kind = kind, hp = tile_max_hp(kind)}
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

tile_max_hp :: proc(kind: Tile_Kind) -> f32 {
	switch kind {
	case .Core:      return 200
	case .Wall:      return 200
	case .Turret:    return 80
	case .Generator: return 60
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

world_power_remaining :: proc(w: ^World) -> i32 {
	supply := i32(0)
	demand := i32(0)
	for _, tile in w.tiles {
		if tile.kind == .Generator do supply += i32(GENERATOR_OUTPUT)
		if tile_consumes_energy(tile.kind) do demand += 1
	}
	return supply - demand
}

@(private="file")
world_recompute_energy :: proc(w: ^World) {
	// Pass 1: producers self-power; everything else starts cold.
	for coord, tile in w.tiles {
		t := tile
		t.energized = (tile.kind == .Generator || tile.kind == .Core)
		w.tiles[coord] = t
	}

	// Pass 2: each generator powers up to GENERATOR_OUTPUT consumer neighbors.
	for coord, tile in w.tiles {
		if tile.kind != .Generator do continue
		capacity := GENERATOR_OUTPUT
		for d in HEX_NEIGHBOR_OFFSETS {
			if capacity <= 0 do break
			n := Hex_Coord{coord.x + d.x, coord.y + d.y}
			nt, ok := w.tiles[n]
			if !ok do continue
			if !tile_consumes_energy(nt.kind) do continue
			if nt.energized do continue
			nt.energized = true
			w.tiles[n] = nt
			capacity -= 1
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
	case .Turret:
		return {0.988, 0.922, 0.922, 1}, {0.639, 0.176, 0.176, 1}
	case .Wall:
		return {0.945, 0.937, 0.910, 1}, {0.373, 0.369, 0.353, 1}
	case .Relay:
		return {0.882, 0.961, 0.933, 1}, {0.059, 0.431, 0.337, 1}
	}
	return {1, 1, 1, 1}, {0, 0, 0, 1}
}

@(private="file")
draw_tile_marker :: proc(g: ^Graphics, c: Hex_Coord, kind: Tile_Kind, alpha: f32) {
	center := hex_to_pixel(c)
	cx, cy := center.x, center.y
	_, stroke := tile_color(kind)
	stroke.a *= alpha

	switch kind {
	case .Core:
		draw_circle(g, cx, cy, 10, stroke)

	case .Farm:
		draw_rect(g, cx - 11, cy - 11, 9, 9, stroke)
		draw_rect(g, cx +  2, cy - 11, 9, 9, stroke)
		light := [4]f32{0.388, 0.600, 0.133, alpha}
		draw_rect(g, cx - 11, cy +  2, 9, 9, light)
		draw_rect(g, cx +  2, cy +  2, 9, 9, light)

	case .Generator:
		amber := [4]f32{0.729, 0.459, 0.090, alpha}
		draw_line(g, cx - 6, cy - 12, cx + 6, cy +  0, 3, amber)
		draw_line(g, cx + 6, cy +  0, cx - 4, cy + 12, 3, amber)

	case .Turret:
		hot := [4]f32{0.886, 0.294, 0.290, alpha}
		draw_circle(g, cx, cy + 2, 8, hot)
		draw_rect(g, cx - 2, cy - 14, 4, 12, stroke)

	case .Wall:
		mid := [4]f32{0.533, 0.529, 0.502, alpha}
		draw_rect(g, cx - 13, cy - 8, 9, 9, mid)
		draw_rect(g, cx +  4, cy - 8, 9, 9, mid)
		draw_rect(g, cx -  4, cy + 1, 9, 9, stroke)

	case .Relay:
		ring_outer := [4]f32{0.365, 0.792, 0.647, alpha}
		ring_inner := [4]f32{0.114, 0.620, 0.459, alpha}
		fill, _ := tile_color(kind)
		draw_circle(g, cx, cy, 10, ring_outer)
		draw_circle(g, cx, cy,  7, fill)
		draw_circle(g, cx, cy,  4, ring_inner)
	}
}

world_render :: proc(w: ^World, g: ^Graphics) {
	for coord, tile in w.tiles {
		_, stroke := tile_color(tile.kind)
		alpha := f32(1)
		if tile_consumes_energy(tile.kind) && !tile.energized {
			alpha = 0.45
		}
		stroke.a *= alpha
		draw_hex_outline(g, coord, 2, stroke)
		draw_tile_marker(g, coord, tile.kind, alpha)
	}
}

world_render_hover :: proc(w: ^World, g: ^Graphics, hover: Hex_Coord, placing: bool, selected: Tile_Kind) {
	if !placing {
		// Selection feedback for Default mode: a faint white outline, regardless of contents.
		draw_hex_outline(g, hover, 1.5, {1, 1, 1, 0.55})
		return
	}
	if hover in w.tiles {
		draw_hex_outline(g, hover, 1.5, {1, 1, 1, 0.35})
		return
	}
	can := world_can_place(w, hover, selected)
	color: [4]f32
	if can {
		color = {0.30, 0.85, 0.45, 0.85}
	} else {
		color = {0.85, 0.30, 0.30, 0.55}
	}
	draw_hex_outline(g, hover, 2.5, color)
}
