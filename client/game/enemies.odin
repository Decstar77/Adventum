package game

import "core:math"
import "core:math/rand"

WORLD_RADIUS_HEX   :: i32(30)
ENEMY_SPAWN_RADIUS :: f32(700)

Enemy_Kind :: enum {
	Crawler,
	Brute,
	Spitter,
	Swarmer,
}

// On death, a Swarmer splits into this many baby Crawlers spawned at its
// position. Keeps the on-death surge readable without ballooning enemy counts.
SWARMER_SPLIT_COUNT :: 2

Enemy :: struct {
	kind:        Enemy_Kind,
	pos:         [2]f32,
	hp:          f32,
	// Per-enemy attack pacing. Only Spitter currently uses this (it sits at
	// standoff range and lobs a projectile every `SPITTER_FIRE_INTERVAL`
	// seconds). Melee kinds leave it at zero — their damage is applied
	// continuously in `enemies_update`.
	attack_cd:   f32,
}

// Spitter projectile tuning. Slower than turret bullets so the player can
// react; same hit feel via the existing fx_emit_impact-style flash, but the
// damage goes to the targeted tile rather than to a player projectile.
SPITTER_FIRE_INTERVAL :: f32(1.4)
SPITTER_PROJ_SPEED    :: f32(280)
SPITTER_PROJ_LIFE     :: f32(2.2)
SPITTER_PROJ_HIT_R    :: f32(10)

Enemy_Projectile :: struct {
	pos:    [2]f32,
	vel:    [2]f32,
	dmg:    f32,
	life:   f32,
	target: Hex_Coord,
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
	case .Spitter: return 30, 55, 14
	case .Swarmer: return 35, 65, 8
	}
	return 0, 0, 0
}

// Distance the enemy stops short of a tile's hex boundary before attacking.
// Contact-melee kinds return 0; ranged kinds stand off and chip from there.
enemy_attack_range :: proc(kind: Enemy_Kind) -> f32 {
	switch kind {
	case .Crawler, .Brute, .Swarmer: return 0
	case .Spitter:                   return 70
	}
	return 0
}

enemy_kind_name :: proc(kind: Enemy_Kind) -> string {
	switch kind {
	case .Crawler: return "Crawler"
	case .Brute:   return "Brute"
	case .Spitter: return "Spitter"
	case .Swarmer: return "Swarmer"
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
	case .Crawler, .Spitter, .Swarmer: return &w.field_crawler
	case .Brute:                       return &w.field_brute
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
	// EMP completely freezes the field: enemies don't shuffle, don't gnaw on
	// tiles, and don't drop sparks. Cooldown bleed-down is handled in
	// `world_tick`. The render pass still draws them, just statue-still.
	if w.emp_time > 0 do return
	for i in 0 ..< len(w.enemies) {
		e := &w.enemies[i]
		_, speed, dmg := enemy_stats(e.kind)

		// All enemies bleed their attack cooldown regardless of whether they
		// have a target — keeps newly-arriving Spitters from getting a free
		// instant first-shot.
		if e.attack_cd > 0 {
			e.attack_cd -= dt
			if e.attack_cd < 0 do e.attack_cd = 0
		}

		target, ok := nearest_tile_to(w, e.pos)
		if !ok do continue
		center := hex_to_pixel(target)
		dx := center.x - e.pos.x
		dy := center.y - e.pos.y
		d := math.sqrt(dx * dx + dy * dy)

		// Stop at the tile boundary (hex edge along the approach direction)
		// rather than the tile centre, plus a small body-radius buffer.
		boundary := hex_boundary_distance(-dx, -dy)
		stop_dist := boundary + ENEMY_BODY_RADIUS + enemy_attack_range(e.kind)

		if d <= stop_dist {
			tile, present := w.tiles[target]
			if present {
				// Spitter sits at standoff range and lobs projectiles on a
				// timer; melee kinds chip continuously like before.
				if e.kind == .Spitter {
					if e.attack_cd <= 0 {
						dir := [2]f32{dx / max(d, 0.001), dy / max(d, 0.001)}
						muzzle := [2]f32{e.pos.x + dir.x * 10, e.pos.y + dir.y * 10}
						append(&w.enemy_projectiles, Enemy_Projectile{
							pos    = muzzle,
							vel    = {dir.x * SPITTER_PROJ_SPEED, dir.y * SPITTER_PROJ_SPEED},
							dmg    = dmg,
							life   = SPITTER_PROJ_LIFE,
							target = target,
						})
						world_queue_sound_at(w, .Enemy_Attack, e.pos)
						e.attack_cd = SPITTER_FIRE_INTERVAL
					}
				} else {
					tile.hp -= dmg * dt
					// Spark at the contact point on the hex boundary, biased
					// away from the tile center toward the enemy.
					dir := [2]f32{dx / max(d, 0.001), dy / max(d, 0.001)}
					contact := [2]f32{
						center.x - dir.x * boundary,
						center.y - dir.y * boundary,
					}
					// Probabilistic emission — averages a few sparks per second
					// per attacking enemy so dense swarms don't drown the screen.
					if rand.float32() < dt * 6 {
						fx_emit_enemy_attack(w, contact, dir)
						world_queue_sound_at(w, .Enemy_Attack, contact)
					}
					if tile.hp <= 0 && tile.kind != .Core {
						fx_emit_tile_destroyed(w, center, tile.kind)
						world_queue_sound_at(w, .Building_Explode, center)
						world_remove(w, target)
					} else {
						w.tiles[target] = tile
					}
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

// Step Spitter projectiles. Each shot is locked onto its `target` hex; we
// damage that tile when the projectile reaches its centre. If the tile died
// before the shot lands the projectile just expires (no friendly fire to
// other enemies — this isn't a turret bullet).
enemy_projectiles_update :: proc(w: ^World, dt: f32) {
	hit_r2 := SPITTER_PROJ_HIT_R * SPITTER_PROJ_HIT_R
	for i := len(w.enemy_projectiles) - 1; i >= 0; i -= 1 {
		ep := &w.enemy_projectiles[i]
		ep.pos.x += ep.vel.x * dt
		ep.pos.y += ep.vel.y * dt
		ep.life  -= dt

		hit := false
		if tile, present := w.tiles[ep.target]; present {
			center := hex_to_pixel(ep.target)
			dx := center.x - ep.pos.x
			dy := center.y - ep.pos.y
			if dx*dx + dy*dy <= hit_r2 {
				tile.hp -= ep.dmg
				if tile.hp <= 0 && tile.kind != .Core {
					fx_emit_tile_destroyed(w, center, tile.kind)
					world_queue_sound_at(w, .Building_Explode, center)
					world_remove(w, ep.target)
				} else {
					w.tiles[ep.target] = tile
				}
				fx_emit_impact(w, ep.pos, ep.vel)
				hit = true
			}
		}
		if hit || ep.life <= 0 {
			unordered_remove(&w.enemy_projectiles, i)
		}
	}
}

enemy_projectiles_render :: proc(w: ^World, p: ^Platform) {
	// Teal globule to match the Spitter's body palette.
	core := [4]f32{0.114, 0.620, 0.459, 1}
	rim  := [4]f32{0.78,  1.0,   0.92,  1}
	for ep in w.enemy_projectiles {
		p->draw_circle(ep.pos.x, ep.pos.y, 5, rim)
		p->draw_circle(ep.pos.x, ep.pos.y, 3, core)
	}
}

// Small health bar centred at (cx, cy). Skips drawing when at full health.
draw_health_bar :: proc(p: ^Platform, cx, cy, width: f32, hp, max_hp: f32) {
	if max_hp <= 0 || hp >= max_hp do return
	frac := clamp(hp / max_hp, 0, 1)
	height := f32(3)
	x := cx - width * 0.5
	y := cy - height * 0.5
	p->draw_rect(x - 1, y - 1, width + 2, height + 2, {0, 0, 0, 0.7})
	p->draw_rect(x, y, width, height, {0.18, 0.18, 0.18, 0.9})
	fill_color: [4]f32
	switch {
	case frac > 0.6: fill_color = {0.42, 0.78, 0.34, 1}
	case frac > 0.3: fill_color = {0.93, 0.78, 0.20, 1}
	case:            fill_color = {0.88, 0.29, 0.29, 1}
	}
	p->draw_rect(x, y, width * frac, height, fill_color)
}

enemies_render :: proc(w: ^World, p: ^Platform) {
	for e in w.enemies {
		max_hp, _, _ := enemy_stats(e.kind)
		switch e.kind {
		case .Crawler:
			p->draw_circle(e.pos.x, e.pos.y, 10, {0.988, 0.922, 0.922, 1})
			p->draw_circle(e.pos.x, e.pos.y,  5, {0.886, 0.294, 0.290, 1})
			draw_health_bar(p, e.pos.x, e.pos.y - 16, 20, e.hp, max_hp)
		case .Brute:
			p->draw_rect(e.pos.x - 9, e.pos.y - 9, 18, 18, {0.980, 0.933, 0.855, 1})
			p->draw_rect(e.pos.x - 5, e.pos.y - 5, 10, 10, {0.729, 0.459, 0.090, 1})
			draw_health_bar(p, e.pos.x, e.pos.y - 16, 24, e.hp, max_hp)
		case .Spitter:
			// Pale shell with a teal core — visually distinct from the warm
			// red Crawler so the short-range threat reads at a glance.
			p->draw_circle(e.pos.x, e.pos.y, 9, {0.882, 0.961, 0.933, 1})
			p->draw_circle(e.pos.x, e.pos.y, 5, {0.114, 0.620, 0.459, 1})
			draw_health_bar(p, e.pos.x, e.pos.y - 16, 22, e.hp, max_hp)
		case .Swarmer:
			// Magenta cluster — three small lobes around a darker core to
			// telegraph "this thing breaks apart on death". Tiny offsets keep
			// the silhouette legible at the same eye scale as a Crawler.
			lobe  := [4]f32{0.992, 0.776, 0.953, 1}
			core  := [4]f32{0.690, 0.137, 0.557, 1}
			p->draw_circle(e.pos.x - 5, e.pos.y - 3, 5, lobe)
			p->draw_circle(e.pos.x + 5, e.pos.y - 3, 5, lobe)
			p->draw_circle(e.pos.x,     e.pos.y + 4, 5, lobe)
			p->draw_circle(e.pos.x,     e.pos.y,     4, core)
			draw_health_bar(p, e.pos.x, e.pos.y - 16, 22, e.hp, max_hp)
		}
	}
}
