package game

import "core:math"
import "core:math/rand"

Particle :: struct {
	pos:      [2]f32,
	vel:      [2]f32,
	life:     f32,
	max_life: f32,
	r0:       f32,
	r1:       f32,
	color:    [4]f32,
	drag:     f32,
}

particles_clear :: proc(w: ^World) {
	clear(&w.particles)
}

@(private="file")
emit :: proc(w: ^World, p: Particle) {
	append(&w.particles, p)
}

fx_emit_muzzle :: proc(w: ^World, pos: [2]f32, angle: f32) {
	// Bright core flash, single short-lived puff.
	emit(w, Particle{
		pos      = pos,
		vel      = {math.cos(angle) * 30, math.sin(angle) * 30},
		life     = 0.10,
		max_life = 0.10,
		r0       = 7,
		r1       = 0,
		color    = {1.0, 0.92, 0.55, 1},
		drag     = 8,
	})
	// A handful of sparks fanned along the barrel.
	for _ in 0 ..< 5 {
		spread := rand.float32_range(-0.35, 0.35)
		a := angle + spread
		speed := rand.float32_range(120, 260)
		life  := rand.float32_range(0.12, 0.22)
		emit(w, Particle{
			pos      = pos,
			vel      = {math.cos(a) * speed, math.sin(a) * speed},
			life     = life,
			max_life = life,
			r0       = rand.float32_range(2.0, 3.2),
			r1       = 0,
			color    = {1.0, 0.62, 0.28, 1},
			drag     = 6,
		})
	}
}

// Soft warm contrail behind a Flyer. Lives long enough to leave a readable
// arc on the player's screen as the flyer banks, and fades through orange so
// it visually reads as exhaust rather than a duplicate of the yellow body.
fx_emit_flyer_trail :: proc(w: ^World, pos: [2]f32) {
	emit(w, Particle{
		pos      = pos,
		vel      = {0, 0},
		life     = 0.42,
		max_life = 0.42,
		r0       = 3.4,
		r1       = 0,
		color    = {1.0, 0.78, 0.30, 0.85},
		drag     = 0,
	})
	// Tiny core highlight on top so the start of the trail pops bright.
	emit(w, Particle{
		pos      = pos,
		vel      = {0, 0},
		life     = 0.14,
		max_life = 0.14,
		r0       = 2.0,
		r1       = 0,
		color    = {1.0, 0.96, 0.70, 0.95},
		drag     = 0,
	})
}

fx_emit_projectile_trail :: proc(w: ^World, pos: [2]f32) {
	emit(w, Particle{
		pos      = pos,
		vel      = {0, 0},
		life     = 0.14,
		max_life = 0.14,
		r0       = 2.6,
		r1       = 0,
		color    = {0.98, 0.55, 0.42, 0.85},
		drag     = 0,
	})
}

fx_emit_impact :: proc(w: ^World, pos: [2]f32, vel: [2]f32) {
	// Back-facing ring of sparks plus a quick flash.
	speed := math.sqrt(vel.x * vel.x + vel.y * vel.y)
	back_angle := f32(math.PI)
	if speed > 0.001 {
		back_angle = math.atan2(-vel.y, -vel.x)
	}
	emit(w, Particle{
		pos      = pos,
		vel      = {0, 0},
		life     = 0.12,
		max_life = 0.12,
		r0       = 9,
		r1       = 1,
		color    = {1.0, 0.88, 0.62, 1},
		drag     = 0,
	})
	for _ in 0 ..< 8 {
		a := back_angle + rand.float32_range(-1.0, 1.0)
		s := rand.float32_range(140, 280)
		life := rand.float32_range(0.18, 0.32)
		emit(w, Particle{
			pos      = pos,
			vel      = {math.cos(a) * s, math.sin(a) * s},
			life     = life,
			max_life = life,
			r0       = rand.float32_range(1.8, 3.0),
			r1       = 0,
			color    = {0.98, 0.45, 0.32, 1},
			drag     = 5,
		})
	}
}

fx_emit_enemy_attack :: proc(w: ^World, pos: [2]f32, toward: [2]f32) {
	// `toward` points from the enemy at the tile being struck. Sparks fly
	// back toward the attacker plus a small bright chip at the contact.
	angle := f32(0)
	if toward.x != 0 || toward.y != 0 {
		angle = math.atan2(-toward.y, -toward.x)
	}
	emit(w, Particle{
		pos      = pos,
		vel      = {0, 0},
		life     = 0.10,
		max_life = 0.10,
		r0       = 4,
		r1       = 0,
		color    = {1.0, 0.85, 0.55, 1},
		drag     = 0,
	})
	for _ in 0 ..< 3 {
		a := angle + rand.float32_range(-0.7, 0.7)
		s := rand.float32_range(80, 180)
		life := rand.float32_range(0.14, 0.26)
		emit(w, Particle{
			pos      = pos,
			vel      = {math.cos(a) * s, math.sin(a) * s},
			life     = life,
			max_life = life,
			r0       = rand.float32_range(1.4, 2.4),
			r1       = 0,
			color    = {0.95, 0.55, 0.30, 1},
			drag     = 5,
		})
	}
}

fx_emit_tile_destroyed :: proc(w: ^World, pos: [2]f32, kind: Tile_Kind) {
	fill, stroke := tile_color(kind)
	// Bright shockwave flash in the tile's stroke color.
	flash := stroke
	flash.a = 1
	emit(w, Particle{
		pos      = pos,
		vel      = {0, 0},
		life     = 0.28,
		max_life = 0.28,
		r0       = 28,
		r1       = 4,
		color    = flash,
		drag     = 0,
	})
	// Inner soft core in the fill color.
	core := fill
	core.a = 1
	emit(w, Particle{
		pos      = pos,
		vel      = {0, 0},
		life     = 0.18,
		max_life = 0.18,
		r0       = 18,
		r1       = 2,
		color    = core,
		drag     = 0,
	})
	// Debris chunks alternating between fill and stroke.
	for i in 0 ..< 22 {
		a := rand.float32_range(0, 2 * math.PI)
		s := rand.float32_range(80, 320)
		life := rand.float32_range(0.35, 0.70)
		c := i % 2 == 0 ? stroke : fill
		c.a = 1
		emit(w, Particle{
			pos      = pos,
			vel      = {math.cos(a) * s, math.sin(a) * s},
			life     = life,
			max_life = life,
			r0       = rand.float32_range(2.2, 4.2),
			r1       = 0,
			color    = c,
			drag     = 3,
		})
	}
}

fx_emit_enemy_death :: proc(w: ^World, pos: [2]f32, kind: Enemy_Kind) {
	core_color: [4]f32
	chunk_color: [4]f32
	count: int
	switch kind {
	case .Crawler:
		core_color  = {1.0, 0.78, 0.62, 1}
		chunk_color = {0.886, 0.294, 0.290, 1}
		count = 12
	case .Brute:
		core_color  = {1.0, 0.86, 0.58, 1}
		chunk_color = {0.729, 0.459, 0.090, 1}
		count = 18
	case .Spitter:
		core_color  = {0.78, 1.0, 0.92, 1}
		chunk_color = {0.114, 0.620, 0.459, 1}
		count = 12
	case .Swarmer:
		// Pink burst — extra debris because it splits into two crawlers and the
		// chunkier FX sells the "broke apart" beat.
		core_color  = {1.0, 0.85, 0.95, 1}
		chunk_color = {0.690, 0.137, 0.557, 1}
		count = 16
	case .Flyer:
		// Yellow burst — matches the triangle's body palette so the kill reads
		// as "the yellow thing exploded".
		core_color  = {1.00, 0.96, 0.65, 1}
		chunk_color = {0.98, 0.78, 0.18, 1}
		count = 14
	}
	// Central flash.
	emit(w, Particle{
		pos      = pos,
		vel      = {0, 0},
		life     = 0.18,
		max_life = 0.18,
		r0       = kind == .Brute ? 16 : 12,
		r1       = 2,
		color    = core_color,
		drag     = 0,
	})
	for _ in 0 ..< count {
		a := rand.float32_range(0, 2 * math.PI)
		s := rand.float32_range(60, kind == .Brute ? 260 : 200)
		life := rand.float32_range(0.30, 0.55)
		emit(w, Particle{
			pos      = pos,
			vel      = {math.cos(a) * s, math.sin(a) * s},
			life     = life,
			max_life = life,
			r0       = rand.float32_range(2.2, 4.0),
			r1       = 0,
			color    = chunk_color,
			drag     = 3.5,
		})
	}
}

// Big bright shockwave for the Core's one-shot bomb. Radius scales the visual
// so the FX matches the actual damage area the player paid for.
fx_emit_bomb :: proc(w: ^World, pos: [2]f32) {
	emit(w, Particle{
		pos = pos, vel = {0, 0},
		life = 0.45, max_life = 0.45,
		r0 = BOMB_RADIUS * 1.1, r1 = 8,
		color = {1.0, 0.85, 0.55, 1},
		drag  = 0,
	})
	emit(w, Particle{
		pos = pos, vel = {0, 0},
		life = 0.30, max_life = 0.30,
		r0 = BOMB_RADIUS * 0.7, r1 = 4,
		color = {1.0, 0.50, 0.30, 1},
		drag  = 0,
	})
	for _ in 0 ..< 40 {
		a := rand.float32_range(0, 2 * math.PI)
		s := rand.float32_range(120, 420)
		life := rand.float32_range(0.35, 0.70)
		emit(w, Particle{
			pos = pos,
			vel = {math.cos(a) * s, math.sin(a) * s},
			life = life, max_life = life,
			r0 = rand.float32_range(2.5, 4.5), r1 = 0,
			color = {1.0, 0.62, 0.28, 1},
			drag  = 3.5,
		})
	}
}

// Expanding circular wave used by the Swarmer's death. We don't have a true
// ring primitive — the renderer only draws filled discs — so we fake the
// outline by layering two particles whose `r0 < r1` so they grow as life
// drains. The slightly larger, fainter outer disc paints the bright edge, and
// a slightly smaller darker disc that grows at the same rate eats the inside,
// leaving the readable hollow ring you'd expect from a shockwave.
SWARMER_SHOCK_RADIUS :: f32(56)

fx_emit_swarmer_shock :: proc(w: ^World, pos: [2]f32) {
	life :: f32(0.42)
	// Outer bright edge: grows from a small dot to SWARMER_SHOCK_RADIUS while
	// fading. r0 is "life full" (small), r1 is "life empty" (big), since the
	// renderer lerps r = r1 + (r0 - r1) * t with t going 1→0.
	emit(w, Particle{
		pos = pos, vel = {0, 0},
		life = life, max_life = life,
		r0 = 4, r1 = SWARMER_SHOCK_RADIUS,
		color = {1.0, 0.78, 0.95, 1},
		drag  = 0,
	})
	// Inner "hole" that grows slightly slower, painted in the background tone
	// so it sells the ring silhouette.
	emit(w, Particle{
		pos = pos, vel = {0, 0},
		life = life * 0.95, max_life = life * 0.95,
		r0 = 1, r1 = SWARMER_SHOCK_RADIUS - 8,
		color = {0.10, 0.11, 0.14, 1},
		drag  = 0,
	})
	// A handful of radial sparks ride the wavefront so the burst doesn't
	// look like a single 2D primitive.
	for k in 0 ..< 14 {
		a := f32(k) * (2 * math.PI / 14) + rand.float32_range(-0.1, 0.1)
		s := rand.float32_range(140, 200)
		emit(w, Particle{
			pos = pos,
			vel = {math.cos(a) * s, math.sin(a) * s},
			life = 0.35, max_life = 0.35,
			r0 = rand.float32_range(2.0, 3.2), r1 = 0,
			color = {0.95, 0.55, 0.85, 1},
			drag  = 3,
		})
	}
}

// Smaller flash for mortar shell detonations / splash hits. `r` is the splash
// radius so a tier-3 mortar visibly flashes wider than a tier-1.
fx_emit_bomb_small :: proc(w: ^World, pos: [2]f32, r: f32) {
	emit(w, Particle{
		pos = pos, vel = {0, 0},
		life = 0.22, max_life = 0.22,
		r0 = r * 1.0, r1 = 3,
		color = {1.0, 0.80, 0.55, 1},
		drag  = 0,
	})
	for _ in 0 ..< 14 {
		a := rand.float32_range(0, 2 * math.PI)
		s := rand.float32_range(80, 260)
		life := rand.float32_range(0.20, 0.40)
		emit(w, Particle{
			pos = pos,
			vel = {math.cos(a) * s, math.sin(a) * s},
			life = life, max_life = life,
			r0 = rand.float32_range(1.8, 3.2), r1 = 0,
			color = {0.98, 0.55, 0.30, 1},
			drag  = 4,
		})
	}
}

particles_update :: proc(w: ^World, dt: f32) {
	for i := len(w.particles) - 1; i >= 0; i -= 1 {
		p := &w.particles[i]
		p.life -= dt
		if p.life <= 0 {
			unordered_remove(&w.particles, i)
			continue
		}
		// Exponential drag: v *= exp(-drag * dt).
		if p.drag > 0 {
			k := math.exp(-p.drag * dt)
			p.vel.x *= k
			p.vel.y *= k
		}
		p.pos.x += p.vel.x * dt
		p.pos.y += p.vel.y * dt
	}
}

particles_render :: proc(w: ^World, plat: ^Platform) {
	for p in w.particles {
		t := p.life / p.max_life            // 1 -> 0 over lifetime
		r := p.r1 + (p.r0 - p.r1) * t
		if r <= 0.25 do continue
		c := p.color
		c.a *= t
		plat->draw_circle(p.pos.x, p.pos.y, r, c)
	}
}
