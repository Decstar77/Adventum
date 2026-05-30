package game

import "../common"

// game2 — a fresh pixel-art game. For now it just proves the platform seam and
// the new texture path end to end: load a sprite at init and draw it centred,
// scaled up with nearest-neighbour filtering so the pixels stay sharp.

Game :: struct {
	pistol: common.Texture,
}

game_init :: proc(g: ^Game, p: ^common.Platform) {
	// Paths are relative to the game's res/ folder; each host prefixes its own
	// asset root (win32: client/game2/res, web: res/ served by the dev server).
	g.pistol = p->load_texture("Guns/Pistols/Outlined/1Pistol01.png")
}

game_shutdown :: proc(g: ^Game) {}

game_update_and_render :: proc(g: ^Game, p: ^common.Platform) {
	p.master_volume   = 1
	p.gameplay_active = true

	size := p->texture_size(g.pistol)
	// The web host decodes textures asynchronously, so size reads {0,0} until
	// the image is ready — fall back to a sensible square until it lands.
	if size.x <= 0 || size.y <= 0 {
		size = {16, 16}
	}

	scale: f32 = 2
	w := size.x * scale
	h := size.y * scale
	x := p.screen_w * 0.5 - w * 0.5
	y := p.screen_h * 0.5 - h * 0.5
	p->draw_texture(g.pistol, x, y, w, h, {1, 1, 1, 1})

	p->draw_text(20, 36, "game2", {1, 1, 1, 1}, .Large)
}
