// Host glue for the wasm build. Implements the foreign imports declared in
// client/web/main.odin, drives the frame loop via requestAnimationFrame, and
// forwards browser input into the wasm module.

const canvas = document.getElementById('screen');
const ctx    = canvas.getContext('2d');
const status = document.getElementById('status');

// --- Background shader (WebGL2) --------------------------------------------
//
// The win32/Vulkan host renders a full-screen procedural background via
// shaders/background.{vert,frag}: dark-teal lit base + fog-of-war disks
// around world-space "lights" pushed by the game each frame. Canvas 2D can't
// run that, so we stack a WebGL2 canvas underneath the 2D canvas and port
// the same shader to GLSL ES 3.00. Layering (bg below, shapes/text above) is
// done by CSS in index.html — both canvases share identical pixel sizes so
// fragment coords map 1:1.
//
// Hard cap matches MAX_FOG_LIGHTS in shaders/background.frag and the win32
// Background_Renderer. 256 vec2s is small enough to pass as a plain uniform
// array — no UBO ceremony needed in WebGL2.

const bgCanvas = document.getElementById('bg');
const gl       = bgCanvas.getContext('webgl2', { antialias: false, premultipliedAlpha: false });

const MAX_FOG_LIGHTS  = 256;
const FOG_LIGHT_RADIUS  = 220.0;   // mirrors win32/background.odin
const FOG_LIGHT_FALLOFF = 480.0;

// CPU-side per-frame light list. The game clears at the top of its update
// (before any set_camera) and pushes one entry per visible building/tile.
const fogLights = new Float32Array(MAX_FOG_LIGHTS * 2);
let fogLightCount = 0;

// Background camera: latched separately from the 2D `cam` because the win32
// gfx_clear_view resets only the shape view, leaving the background sticky on
// the most recent set_camera. We mirror that: js_set_camera updates bgCam,
// js_clear_camera does not touch it, and each frame resets it to identity
// before web_frame so a frame that never sets a camera renders bg in screen
// space (matching gfx_begin in win32).
let bgCam = { sx: 1, sy: 1, ox: 0, oy: 0 };

let bgProgram = null;
let bgVAO     = null;
let bgUniforms = {};

function initBackgroundGL() {
	if (!gl) {
		console.warn('WebGL2 unavailable — background shader disabled, falling back to flat fill.');
		return false;
	}

	// Fullscreen triangle. Mirrors shaders/background.vert, but in GL ES the
	// y axis already points up so we flip the synthesised position to match
	// Vulkan's top-left origin convention used by the rest of the game.
	const vertSrc = `#version 300 es
precision highp float;
void main() {
	vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
	// Flip y so gl_FragCoord (origin bottom-left in GL) reads the same as the
	// Vulkan build's top-left origin once we do screen.y - gl_FragCoord.y in
	// the fragment shader.
	gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`;

	// Direct port of shaders/background.frag. Differences:
	//   - push_constant block + UBO -> plain uniforms / uniform array
	//   - flip y so the world-space math matches the y-down game coordinates
	const fragSrc = `#version 300 es
precision highp float;
out vec4 out_color;

#define MAX_FOG_LIGHTS ${MAX_FOG_LIGHTS}

uniform vec2  u_screen;
uniform vec2  u_view_scale;
uniform vec2  u_view_offset;
uniform float u_time;
uniform int   u_light_count;
uniform float u_light_radius;
uniform float u_light_falloff;
uniform vec2  u_lights[MAX_FOG_LIGHTS];

void main() {
	// gl_FragCoord origin is bottom-left in WebGL; flip to top-left so the
	// camera affine (which maps world->screen with y growing downward) lines
	// up with the 2D canvas above us.
	vec2 frag = vec2(gl_FragCoord.x, u_screen.y - gl_FragCoord.y);
	vec2 uv   = frag / u_screen;
	float t   = u_time;

	vec3 lit  = vec3(0.045, 0.115, 0.135);
	lit += vec3(0.0, 0.006, 0.010) *
	       (0.5 + 0.5 * sin(t * 0.18 + uv.y * 2.6 + uv.x * 1.3));
	vec3 dark = vec3(0.003, 0.008, 0.012);

	vec2 world = (frag - u_view_offset) / u_view_scale;

	float min_d = 1e9;
	int n = u_light_count;
	if (n > MAX_FOG_LIGHTS) n = MAX_FOG_LIGHTS;
	for (int i = 0; i < MAX_FOG_LIGHTS; ++i) {
		if (i >= n) break; // GLSL ES needs a constant loop bound
		float d = distance(world, u_lights[i]);
		if (d < min_d) min_d = d;
	}

	float r0 = u_light_radius;
	float r1 = r0 + max(u_light_falloff, 1.0);
	float fade = (n == 0) ? 1.0 : smoothstep(r0, r1, min_d);

	vec3 col = mix(lit, dark, fade);
	out_color = vec4(col, 1.0);
}`;

	function compile(type, src) {
		const sh = gl.createShader(type);
		gl.shaderSource(sh, src);
		gl.compileShader(sh);
		if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
			console.error('background shader compile error:', gl.getShaderInfoLog(sh), src);
			gl.deleteShader(sh);
			return null;
		}
		return sh;
	}

	const vs = compile(gl.VERTEX_SHADER,   vertSrc);
	const fs = compile(gl.FRAGMENT_SHADER, fragSrc);
	if (!vs || !fs) return false;

	bgProgram = gl.createProgram();
	gl.attachShader(bgProgram, vs);
	gl.attachShader(bgProgram, fs);
	gl.linkProgram(bgProgram);
	if (!gl.getProgramParameter(bgProgram, gl.LINK_STATUS)) {
		console.error('background program link error:', gl.getProgramInfoLog(bgProgram));
		return false;
	}

	bgUniforms = {
		screen:       gl.getUniformLocation(bgProgram, 'u_screen'),
		view_scale:   gl.getUniformLocation(bgProgram, 'u_view_scale'),
		view_offset:  gl.getUniformLocation(bgProgram, 'u_view_offset'),
		time:         gl.getUniformLocation(bgProgram, 'u_time'),
		light_count:  gl.getUniformLocation(bgProgram, 'u_light_count'),
		light_radius: gl.getUniformLocation(bgProgram, 'u_light_radius'),
		light_falloff:gl.getUniformLocation(bgProgram, 'u_light_falloff'),
		lights:       gl.getUniformLocation(bgProgram, 'u_lights[0]'),
	};

	// Empty VAO; the vertex shader synthesises positions from gl_VertexID, so
	// we just need *a* VAO bound when issuing the draw.
	bgVAO = gl.createVertexArray();

	gl.disable(gl.BLEND);
	gl.disable(gl.DEPTH_TEST);
	gl.disable(gl.CULL_FACE);
	return true;
}

function renderBackground(timeSec) {
	if (!bgProgram) {
		// Fallback: solid clear so the canvas isn't transparent over the
		// page background.
		if (gl) {
			gl.clearColor(0.012, 0.012, 0.039, 1.0);
			gl.clear(gl.COLOR_BUFFER_BIT);
		}
		return;
	}

	gl.viewport(0, 0, bgCanvas.width, bgCanvas.height);
	gl.useProgram(bgProgram);
	gl.bindVertexArray(bgVAO);

	gl.uniform2f(bgUniforms.screen,      bgCanvas.width, bgCanvas.height);
	gl.uniform2f(bgUniforms.view_scale,  bgCam.sx, bgCam.sy);
	gl.uniform2f(bgUniforms.view_offset, bgCam.ox, bgCam.oy);
	gl.uniform1f(bgUniforms.time,         timeSec);
	gl.uniform1i(bgUniforms.light_count,  fogLightCount);
	gl.uniform1f(bgUniforms.light_radius, FOG_LIGHT_RADIUS);
	gl.uniform1f(bgUniforms.light_falloff,FOG_LIGHT_FALLOFF);
	if (bgUniforms.lights && fogLightCount > 0) {
		// uniform2fv accepts the full array — extra trailing slots are unused.
		gl.uniform2fv(bgUniforms.lights, fogLights);
	}

	gl.drawArrays(gl.TRIANGLES, 0, 3);
}

// --- Audio ------------------------------------------------------------------
//
// One <audio>-style buffer pool per family. Indices match the `Sound` enum in
// client/game/platform.odin: 0=None, 1=Hover, 2=Click, 3=Place, 4=Explode,
// 5=Turret, 6=Enemy_Attack, 7=Enemy_Die. We keep N pre-loaded HTMLAudioElements
// per family and round-robin through them so overlapping plays each get their
// own playback head — a single Audio element can't play to itself in parallel.
//
// Files are served relative to host.js. `build_web.bat` mirrors `res/` into
// the web build dir so the dev server (rooted at build/web/) can find them.

const SOUND_FILES = [
	[],                                                          // None
	['res/sounds/button-hover.wav'],                       // Button_Hover
	['res/sounds/button-click.wav'],                       // Button_Click
	['res/sounds/place_building_1.wav',
	 'res/sounds/place_building_2.wav'],                   // Place_Building
	['res/sounds/building-explode.wav'],                   // Building_Explode
	['res/sounds/turret_shoot-01.wav',
	 'res/sounds/turret_shoot-02.wav',
	 'res/sounds/turret_shoot-03.wav'],                    // Turret_Shoot
	['res/sounds/enemy-attack-01.wav',
	 'res/sounds/enemy-attack-02.wav',
	 'res/sounds/enemy-attack-03.wav',
	 'res/sounds/enemy-attack-04.wav',
	 'res/sounds/enemy-attack-05.wav'],                    // Enemy_Attack
	['res/sounds/enemy-die-01.wav',
	 'res/sounds/enemy-die-02.wav',
	 'res/sounds/enemy-die-03.wav'],                       // Enemy_Die
];

const POOL_PER_VARIANT = 4; // headroom for overlapping plays of the same wav
let masterVolume = 1.0;

// Per-family minimum gap between consecutive plays. Mirrors the win32 host's
// table; together with the per-frame coalescer in the game, it stops a synced
// salvo (18 turrets on one tick) and rapid cross-frame repeats from stacking.
// Indices match the Sound enum: 0=None, 1=Hover, 2=Click, 3=Place, 4=Explode,
// 5=Turret, 6=Enemy_Attack, 7=Enemy_Die.
const SOUND_MIN_INTERVAL_MS = [0, 50, 0, 0, 60, 60, 80, 60];
const lastPlayedMs = new Array(SOUND_MIN_INTERVAL_MS.length).fill(-Infinity);

const soundPool = SOUND_FILES.map(variants =>
	variants.map(src => {
		const pool = [];
		for (let i = 0; i < POOL_PER_VARIANT; i++) {
			const a = new Audio(new URL(src, import.meta.url).href);
			a.preload = 'auto';
			pool.push(a);
		}
		return { pool, cursor: 0 };
	})
);

function playSound(soundIdx) {
	const variants = soundPool[soundIdx];
	if (!variants || variants.length === 0) return;

	const minIv = SOUND_MIN_INTERVAL_MS[soundIdx] || 0;
	const now = performance.now();
	if (minIv > 0 && now - lastPlayedMs[soundIdx] < minIv) return;
	lastPlayedMs[soundIdx] = now;

	const v = variants[(Math.random() * variants.length) | 0];
	const a = v.pool[v.cursor];
	v.cursor = (v.cursor + 1) % v.pool.length;
	try {
		a.volume = masterVolume;
		a.currentTime = 0;
		// Browsers reject autoplay until the user has interacted. Ignore the
		// rejection — once the player clicks or presses a key, subsequent
		// plays will succeed.
		a.play().catch(() => {});
	} catch {}
}

// Camera: we apply the (scale, offset) manually inside each draw call so the
// canvas's save/restore stack stays free for scissor clipping.
let cam = { sx: 1, sy: 1, ox: 0, oy: 0 };

let memory; // exports.memory once we've instantiated.
const decoder = new TextDecoder();

function decodeString(ptr, len) {
	if (len === 0) return '';
	return decoder.decode(new Uint8Array(memory.buffer, ptr, len));
}

function rgba(r, g, b, a) {
	const R = Math.max(0, Math.min(255, (r * 255) | 0));
	const G = Math.max(0, Math.min(255, (g * 255) | 0));
	const B = Math.max(0, Math.min(255, (b * 255) | 0));
	return `rgba(${R},${G},${B},${a})`;
}

function fontStr(font) {
	return font === 1 ? '32px monospace' : '16px monospace';
}

const host = {
	js_draw_rect: (x, y, w, h, r, g, b, a) => {
		ctx.fillStyle = rgba(r, g, b, a);
		ctx.fillRect(x * cam.sx + cam.ox, y * cam.sy + cam.oy, w * cam.sx, h * cam.sy);
	},
	js_draw_circle: (cx, cy, rad, r, g, b, a) => {
		ctx.fillStyle = rgba(r, g, b, a);
		ctx.beginPath();
		ctx.arc(cx * cam.sx + cam.ox, cy * cam.sy + cam.oy, rad * cam.sx, 0, Math.PI * 2);
		ctx.fill();
	},
	js_draw_line: (ax, ay, bx, by, t, r, g, b, a) => {
		ctx.strokeStyle = rgba(r, g, b, a);
		ctx.lineWidth   = Math.max(0.5, t * cam.sx);
		ctx.beginPath();
		ctx.moveTo(ax * cam.sx + cam.ox, ay * cam.sy + cam.oy);
		ctx.lineTo(bx * cam.sx + cam.ox, by * cam.sy + cam.oy);
		ctx.stroke();
	},
	js_draw_text: (x, y, ptr, len, r, g, b, a, font) => {
		// Text is always issued in screen-space by the game (after
		// clear_camera()), so we ignore `cam` here.
		ctx.fillStyle = rgba(r, g, b, a);
		ctx.font      = fontStr(font);
		ctx.textBaseline = 'alphabetic';
		ctx.fillText(decodeString(ptr, len), x, y);
	},
	js_text_measure: (ptr, len, font) => {
		ctx.font = fontStr(font);
		return ctx.measureText(decodeString(ptr, len)).width;
	},
	js_set_camera:   (sx, sy, ox, oy) => {
		cam   = { sx, sy, ox, oy };
		// Background latches the latest world-space camera so its lights pan
		// with the scene; clear_camera only resets `cam` (matches gfx_clear_view
		// in win32, which leaves bg_view sticky).
		bgCam = { sx, sy, ox, oy };
	},
	js_clear_camera: ()               => { cam = { sx: 1, sy: 1, ox: 0, oy: 0 }; },
	js_fog_lights_clear: () => { fogLightCount = 0; },
	js_fog_lights_push:  (x, y) => {
		if (fogLightCount >= MAX_FOG_LIGHTS) return;
		fogLights[fogLightCount * 2 + 0] = x;
		fogLights[fogLightCount * 2 + 1] = y;
		fogLightCount++;
	},
	js_push_scissor: (x, y, w, h) => {
		ctx.save();
		ctx.beginPath();
		ctx.rect(x, y, w, h);
		ctx.clip();
	},
	js_pop_scissor:       () => { ctx.restore(); },
	js_toggle_fullscreen: () => {
		if (!document.fullscreenElement) canvas.requestFullscreen?.();
		else document.exitFullscreen?.();
	},
	js_request_quit: () => { window.close(); },
	js_play_sound:        (sound) => { playSound(sound); },
	js_set_master_volume: (v)     => { masterVolume = Math.max(0, Math.min(1, v)); },
};

// --- Input mapping. Indices must match the Key enum in client/game/platform.odin.
// 0=Unknown, then W,A,S,D, C,B,R,V, Num1..Num6, Escape, Enter, Space,
// Left_Shift, Right_Shift, F6. If you reorder the Odin enum, update this table.
const KEY = {
	KeyW: 1, KeyA: 2, KeyS: 3, KeyD: 4,
	KeyC: 5, KeyB: 6, KeyR: 7, KeyV: 8,
	Digit1: 9, Digit2: 10, Digit3: 11, Digit4: 12, Digit5: 13, Digit6: 14,
	Escape: 15, Enter: 16, Space: 17,
	ShiftLeft: 18, ShiftRight: 19,
	F6: 20,
};

// Odin's `js_wasm32` runtime links the C99 libm trig/exp/log/round helpers as
// host imports (wasm32 has no native opcodes for them). Forward each to its
// JS Math equivalent. Keep `f` and non-`f` variants — Odin emits whichever
// matches the operand width.
const M = Math;
const libm = {
	sin:   M.sin,    sinf:  M.sin,
	cos:   M.cos,    cosf:  M.cos,
	tan:   M.tan,    tanf:  M.tan,
	asin:  M.asin,   asinf: M.asin,
	acos:  M.acos,   acosf: M.acos,
	atan:  M.atan,   atanf: M.atan,
	atan2: M.atan2,  atan2f: M.atan2,
	sinh:  M.sinh,   sinhf: M.sinh,
	cosh:  M.cosh,   coshf: M.cosh,
	tanh:  M.tanh,   tanhf: M.tanh,
	exp:   M.exp,    expf:  M.exp,
	exp2:  (x) => M.pow(2, x), exp2f: (x) => M.pow(2, x),
	log:   M.log,    logf:  M.log,
	log2:  M.log2,   log2f: M.log2,
	log10: M.log10,  log10f: M.log10,
	pow:   M.pow,    powf:  M.pow,
	cbrt:  M.cbrt,   cbrtf: M.cbrt,
	fmod:  (a, b) => a - M.trunc(a / b) * b,
	fmodf: (a, b) => a - M.trunc(a / b) * b,
	round: M.round,  roundf: M.round,
	trunc: M.trunc,  truncf: M.trunc,
	ldexp: (x, e) => x * M.pow(2, e),
	ldexpf: (x, e) => x * M.pow(2, e),
};

// Forward Odin's stdio writes to the JS console. The runtime calls this for
// fmt.eprintln, panic messages, and the like.
let stdoutBuf = '', stderrBuf = '';
function writeFd(fd, ptr, len) {
	if (len === 0) return 0;
	const text = decodeString(ptr, len);
	const flush = (buf, line) => {
		buf += line;
		const idx = buf.lastIndexOf('\n');
		if (idx >= 0) {
			(fd === 2 ? console.error : console.log)(buf.slice(0, idx));
			buf = buf.slice(idx + 1);
		}
		return buf;
	};
	if (fd === 2) stderrBuf = flush(stderrBuf, text);
	else          stdoutBuf = flush(stdoutBuf, text);
	return len;
}
libm.write = writeFd;

// Anything else the runtime asks for: warn once and return 0 so it's easy to
// spot in the console without spamming.
const seenStubs = new Set();
const odin_env = new Proxy(libm, {
	get: (target, name) => {
		if (name in target) return target[name];
		if (typeof name === 'string' && !seenStubs.has(name)) {
			seenStubs.add(name);
			console.warn('odin_env stub (returning 0):', name);
		}
		return () => 0;
	},
});

const imports = { host, odin_env, env: odin_env };

let mouseX = 0, mouseY = 0, mouseLeft = 0, mouseRight = 0, scrollDy = 0;

canvas.addEventListener('mousemove', (e) => {
	const r = canvas.getBoundingClientRect();
	mouseX = (e.clientX - r.left) * (canvas.width  / r.width);
	mouseY = (e.clientY - r.top)  * (canvas.height / r.height);
});
canvas.addEventListener('mousedown', (e) => {
	canvas.focus();
	if (e.button === 0) mouseLeft  = 1;
	if (e.button === 2) mouseRight = 1;
});
canvas.addEventListener('mouseup', (e) => {
	if (e.button === 0) mouseLeft  = 0;
	if (e.button === 2) mouseRight = 0;
});
canvas.addEventListener('contextmenu', (e) => e.preventDefault());
canvas.addEventListener('wheel', (e) => {
	scrollDy += -Math.sign(e.deltaY);
	e.preventDefault();
}, { passive: false });

const PREVENT_DEFAULT = new Set(['Tab', 'Space', ...Object.keys(KEY)]);

window.addEventListener('keydown', (e) => {
	const k = KEY[e.code];
	if (k !== undefined) exports.web_key(k, 1);
	if (PREVENT_DEFAULT.has(e.code)) e.preventDefault();
});
window.addEventListener('keyup', (e) => {
	const k = KEY[e.code];
	if (k !== undefined) exports.web_key(k, 0);
});

let exports;

(async function () {
	try {
		const url = new URL('client.wasm', import.meta.url);
		const result = await WebAssembly.instantiateStreaming(fetch(url), imports);
		exports = result.instance.exports;
		memory  = exports.memory;
		initBackgroundGL();
		exports.web_init();
		status.remove();
		canvas.focus();

		const start = performance.now();
		let last = start;
		function frame(now) {
			const dt    = (now - last) / 1000;
			const time  = (now - start) / 1000;
			last = now;
			const dy = scrollDy; scrollDy = 0;

			// Clear the 2D canvas to transparent so the WebGL background
			// canvas underneath is visible. clearRect is the cheap way to
			// drop everything from the previous frame without painting a
			// fill on top.
			ctx.setTransform(1, 0, 0, 1, 0, 0);
			ctx.clearRect(0, 0, canvas.width, canvas.height);

			// Reset the latched background camera each frame to match
			// gfx_begin's `bg_view = identity`. The game's set_camera call
			// during web_frame will overwrite this to whatever world-space
			// affine is active when fog lights are pushed.
			bgCam = { sx: 1, sy: 1, ox: 0, oy: 0 };

			exports.web_frame(dt, time, canvas.width, canvas.height, mouseX, mouseY, dy, mouseLeft, mouseRight);

			// Render bg after web_frame so we use the fog lights and camera
			// the game just pushed. Layering is by canvas stacking, not by
			// draw order, so doing this last is safe.
			renderBackground(time);

			requestAnimationFrame(frame);
		}
		requestAnimationFrame(frame);
	} catch (err) {
		status.textContent = 'failed to load: ' + err.message;
		console.error(err);
	}
})();
