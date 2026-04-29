package main

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/ease"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import t "core:time"

import sapp "sokol/app"
import sg "sokol/gfx"
import sglue "sokol/glue"
import slog "sokol/log"

import stbi "vendor:stb/image"
import stbrp "vendor:stb/rect_pack"
import stbtt "vendor:stb/truetype"

Vertex :: struct {
	pos:            Vector2,
	col:            Vector4,
	uv:             Vector2,
	tex_index:      u8,
	_pad:           [3]u8,
	color_override: Vector4,
}

Draw_Frame :: struct {
	quads:         [MAX_QUADS]Quad,
	quad_count:    int,
	projection:    Matrix4,
	projectionInv: Matrix4,
	camera_xform:  Matrix4,
	cameraInv:     Matrix4,
}

TextAlign :: enum {
	BOTTOM_LEFT,
	BOTTOM_CENTER,
	BOTTOM_RIGHT,
}

ImageId :: int
IMAGE_NIL :: ImageId(0)

Quad :: [4]Vertex
MAX_QUADS :: 524288
MAX_VERTS :: MAX_QUADS * 4
INDEX_BUFFER_COUNT :: MAX_QUADS * 6
indices: [INDEX_BUFFER_COUNT]u16

init_render :: proc() {
	fmt.println("DrawFrame size =", size_of(Draw_Frame))

	// make the vertex buffer
	app_state.bind.vertex_buffers[0] = sg.make_buffer(
		{usage = .DYNAMIC, size = size_of(Quad) * len(draw_frame.quads)},
	)

	// make & fill the index buffer
	i := 0
	for i < INDEX_BUFFER_COUNT {
		// vertex offset pattern to draw a quad
		// { 0, 1, 2,  0, 2, 3 }
		indices[i + 0] = auto_cast ((i / 6) * 4 + 0)
		indices[i + 1] = auto_cast ((i / 6) * 4 + 1)
		indices[i + 2] = auto_cast ((i / 6) * 4 + 2)
		indices[i + 3] = auto_cast ((i / 6) * 4 + 0)
		indices[i + 4] = auto_cast ((i / 6) * 4 + 2)
		indices[i + 5] = auto_cast ((i / 6) * 4 + 3)
		i += 6
	}
	app_state.bind.index_buffer = sg.make_buffer(
		{type = .INDEXBUFFER, data = {ptr = &indices, size = size_of(indices)}},
	)

	// image stuff
	app_state.bind.samplers[SMP_default_sampler] = sg.make_sampler({})

	// setup pipeline
	pipeline_desc: sg.Pipeline_Desc = {
		shader = sg.make_shader(quad_shader_desc(sg.query_backend())),
		index_type = .UINT16,
		layout = {
			attrs = {
				ATTR_quad_position = {format = .FLOAT2},
				ATTR_quad_color0 = {format = .FLOAT4},
				ATTR_quad_uv0 = {format = .FLOAT2},
				ATTR_quad_bytes0 = {format = .UBYTE4N},
				ATTR_quad_color_override0 = {format = .FLOAT4},
			},
		},
	}
	blend_state: sg.Blend_State = {
		enabled          = true,
		src_factor_rgb   = .SRC_ALPHA,
		dst_factor_rgb   = .ONE_MINUS_SRC_ALPHA,
		op_rgb           = .ADD,
		src_factor_alpha = .ONE,
		dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
		op_alpha         = .ADD,
	}
	pipeline_desc.colors[0] = {
		blend = blend_state,
	}
	app_state.pip = sg.make_pipeline(pipeline_desc)

	// default pass action
	app_state.pass_action = {
		colors = {0 = {load_action = .CLEAR, clear_value = {0.1, 0.1, 0.1, 1}}},
	}
}

DEFAULT_UV :: v4{0, 0, 1, 1}
Vector2 :: [2]f32
Vector3 :: [3]f32
Vector4 :: [4]f32
v2 :: Vector2
v3 :: Vector3
v4 :: Vector4
Matrix4 :: linalg.Matrix4f32

COLOR_RED :: Vector4{1, 0, 0, 1}
COLOR_GREEN :: Vector4{0, 1, 0, 1}
COLOR_BLUE :: Vector4{0, 0, 1, 1}
COLOR_WHITE :: Vector4{1, 1, 1, 1}
COLOR_BLACK :: Vector4{0, 0, 0, 1}

// might do something with these later on
loggie :: fmt.println // log is already used........
log_error :: fmt.println
log_warning :: fmt.println

init_time: t.Time
seconds_since_init :: proc() -> f64 {
	using t
	if init_time._nsec == 0 {
		log_error("invalid time")
		return 0
	}
	return duration_seconds(since(init_time))
}

xform_translate :: proc(pos: Vector2) -> Matrix4 {
	return linalg.matrix4_translate(v3{pos.x, pos.y, 0})
}
xform_rotate :: proc(angle: f32) -> Matrix4 {
	return linalg.matrix4_rotate(math.to_radians(angle), v3{0, 0, 1})
}
xform_scale :: proc(scale: Vector2) -> Matrix4 {
	return linalg.matrix4_scale(v3{scale.x, scale.y, 1})
}

Pivot :: enum {
	bottom_left,
	bottom_center,
	bottom_right,
	center_left,
	center_center,
	center_right,
	top_left,
	top_center,
	top_right,
}

scale_from_pivot :: proc(pivot: Pivot) -> Vector2 {
	switch pivot {
	case .bottom_left:
		return v2{0.0, 0.0}
	case .bottom_center:
		return v2{0.5, 0.0}
	case .bottom_right:
		return v2{1.0, 0.0}
	case .center_left:
		return v2{0.0, 0.5}
	case .center_center:
		return v2{0.5, 0.5}
	case .center_right:
		return v2{1.0, 0.5}
	case .top_center:
		return v2{0.5, 1.0}
	case .top_left:
		return v2{0.0, 1.0}
	case .top_right:
		return v2{1.0, 1.0}
	}
	return {}
}

sine_breathe :: proc(p: $T) -> T where intrinsics.type_is_float(T) {
	return (math.sin((p - .25) * 2.0 * math.PI) / 2.0) + 0.5
}

lerp_v2 :: proc(a, b: v2, t: f32) -> v2 {
	return a + (b - a) * t
}

to_world :: proc(screenP: v2) -> v2 {
	x := 2 * screenP.x / f32(sapp.width()) - 1
	y := 1 - 2 * screenP.y / f32(sapp.height())

	inv := draw_frame.cameraInv * draw_frame.projectionInv
	v := v4{x, y, 0, 1}
	r := inv * v

	// fmt.printfln("X=%f, Y=%F", r.x, r.y)

	return v2{r.x, r.y}
}

to_gui :: proc(screenP: v2) -> v2 {
	projectionInv := linalg.matrix_ortho3d_f32(0.0, window_w, 0.0, window_h, -1, 1)
	projectionInv = linalg.inverse(projectionInv)
	cameraInv := Matrix4(1)
	cameraInv = xform_scale(GuiScale)
	cameraInv = linalg.inverse(cameraInv)

	x := 2 * screenP.x / f32(sapp.width()) - 1
	y := 1 - 2 * screenP.y / f32(sapp.height())

	inv := cameraInv * projectionInv
	v := v4{x, y, 0, 1}
	r := inv * v

	return v2{r.x, r.y}
}

color_hex_to_float :: proc(hex: string) -> v4 {
	// Expecting 6 or 8 hex digits (RRGGBB or RRGGBBAA)
	using strconv

	if len(hex) == 0 {
		return v4{0, 0, 0, 1}
	}

	// Parse integer from hex string
	val, ok := strconv.parse_u64(hex, 16)
	if !ok {
		return v4{0, 0, 0, 1}
	}

	// Extract color channels
	r, g, b, a: f32
	if len(hex) <= 6 {
		r = f32((val >> 16) & 0xFF) / 255.0
		g = f32((val >> 8) & 0xFF) / 255.0
		b = f32(val & 0xFF) / 255.0
		a = 1.0
	} else {
		r = f32((val >> 24) & 0xFF) / 255.0
		g = f32((val >> 16) & 0xFF) / 255.0
		b = f32((val >> 8) & 0xFF) / 255.0
		a = f32(val & 0xFF) / 255.0
	}

	return v4{r, g, b, a}
}

render_frame :: proc() {
	app_state.bind.images[IMG_tex0] = atlas.sg_image
	app_state.bind.images[IMG_tex1] = images[font.img_id].sg_img

	if draw_frame.quad_count > 0 {
		sg.update_buffer(
			app_state.bind.vertex_buffers[0],
			{ptr = &draw_frame.quads[0], size = size_of(Quad) * auto_cast draw_frame.quad_count},
		)
	}
	sg.begin_pass({action = app_state.pass_action, swapchain = sglue.swapchain()})
	sg.apply_pipeline(app_state.pip)
	sg.apply_bindings(app_state.bind)
	if draw_frame.quad_count > 0 {
		sg.draw(0, 6 * draw_frame.quad_count, 1)
	}
	sg.end_pass()
	sg.commit()
}

//
// :RENDER STUFF
//
// API ordered highest -> lowest level

draw_sprite :: proc(
	pos: Vector2,
	img_id: ImageId,
	pivot := Pivot.bottom_left,
	xform := Matrix4(1),
	color_override := v4{0, 0, 0, 0},
) {
	image := images[img_id]
	size := v2{auto_cast image.width, auto_cast image.height}

	xform0 := Matrix4(1)
	xform0 *= xform_translate(pos)
	xform0 *= xform // we slide in here because rotations + scales work nicely at this point
	xform0 *= xform_translate(size * -scale_from_pivot(pivot))

	draw_rect_xform(xform0, size, img_id = img_id, color_override = color_override)
}

draw_rect_aabb :: proc(
	min: Vector2,
	max: Vector2,
	col: Vector4 = COLOR_WHITE,
	uv: Vector4 = DEFAULT_UV,
	img_id: ImageId = IMAGE_NIL,
	color_override := v4{0, 0, 0, 0},
) {
	xform := linalg.matrix4_translate(v3{min.x, min.y, 0})
	draw_rect_xform(xform, max - min, col, uv, img_id, color_override)
}

draw_rect_xform :: proc(
	xform: Matrix4,
	size: Vector2,
	col: Vector4 = COLOR_WHITE,
	uv: Vector4 = DEFAULT_UV,
	img_id: ImageId = IMAGE_NIL,
	color_override := v4{0, 0, 0, 0},
) {
	draw_rect_projected(
		draw_frame.projection * draw_frame.camera_xform * xform,
		size,
		col,
		uv,
		img_id,
		color_override,
	)
}

clear_draw_frame :: proc() {
	//runtime.memset(&draw_frame, 0, size_of(draw_frame))
	runtime.memset(&draw_frame, 0, draw_frame.quad_count)
	draw_frame.quad_count = 0
}

draw_frame: Draw_Frame

// below is the lower level draw rect stuff

draw_rect_projected :: proc(
	world_to_clip: Matrix4,
	size: Vector2,
	col: Vector4 = COLOR_WHITE,
	uv: Vector4 = DEFAULT_UV,
	img_id: ImageId = IMAGE_NIL,
	color_override := v4{0, 0, 0, 0},
) {

	bl := v2{0, 0}
	tl := v2{0, size.y}
	tr := v2{size.x, size.y}
	br := v2{size.x, 0}

	uv0 := uv
	if uv == DEFAULT_UV {
		uv0 = images[img_id].atlas_uvs
	}

	tex_index: u8 = images[img_id].tex_index
	if img_id == IMAGE_NIL {
		tex_index = 255 // bypasses texture sampling
	}

	draw_quad_projected(
		world_to_clip,
		{bl, tl, tr, br},
		{col, col, col, col},
		{uv0.xy, uv0.xw, uv0.zw, uv0.zy},
		{tex_index, tex_index, tex_index, tex_index},
		{color_override, color_override, color_override, color_override},
	)
}

draw_quad_projected :: proc(
	world_to_clip: Matrix4,
	positions: [4]Vector2,
	colors: [4]Vector4,
	uvs: [4]Vector2,
	tex_indicies: [4]u8,
	//flags:           [4]Quad_Flags,
	color_overrides: [4]Vector4,
	//hsv:             [4]Vector3
) {
	using linalg

	if draw_frame.quad_count >= MAX_QUADS {
		log_error("max quads reached")
		return
	}

	verts := cast(^[4]Vertex)&draw_frame.quads[draw_frame.quad_count]
	draw_frame.quad_count += 1

	verts[0].pos = (world_to_clip * Vector4{positions[0].x, positions[0].y, 0.0, 1.0}).xy
	verts[1].pos = (world_to_clip * Vector4{positions[1].x, positions[1].y, 0.0, 1.0}).xy
	verts[2].pos = (world_to_clip * Vector4{positions[2].x, positions[2].y, 0.0, 1.0}).xy
	verts[3].pos = (world_to_clip * Vector4{positions[3].x, positions[3].y, 0.0, 1.0}).xy

	verts[0].col = colors[0]
	verts[1].col = colors[1]
	verts[2].col = colors[2]
	verts[3].col = colors[3]

	verts[0].uv = uvs[0]
	verts[1].uv = uvs[1]
	verts[2].uv = uvs[2]
	verts[3].uv = uvs[3]

	verts[0].tex_index = tex_indicies[0]
	verts[1].tex_index = tex_indicies[1]
	verts[2].tex_index = tex_indicies[2]
	verts[3].tex_index = tex_indicies[3]

	verts[0].color_override = color_overrides[0]
	verts[1].color_override = color_overrides[1]
	verts[2].color_override = color_overrides[2]
	verts[3].color_override = color_overrides[3]
}

draw_circle :: proc(center: v2, radius: f32, color: v4) {
	draw_circle_projected(draw_frame.projection * draw_frame.camera_xform, center, radius, color)
}

draw_circle_projected :: proc(world_to_clip: Matrix4, center: v2, radius: f32, colors: v4) {
	using linalg

	SEGMENTS: int = 9
	STEP: f32 = f32(2.0 * PI) / f32(SEGMENTS)

	if draw_frame.quad_count >= MAX_QUADS {
		log_error("max quads reached")
		return
	}

	verts := cast(^[36]Vertex)&draw_frame.quads[draw_frame.quad_count]
	draw_frame.quad_count += 9

	for i := 0; i < SEGMENTS; i += 1 {
		a0 := f32(i) * STEP
		a1 := f32(i + 1) * STEP

		// Directions on the unit circle
		d0 := Vector2{cos(a0), sin(a0)}
		d1 := Vector2{cos(a1), sin(a1)}

		// Pie-slice quad (two verts at center)
		p0 := center // inner 0 (center)
		p1 := center + d0 * radius // outer edge
		p2 := center + d1 * radius // outer edge next segment
		p3 := center // inner 0 (center)

		// Write into the 4 vertices of this quad
		base := i * 4

		verts[base + 0].pos = (world_to_clip * Vector4{p0.x, p0.y, 0.0, 1.0}).xy
		verts[base + 1].pos = (world_to_clip * Vector4{p1.x, p1.y, 0.0, 1.0}).xy
		verts[base + 2].pos = (world_to_clip * Vector4{p2.x, p2.y, 0.0, 1.0}).xy
		verts[base + 3].pos = (world_to_clip * Vector4{p3.x, p3.y, 0.0, 1.0}).xy

		verts[base + 0].col = colors
		verts[base + 1].col = colors
		verts[base + 2].col = colors
		verts[base + 3].col = colors

		verts[base + 0].tex_index = 255
		verts[base + 1].tex_index = 255
		verts[base + 2].tex_index = 255
		verts[base + 3].tex_index = 255

		verts[base + 0].color_override = colors
		verts[base + 1].color_override = colors
		verts[base + 2].color_override = colors
		verts[base + 3].color_override = colors
	}
}

Image :: struct {
	width:        i32,
	height:       i32,
	paddedWidth:  i32,
	paddedHeight: i32,
	tex_index:    u8,
	sg_img:       sg.Image,
	data:         [^]byte,
	paddedData:   [^]byte,
	atlas_uvs:    Vector4,
}
images: [512]Image
image_count: int

get_pixel :: proc(data: [^]byte, w: i32, h: i32, x: i32, y: i32) -> (u8, u8, u8, u8) {
	offset: i32 = (y * w + x) * 4
	r := data[offset + 0]
	g := data[offset + 1]
	b := data[offset + 2]
	a := data[offset + 3]
	return r, g, b, a
}

pad_image :: proc(image: ^Image) {
	image.paddedWidth = image.width + 2
	image.paddedHeight = image.height + 2
	newSize := image.paddedWidth * image.paddedHeight * 4
	image.paddedData = make([^]byte, newSize)
	mem.set(image.paddedData, 0, int(newSize))

	for y: i32 = 1; y < image.paddedHeight - 1; y += 1 {
		for x: i32 = 1; x < image.paddedWidth - 1; x += 1 {
			r, g, b, a := get_pixel(image.data, image.width, image.height, x - 1, y - 1)
			image.paddedData[(y * image.paddedWidth + x) * 4 + 0] = r
			image.paddedData[(y * image.paddedWidth + x) * 4 + 1] = g
			image.paddedData[(y * image.paddedWidth + x) * 4 + 2] = b
			image.paddedData[(y * image.paddedWidth + x) * 4 + 3] = a
		}
	}
}

find_images_paths :: proc(img_dir: string) -> [dynamic]string {
	f, err1 := os.open(img_dir)
	if err1 != os.ERROR_NONE {
		fmt.eprintln("Could not open directory: %v", err1)
		os.exit(1)
	}
	defer os.close(f)

	entries, err2 := os.read_dir(f, -1)
	if err2 != nil {
		fmt.printf("Failed to read dir %s: %v\n", img_dir, err2)
		return {}
	}

	paths: [dynamic]string

	for entry in entries {
		stuff: [2]string
		stuff[0] = img_dir
		stuff[1] = entry.name
		path := filepath.join(stuff[:])
		if entry.is_dir {
			newPaths := find_images_paths(path)
			for p in newPaths {
				append(&paths, p)
			}
			delete(newPaths)
		} else {
			if filepath.ext(path) == ".png" {
				append(&paths, path)
			}
		}
	}

	return paths
}

init_images :: proc() {
	using fmt

	img_dir := "res/sprites/"

	paths := find_images_paths(img_dir)
	defer delete(paths)


	highest_id := 0
	for path, idx in paths {
		id := idx + 1 // reserve 0 as IMAGE_NIL
		if id > highest_id {
			highest_id = id
		}

		fmt.println(path)
		png_data, succ := os.read_entire_file(path)
		assert(succ)

		stbi.set_flip_vertically_on_load(1)
		width, height, channels: i32
		img_data := stbi.load_from_memory(
			raw_data(png_data),
			auto_cast len(png_data),
			&width,
			&height,
			&channels,
			4,
		)
		assert(img_data != nil, "stbi load failed, invalid image?")

		img: Image
		img.width = width
		img.height = height
		img.data = img_data

		pad_image(&img)

		images[id] = img
	}
	image_count = highest_id + 1

	pack_images_into_atlas()
}

Atlas :: struct {
	w, h:     int,
	sg_image: sg.Image,
}
atlas: Atlas

pack_images_into_atlas :: proc() {

	// 8192 x 8192 is the WGPU recommended max I think
	atlas.w = 512
	atlas.h = 512

	cont: stbrp.Context
	nodes: [512]stbrp.Node // #volatile with atlas.w
	stbrp.init_target(&cont, auto_cast atlas.w, auto_cast atlas.h, &nodes[0], auto_cast atlas.w)

	rects: [dynamic]stbrp.Rect
	for img, id in images {
		if img.width == 0 {
			continue
		}

		append(
			&rects,
			stbrp.Rect {
				id = auto_cast id,
				w = auto_cast img.paddedWidth,
				h = auto_cast img.paddedHeight,
			},
		)
	}

	succ := stbrp.pack_rects(&cont, &rects[0], auto_cast len(rects))
	if succ == 0 {
		assert(false, "failed to pack all the rects, ran out of space?")
	}

	// allocate big atlas
	raw_data, err := mem.alloc(atlas.w * atlas.h * 4)
	defer mem.free(raw_data)
	mem.set(raw_data, 255, atlas.w * atlas.h * 4)

	// copy rect row-by-row into destination atlas
	for rect in rects {
		img := &images[rect.id]

		// copy row by row into atlas
		for row in 0 ..< rect.h {
			src_row := mem.ptr_offset(&img.paddedData[0], row * rect.w * 4)
			dest_row := mem.ptr_offset(
				cast(^u8)raw_data,
				((rect.y + row) * auto_cast atlas.w + rect.x) * 4,
			)
			mem.copy(dest_row, src_row, auto_cast rect.w * 4)
		}

		// yeet old data
		stbi.image_free(img.data)
		img.data = nil

		// img.atlas_x = auto_cast rect.x
		// img.atlas_y = auto_cast rect.y

		img.atlas_uvs.x = (cast(f32)rect.x + 1) / cast(f32)atlas.w
		img.atlas_uvs.y = (cast(f32)rect.y + 1) / cast(f32)atlas.h
		img.atlas_uvs.z = img.atlas_uvs.x + cast(f32)img.width / cast(f32)atlas.w
		img.atlas_uvs.w = img.atlas_uvs.y + cast(f32)img.height / cast(f32)atlas.h
	}

	stbi.write_png(
		"atlas.png",
		auto_cast atlas.w,
		auto_cast atlas.h,
		4,
		raw_data,
		4 * auto_cast atlas.w,
	)

	// setup image for GPU
	desc: sg.Image_Desc
	desc.width = auto_cast atlas.w
	desc.height = auto_cast atlas.h
	desc.pixel_format = .RGBA8
	desc.data.subimage[0][0] = {
		ptr  = raw_data,
		size = auto_cast (atlas.w * atlas.h * 4),
	}
	atlas.sg_image = sg.make_image(desc)
	if atlas.sg_image.id == sg.INVALID_ID {
		log_error("failed to make image")
	}
}

draw_text_bounds :: proc(text: string, scale: f32) -> (v2, v2) {
	using stbtt
	x: f32 = 0
	y: f32 = 0

	minBound := v2{1e9, 1e9}
	maxBound := v2{-1e9, -1e9}

	for char in text {
		if char == '\n' {
			// Newline handling if needed
			y += f32(font.font_height) * scale
			x = 0
			continue
		}

		advance_x: f32
		advance_y: f32
		q: aligned_quad
		GetBakedQuad(
			&font.char_data[0],
			font_bitmap_w,
			font_bitmap_h,
			cast(i32)char - 32,
			&advance_x,
			&advance_y,
			&q,
			false,
		)

		size := v2{abs(q.x0 - q.x1), abs(q.y0 - q.y1)}
		bottomLeft := v2{q.x0, -q.y1}
		offset := v2{x, y} + bottomLeft

		minBound = linalg.min(minBound, offset)
		maxBound = linalg.max(maxBound, offset + size)

		x += advance_x
		y += -advance_y
	}

	return minBound, maxBound

}

draw_text_size :: proc(text: string, scale: f32) -> v2 {
	minBound, maxBound := draw_text_bounds(text, scale)
	size := (maxBound - minBound) * scale
	return size
}
//
// :FONT
//
draw_text :: proc(
	pos: v2,
	text: string,
	scale: f32 = 1.0,
	col: Vector4 = COLOR_WHITE,
	align: TextAlign = .BOTTOM_LEFT,
) {
	using stbtt
	x: f32
	y: f32

	alignOffset := v2{0, 0}
	if (align == .BOTTOM_CENTER) {
		size := draw_text_size(text, scale)
		alignOffset.x -= size.x / 2
		// draw_rect_aabb(pos + alignOffset, pos + alignOffset + size, col = v4{0, 1, 1, 0.5})
	} else if (align == .BOTTOM_RIGHT) {
		size := draw_text_size(text, scale)
		alignOffset.x -= size.x
	}


	for char in text {
		advance_x: f32
		advance_y: f32
		q: aligned_quad
		GetBakedQuad(
			&font.char_data[0],
			font_bitmap_w,
			font_bitmap_h,
			cast(i32)char - 32,
			&advance_x,
			&advance_y,
			&q,
			false,
		)

		// this is the the data for the aligned_quad we're given, with y+ going down
		// x0, y0,     s0, t0, // top-left
		// x1, y1,     s1, t1, // bottom-right
		size := v2{abs(q.x0 - q.x1), abs(q.y0 - q.y1)}

		bottom_left := v2{q.x0, -q.y1}
		top_right := v2{q.x1, -q.y0}
		assert(bottom_left + size == top_right)

		offset_to_render_at := v2{x, y} + bottom_left

		uv := v4{q.s0, q.t1, q.s1, q.t0}

		xform := Matrix4(1)
		xform *= xform_translate(pos + alignOffset)
		xform *= xform_scale(v2{auto_cast scale, auto_cast scale})
		xform *= xform_translate(offset_to_render_at)
		draw_rect_xform(xform, size, uv = uv, img_id = font.img_id, col = col)

		x += advance_x
		y += -advance_y
	}
}

font_bitmap_w :: 256
font_bitmap_h :: 256
char_count :: 96
Font :: struct {
	char_data:   [char_count]stbtt.bakedchar,
	img_id:      ImageId,
	font_height: i32,
}
font: Font

init_fonts :: proc() {
	using stbtt

	bitmap, _ := mem.alloc(font_bitmap_w * font_bitmap_h)
	font_height := 14 // for some reason this only bakes properly at 15 ? it's a 16px font dou...
	path := "res/fonts/m6x11.ttf"
	ttf_data, err := os.read_entire_file(path)
	assert(ttf_data != nil, "failed to read font")

	ret := BakeFontBitmap(
		raw_data(ttf_data),
		0,
		auto_cast font_height,
		auto_cast bitmap,
		font_bitmap_w,
		font_bitmap_h,
		32,
		char_count,
		&font.char_data[0],
	)
	assert(ret > 0, "not enough space in bitmap")

	stbi.write_png(
		"font.png",
		auto_cast font_bitmap_w,
		auto_cast font_bitmap_h,
		1,
		bitmap,
		auto_cast font_bitmap_w,
	)

	// setup font atlas so we can use it in the shader
	desc: sg.Image_Desc
	desc.width = auto_cast font_bitmap_w
	desc.height = auto_cast font_bitmap_h
	desc.pixel_format = .R8
	desc.data.subimage[0][0] = {
		ptr  = bitmap,
		size = auto_cast (font_bitmap_w * font_bitmap_h),
	}
	sg_img := sg.make_image(desc)
	if sg_img.id == sg.INVALID_ID {
		log_error("failed to make image")
	}

	id := store_image(font_bitmap_w, font_bitmap_h, 1, sg_img)
	font.img_id = id
	font.font_height = auto_cast font_height
}
// kind scuffed...
// but I'm abusing the Images to store the font atlas by just inserting it at the end with the next id
store_image :: proc(w: int, h: int, tex_index: u8, sg_img: sg.Image) -> ImageId {

	img: Image
	img.width = auto_cast w
	img.height = auto_cast h
	img.tex_index = tex_index
	img.sg_img = sg_img
	img.atlas_uvs = DEFAULT_UV

	id := image_count
	images[id] = img
	image_count += 1

	return ImageId(id)
}
