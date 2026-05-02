package main

import "core:math"

HEX_SIZE :: f32(48)

@(private="file") SQRT3 :: f32(1.7320508)

Hex_Coord :: [2]i32

HEX_NEIGHBOR_OFFSETS := [6]Hex_Coord{
	{+1,  0}, {+1, -1}, {0, -1},
	{-1,  0}, {-1, +1}, {0, +1},
}

hex_to_pixel :: proc(c: Hex_Coord) -> [2]f32 {
	q := f32(c.x)
	r := f32(c.y)
	return {
		HEX_SIZE * 1.5 * q,
		HEX_SIZE * SQRT3 * (r + q * 0.5),
	}
}

pixel_to_hex :: proc(p: [2]f32) -> Hex_Coord {
	fq := (2.0 / 3.0) * p.x / HEX_SIZE
	fr := (-1.0 / 3.0 * p.x + (SQRT3 / 3.0) * p.y) / HEX_SIZE
	return hex_round(fq, fr)
}

hex_round :: proc(fq, fr: f32) -> Hex_Coord {
	fs := -fq - fr
	q := math.round(fq)
	r := math.round(fr)
	s := math.round(fs)
	dq := abs(q - fq)
	dr := abs(r - fr)
	ds := abs(s - fs)
	if dq > dr && dq > ds {
		q = -r - s
	} else if dr > ds {
		r = -q - s
	}
	return {i32(q), i32(r)}
}

hex_neighbor :: proc(c: Hex_Coord, dir: int) -> Hex_Coord {
	d := HEX_NEIGHBOR_OFFSETS[dir]
	return {c.x + d.x, c.y + d.y}
}

hex_distance :: proc(a, b: Hex_Coord) -> i32 {
	dq := abs(a.x - b.x)
	dr := abs(a.y - b.y)
	ds := abs((a.x + a.y) - (b.x + b.y))
	d := dq + dr + ds
	return d / 2
}

hex_corners :: proc(center: [2]f32) -> [6][2]f32 {
	corners: [6][2]f32
	for i in 0 ..< 6 {
		angle := f32(i) * (math.PI / 3.0)
		corners[i] = {
			center.x + HEX_SIZE * math.cos(angle),
			center.y + HEX_SIZE * math.sin(angle),
		}
	}
	return corners
}

draw_hex_outline :: proc(g: ^Graphics, c: Hex_Coord, thickness: f32, color: [4]f32) {
	center := hex_to_pixel(c)
	corners := hex_corners(center)
	for i in 0 ..< 6 {
		a := corners[i]
		b := corners[(i + 1) % 6]
		draw_line(g, a.x, a.y, b.x, b.y, thickness, color)
	}
}
