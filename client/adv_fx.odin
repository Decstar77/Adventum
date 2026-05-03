package main

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

particles_render :: proc(w: ^World, g: ^Graphics) {
	for p in w.particles {
		t := p.life / p.max_life            // 1 -> 0 over lifetime
		r := p.r1 + (p.r0 - p.r1) * t
		if r <= 0.25 do continue
		c := p.color
		c.a *= t
		draw_circle(g, p.pos.x, p.pos.y, r, c)
	}
}
