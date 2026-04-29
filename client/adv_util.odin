package main

import "core:fmt"
import "core:math"
import "core:math/ease"
import "core:math/linalg"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:strconv"

contains :: proc(arr: []$T, value: T) -> bool {
	for x in arr {
		if x == value {
			return true
		}
	}
	return false
}

find :: proc(arr: []$T, value: T) -> int {
	for x, index in arr {
		if x == value {
			return index
		}
	}
	return -1
}

Manifold :: struct {
	pen:    f32, // penetration depth
	normal: v2, // direction from box1 to box2
}

aabb_contains_point :: proc(min: v2, max: v2, p: v2) -> bool {
	return p.x >= min.x && p.x <= max.x && p.y >= min.y && p.y <= max.y
}

aabb_vs_aabb :: proc(min1: v2, max1: v2, min2: v2, max2: v2) -> bool {
	return !(max1.x < min2.x || max2.x < min1.x || max1.y < min2.y || max2.y < min1.y)
}

distance2 :: proc(a: v2, b: v2) -> f32 {
	return linalg.length2(b - a)
}

collide_aabb_ex :: proc(min1, max1, min2, max2: v2) -> (bool, Manifold) {
	// calculate half extents
	half1 := (max1 - min1) * 0.5
	half2 := (max2 - min2) * 0.5

	// centers
	center1 := min1 + half1
	center2 := min2 + half2

	// difference vector
	diff := center2 - center1

	// overlap along each axis
	overlap_x := (half1.x + half2.x) - abs(diff.x)
	overlap_y := (half1.y + half2.y) - abs(diff.y)

	// if either overlap is negative → no intersection
	if overlap_x <= 0 || overlap_y <= 0 {
		return false, Manifold{}
	}

	// pick axis of least penetration
	manifold: Manifold
	if overlap_x < overlap_y {
		manifold.pen = overlap_x
		manifold.normal = v2{math.sign(diff.x), 0}
	} else {
		manifold.pen = overlap_y
		manifold.normal = v2{0, math.sign(diff.y)}
	}

	return true, manifold
}

search_folder :: proc(dir: string, ext: string) -> [dynamic]string {
	f, err1 := os.open(dir)
	if err1 != os.ERROR_NONE {
		fmt.eprintln("Could not open directory: %v", err1)
		os.exit(1)
	}
	defer os.close(f)

	entries, err2 := os.read_dir(f, -1)
	if err2 != nil {
		fmt.printf("Failed to read dir %s: %v\n", dir, err2)
		return {}
	}

	paths: [dynamic]string

	for entry in entries {
		stuff: [2]string
		stuff[0] = dir
		stuff[1] = entry.name
		path := filepath.join(stuff[:])
		if entry.is_dir {
			newPaths := find_images_paths(path)
			for p in newPaths {
				append(&paths, p)
			}
			delete(newPaths)
		} else {
			if filepath.ext(path) == ext {
				append(&paths, path)
			}
		}
	}

	return paths
}


