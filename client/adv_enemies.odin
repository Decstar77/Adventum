package main

import "core:math"
import "core:math/rand"

WORLD_RADIUS_HEX   :: i32(30)
ENEMY_SPAWN_RADIUS :: f32(700)

Enemy_Kind :: enum {
	Crawler,
	Brute,
}

Enemy :: struct {
	kind: Enemy_Kind,
	pos:  [2]f32,
	hp:   f32,
}

Pathing_Weights :: struct {
	empty: i32,
	wall:  i32,
	other: i32,
}

CRAWLER_WEIGHTS :: Pathing_Weights{empty = 2, wall = 20, other = 10}
BRUTE_WEIGHTS   :: Pathing_Weights{empty = 3, wall =  2, other =  4}

enemy_stats :: proc(kind: Enemy_Kind) -> (hp, speed, dmg: f32) {
	switch kind {
	case .Crawler: return 20, 80, 10
	case .Brute:   return 100, 35, 30
	}
	return 0, 0, 0
}

enemy_kind_name :: proc(kind: Enemy_Kind) -> string {
	switch kind {
	case .Crawler: return "Crawler"
	case .Brute:   return "Brute"
	}
	return "?"
}

Path_Field :: struct {
	dist: map[Hex_Coord]i32,
	next: map[Hex_Coord]Hex_Coord,
}

path_field_clear :: proc(f: ^Path_Field) {
	clear(&f.dist)
	clear(&f.next)
}

path_field_destroy :: proc(f: ^Path_Field) {
	delete(f.dist)
	delete(f.next)
}

build_path_field :: proc(w: ^World, field: ^Path_Field, weights: Pathing_Weights) {
	path_field_clear(field)
	field.dist[w.core] = 0

	open: [dynamic]Hex_Coord
	defer delete(open)
	append(&open, w.core)

	settled: map[Hex_Coord]bool
	defer delete(settled)

	for len(open) > 0 {
		best_idx := -1
		best_dist: i32
		for i in 0 ..< len(open) {
			if open[i] in settled do continue
			d := field.dist[open[i]]
			if best_idx < 0 || d < best_dist {
				best_idx = i
				best_dist = d
			}
		}
		if best_idx < 0 do break

		cur := open[best_idx]
		unordered_remove(&open, best_idx)

		if cur in settled do continue
		settled[cur] = true
		cur_dist := field.dist[cur]

		for d in HEX_NEIGHBOR_OFFSETS {
			n := Hex_Coord{cur.x + d.x, cur.y + d.y}
			if hex_distance(n, w.core) > WORLD_RADIUS_HEX do continue

			cost: i32
			if t, ok := w.tiles[n]; ok {
				#partial switch t.kind {
				case .Wall: cost = weights.wall
				case:       cost = weights.other
				}
			} else {
				cost = weights.empty
			}

			new_dist := cur_dist + cost
			existing, has := field.dist[n]
			if !has || new_dist < existing {
				field.dist[n] = new_dist
				field.next[n] = cur
				append(&open, n)
			}
		}
	}
}

enemy_field_for :: proc(w: ^World, kind: Enemy_Kind) -> ^Path_Field {
	switch kind {
	case .Crawler: return &w.field_crawler
	case .Brute:   return &w.field_brute
	}
	return &w.field_crawler
}

enemy_spawn :: proc(w: ^World, kind: Enemy_Kind) {
	angle := rand.float32_range(0, 2 * math.PI)
	pos := [2]f32{
		math.cos(angle) * ENEMY_SPAWN_RADIUS,
		math.sin(angle) * ENEMY_SPAWN_RADIUS,
	}
	hp, _, _ := enemy_stats(kind)
	append(&w.enemies, Enemy{kind = kind, pos = pos, hp = hp})
}

ENEMY_BODY_RADIUS :: f32(10)

@(private="file")
nearest_tile_to :: proc(w: ^World, from: [2]f32) -> (Hex_Coord, bool) {
	best_d2 := f32(0)
	best:    Hex_Coord
	found := false
	for coord in w.tiles {
		center := hex_to_pixel(coord)
		dx := center.x - from.x
		dy := center.y - from.y
		d2 := dx * dx + dy * dy
		if !found || d2 < best_d2 {
			best_d2 = d2
			best    = coord
			found   = true
		}
	}
	return best, found
}

// Phase-5 behaviour: every enemy walks straight at its nearest tile and chips it
// in place. Per-enemy nuance (Brutes preferring walls, Crawlers routing around)
// will return later via the path-field code retained above.
enemies_update :: proc(w: ^World, dt: f32) {
	for i in 0 ..< len(w.enemies) {
		e := &w.enemies[i]
		_, speed, dmg := enemy_stats(e.kind)

		target, ok := nearest_tile_to(w, e.pos)
		if !ok do continue
		center := hex_to_pixel(target)
		dx := center.x - e.pos.x
		dy := center.y - e.pos.y
		d := math.sqrt(dx * dx + dy * dy)

		// Stop at the tile boundary (hex edge along the approach direction)
		// rather than the tile centre, plus a small body-radius buffer.
		boundary := hex_boundary_distance(-dx, -dy)
		stop_dist := boundary + ENEMY_BODY_RADIUS

		if d <= stop_dist {
			tile, present := w.tiles[target]
			if present {
				tile.hp -= dmg * dt
				if tile.hp <= 0 && tile.kind != .Core {
					world_remove(w, target)
				} else {
					w.tiles[target] = tile
				}
			}
			continue
		}

		step := speed * dt
		travel := min(step, d - stop_dist)
		if travel > 0 {
			e.pos.x += dx / d * travel
			e.pos.y += dy / d * travel
		}
	}
}

// Small health bar centred at (cx, cy). Skips drawing when at full health.
draw_health_bar :: proc(g: ^Graphics, cx, cy, width: f32, hp, max_hp: f32) {
	if max_hp <= 0 || hp >= max_hp do return
	frac := clamp(hp / max_hp, 0, 1)
	height := f32(3)
	x := cx - width * 0.5
	y := cy - height * 0.5
	draw_rect(g, x - 1, y - 1, width + 2, height + 2, {0, 0, 0, 0.7})
	draw_rect(g, x, y, width, height, {0.18, 0.18, 0.18, 0.9})
	fill_color: [4]f32
	switch {
	case frac > 0.6: fill_color = {0.42, 0.78, 0.34, 1}
	case frac > 0.3: fill_color = {0.93, 0.78, 0.20, 1}
	case:            fill_color = {0.88, 0.29, 0.29, 1}
	}
	draw_rect(g, x, y, width * frac, height, fill_color)
}

enemies_render :: proc(w: ^World, g: ^Graphics) {
	for e in w.enemies {
		max_hp, _, _ := enemy_stats(e.kind)
		switch e.kind {
		case .Crawler:
			draw_circle(g, e.pos.x, e.pos.y, 10, {0.988, 0.922, 0.922, 1})
			draw_circle(g, e.pos.x, e.pos.y,  5, {0.886, 0.294, 0.290, 1})
			draw_health_bar(g, e.pos.x, e.pos.y - 16, 20, e.hp, max_hp)
		case .Brute:
			draw_rect(g, e.pos.x - 9, e.pos.y - 9, 18, 18, {0.980, 0.933, 0.855, 1})
			draw_rect(g, e.pos.x - 5, e.pos.y - 5, 10, 10, {0.729, 0.459, 0.090, 1})
			draw_health_bar(g, e.pos.x, e.pos.y - 16, 24, e.hp, max_hp)
		}
	}
}
