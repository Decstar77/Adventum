// Host glue for the wasm build. Implements the foreign imports declared in
// client/web/main.odin, drives the frame loop via requestAnimationFrame, and
// forwards browser input into the wasm module.

const canvas = document.getElementById('screen');
const ctx    = canvas.getContext('2d');

// Splash + progress bar. The progress fill is driven by a streaming wasm
// fetch below (Content-Length permitting); the text underneath swaps to a
// short status message ("loading…", "running…", or an error).
const splashEl   = document.getElementById('splash');
const splashFill = document.getElementById('splash-fill');
const splashText = document.getElementById('splash-text');
function setProgress(frac) {
	if (!splashFill) return;
	const pct = Math.max(0, Math.min(1, frac)) * 100;
	splashFill.style.width = pct.toFixed(1) + '%';
}
function setStatus(msg) {
	if (splashText) splashText.textContent = msg;
}
function hideSplash() {
	if (!splashEl) return;
	splashEl.classList.add('fade');
	// Remove from layout after the CSS transition so it doesn't eat clicks.
	setTimeout(() => splashEl.remove(), 400);
}

// --- CrazyGames SDK ---------------------------------------------------------
// Available when this build is loaded in the CrazyGames iframe; falls back to
// undefined when served from a plain dev server. Every SDK call below is
// gated on `CG` so the local build keeps working unchanged.
const CG = (typeof window !== 'undefined' && window.CrazyGames) ? window.CrazyGames.SDK : null;
let cgReady = false;
async function initCrazyGames() {
	if (!CG) return;
	try {
		await CG.init();
		cgReady = true;
	} catch (err) {
		console.warn('CrazyGames SDK init failed:', err);
	}
}

// CrazyGames lifecycle: gameplayStart/Stop are mandatory for ad approval
// (they tell the SDK when the player is actively playing vs. on a menu). We
// edge-detect on the boolean the wasm pushes each frame.
let gameplayActive = false;
function setGameplayActive(active) {
	active = !!active;
	if (active === gameplayActive) return;
	gameplayActive = active;
	if (!cgReady || !CG.game) return;
	try {
		if (active) CG.game.gameplayStart();
		else        CG.game.gameplayStop();
	} catch (err) { console.warn('CG gameplay state:', err); }
}

// --- Persistence ------------------------------------------------------------
// Prefer the CrazyGames user-scoped data API (cloud-synced when the player is
// logged in); fall back to localStorage so the local build still persists
// volume + best time. Values are stored as strings.
const STORAGE_PREFIX = 'adventum:';
function storageGet(key) {
	const fullKey = STORAGE_PREFIX + key;
	if (cgReady && CG.data && typeof CG.data.getItem === 'function') {
		try {
			const v = CG.data.getItem(fullKey);
			if (v !== null && v !== undefined) return v;
		} catch {}
	}
	try { return localStorage.getItem(fullKey); } catch { return null; }
}
function storageSet(key, value) {
	const fullKey = STORAGE_PREFIX + key;
	if (cgReady && CG.data && typeof CG.data.setItem === 'function') {
		try { CG.data.setItem(fullKey, value); } catch {}
	}
	try { localStorage.setItem(fullKey, value); } catch {}
}

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
// All sound files are streamed and decoded into AudioBuffers during the
// loading-screen phase, so by the time the game starts every play is just a
// `createBufferSource → start`. Non-spatial and spatial paths both go through
// the same AudioContext + master gain. Indices match the `Sound` enum in
// client/game/platform.odin (None=0 … Flak_Cannon_Loop=12).
//
// Files are served relative to host.js. `build_web.bat` mirrors `res/` into
// the web build dir so the dev server (rooted at build/web/) can find them.

const SOUND_FILES = [
	[],                                                          // None
	['res/sounds/button-hover.ogg'],                       // Button_Hover
	['res/sounds/button-click.ogg'],                       // Button_Click
	['res/sounds/place_building_1.ogg',
	 'res/sounds/place_building_2.ogg'],                   // Place_Building
	['res/sounds/building-explode.ogg'],                   // Building_Explode
	['res/sounds/blue_laser_1.ogg',
	 'res/sounds/blue_laser_2.ogg',
	 'res/sounds/blue_laser_3.ogg'],                    // Turret_Shoot
	['res/sounds/enemy-attack-01.ogg',
	 'res/sounds/enemy-attack-02.ogg',
	 'res/sounds/enemy-attack-03.ogg',
	 'res/sounds/enemy-attack-04.ogg',
	 'res/sounds/enemy-attack-05.ogg'],                    // Enemy_Attack
	['res/sounds/enemy-die-01.ogg',
	 'res/sounds/enemy-die-02.ogg',
	 'res/sounds/enemy-die-03.ogg'],                       // Enemy_Die
	['res/sounds/emp-sound.ogg'],                          // Emp
	['res/sounds/sell-sound.ogg'],                         // Sell
	['res/sounds/repair-sound.ogg'],                       // Repair
	['res/sounds/ugrade-sound.ogg'],                       // Upgrade
	['res/sounds/flack_cannon.ogg'],                       // Flak_Cannon_Loop
];

let masterVolume = 1.0;

// Per-family gain multiplier. Mirrors win32 `SOUND_GAIN` so source-mix
// differences are evened out the same way in both backends.
const SOUND_GAIN = [1.0, 0.3, 0.3, 3.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0];

// Per-family minimum gap between consecutive plays. Mirrors the win32 host's
// table; together with the per-frame coalescer in the game, it stops a synced
// salvo (18 turrets on one tick) and rapid cross-frame repeats from stacking.
const SOUND_MIN_INTERVAL_MS = [0, 50, 0, 0, 120, 110, 140, 110, 0, 0, 0, 0, 0];
const lastPlayedMs = new Array(SOUND_MIN_INTERVAL_MS.length).fill(-Infinity);

// Max concurrent positional voices per family. Spatial plays that exceed the
// cap are dropped; non-positional plays don't count toward this.
const SOUND_MAX_VOICES = [0, 0, 0, 2, 2, 3, 2, 2, 0, 0, 0, 0, 0];
const activeVoiceCount = new Array(SOUND_MAX_VOICES.length).fill(0);

// Decoded buffers, same shape as SOUND_FILES (one AudioBuffer per variant).
// Populated synchronously after `preloadAudio` resolves; null slots mean
// "decode failed", which the play paths treat as silent drops.
const audioBuffers = SOUND_FILES.map(v => v.map(_ => null));

// --- Spatial audio (Web Audio API) ------------------------------------------
//
// Listener tracks the game's camera (set by `js_set_listener`). Pan + distance
// attenuation map closely to the win32 backend: 1 hex pitch (~72 px) per audio
// unit, linear rolloff inside [1, 14] units.

const AUDIO_PIXELS_PER_UNIT = 72;
const AUDIO_REF_DISTANCE    = 1;
const AUDIO_MAX_DISTANCE    = 14;
const AUDIO_ROLLOFF         = 1.0;

let audioCtx        = null;
let audioMasterGain = null;
let listenerPx      = { x: 0, y: 0 };

// Create the AudioContext eagerly so `decodeAudioData` is available during
// preload. Browsers create it in `suspended` state without a user gesture and
// log a warning; we call `resume()` on the first input event (see the
// mousedown / keydown handlers below). Decode works regardless of state.
function initAudioContext() {
	if (audioCtx) return audioCtx;
	const Ctx = window.AudioContext || window.webkitAudioContext;
	if (!Ctx) return null;
	audioCtx = new Ctx();
	audioMasterGain = audioCtx.createGain();
	audioMasterGain.gain.value = masterVolume;
	audioMasterGain.connect(audioCtx.destination);
	applyListener();
	return audioCtx;
}

function resumeAudio() {
	if (audioCtx && audioCtx.state === 'suspended') {
		audioCtx.resume().catch(() => {});
	}
	// Music playback also needs a user gesture before HTMLAudioElement.play()
	// will succeed; retry any element that was rejected earlier.
	if (music.needsStart) {
		music.needsStart = false;
		musicResume();
	}
}

// Streams every sound file and decodes it into `audioBuffers`. `report(url,
// total, received)` is called as bytes arrive so the splash progress bar can
// account for these as well as the wasm. Resolves once every variant has
// either decoded successfully or failed (failures are non-fatal — the slot
// stays null and plays of that variant drop silently).
async function preloadAudio(report) {
	const ctx = initAudioContext();
	if (!ctx) return;

	const tasks = [];
	for (let si = 0; si < SOUND_FILES.length; si++) {
		const variants = SOUND_FILES[si];
		for (let vi = 0; vi < variants.length; vi++) {
			const url = new URL(variants[vi], import.meta.url).href;
			tasks.push((async () => {
				try {
					const bytes = await fetchWithProgress(url, report);
					// decodeAudioData detaches the input ArrayBuffer on some
					// engines, so slice into a fresh one we own.
					const ab = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
					const buf = await new Promise((resolve, reject) => {
						// Both promise- and callback-style overloads exist;
						// the callback form works in every browser we care
						// about including older Safari.
						ctx.decodeAudioData(ab, resolve, reject);
					});
					audioBuffers[si][vi] = buf;
				} catch (err) {
					console.warn('audio preload failed:', url, err);
				}
			})());
		}
	}
	await Promise.all(tasks);
}

function playSound(soundIdx) {
	const variants = SOUND_FILES[soundIdx];
	if (!variants || variants.length === 0 || !audioCtx) return;
	resumeAudio();

	const minIv = SOUND_MIN_INTERVAL_MS[soundIdx] || 0;
	const now = performance.now();
	if (minIv > 0 && now - lastPlayedMs[soundIdx] < minIv) return;
	lastPlayedMs[soundIdx] = now;

	const variantIdx = (Math.random() * variants.length) | 0;
	const buf = audioBuffers[soundIdx][variantIdx];
	if (!buf) return;

	const src = audioCtx.createBufferSource();
	src.buffer = buf;
	const gain = audioCtx.createGain();
	gain.gain.value = Math.min(1, SOUND_GAIN[soundIdx] ?? 1);
	src.connect(gain).connect(audioMasterGain);
	src.start();
}

function applyListener() {
	if (!audioCtx) return;
	const x = listenerPx.x / AUDIO_PIXELS_PER_UNIT;
	const z = listenerPx.y / AUDIO_PIXELS_PER_UNIT;
	const L = audioCtx.listener;
	// Newer browsers expose positionX/Y/Z as AudioParams; older ones expose
	// setPosition(). Support both.
	if (L.positionX) {
		L.positionX.value = x;
		L.positionY.value = 0;
		L.positionZ.value = z;
	} else if (L.setPosition) {
		L.setPosition(x, 0, z);
	}
}

function setListener(xPx, yPx) {
	listenerPx.x = xPx;
	listenerPx.y = yPx;
	applyListener();
}

function playSoundAt(soundIdx, xPx, yPx) {
	const variants = SOUND_FILES[soundIdx];
	if (!variants || variants.length === 0 || !audioCtx) return;
	resumeAudio();

	// Share the per-family cooldown with the non-spatial path so a salvo of
	// turret shots and a UI click of the same family don't fight each other.
	const minIv = SOUND_MIN_INTERVAL_MS[soundIdx] || 0;
	const now = performance.now();
	if (minIv > 0 && now - lastPlayedMs[soundIdx] < minIv) return;

	// Concurrent-voice cap: drop the play if too many copies are still ringing.
	const maxVoices = SOUND_MAX_VOICES[soundIdx] || 0;
	if (maxVoices > 0 && activeVoiceCount[soundIdx] >= maxVoices) return;

	const variantIdx = (Math.random() * variants.length) | 0;
	const buf = audioBuffers[soundIdx][variantIdx];
	if (!buf) return;

	lastPlayedMs[soundIdx] = now;
	activeVoiceCount[soundIdx]++;

	const src = audioCtx.createBufferSource();
	src.buffer = buf;
	src.onended = () => { activeVoiceCount[soundIdx]--; };
	const gain = audioCtx.createGain();
	gain.gain.value = Math.min(1, SOUND_GAIN[soundIdx] ?? 1);
	const panner = audioCtx.createPanner();
	panner.panningModel    = 'HRTF';
	panner.distanceModel   = 'linear';
	panner.refDistance     = AUDIO_REF_DISTANCE;
	panner.maxDistance     = AUDIO_MAX_DISTANCE;
	panner.rolloffFactor   = AUDIO_ROLLOFF;
	const x = xPx / AUDIO_PIXELS_PER_UNIT;
	const z = yPx / AUDIO_PIXELS_PER_UNIT;
	if (panner.positionX) {
		panner.positionX.value = x;
		panner.positionY.value = 0;
		panner.positionZ.value = z;
	} else if (panner.setPosition) {
		panner.setPosition(x, 0, z);
	}
	src.connect(gain).connect(panner).connect(audioMasterGain);
	src.start();
}

// --- Music ------------------------------------------------------------------
//
// Background music mirrors the win32 design: shuffled track order with a
// bag-style no-repeat draw, crossfaded over MUSIC_CROSSFADE_S when the
// current track is near its end. Tracks are streamed via HTMLAudioElement
// (not decoded into AudioBuffers) so a 3-minute MP3 costs a small buffer
// instead of ~30 MB of decoded PCM per track.
//
// Volume math: each element's `.volume` = masterVolume × MUSIC_VOLUME × fade,
// where `fade` ramps 0→1 on start, 1→0 on outgoing. masterVolume comes from
// the pause-menu slider; MUSIC_VOLUME keeps music quieter than SFX baseline.

const MUSIC_FILES = [
	'res/sounds/music-01.mp3',
	'res/sounds/music-02.mp3',
	'res/sounds/music-03.mp3',
];
const MUSIC_CROSSFADE_S = 3.0;
const MUSIC_VOLUME      = 0.5;

const music = {
	enabled:  true,
	current:  null,  // { audio, idx, fade }
	incoming: null,
	bag:      [],
	lastIdx:  -1,
	// `needsStart` flips true when play() is rejected by the browser's
	// autoplay policy. The next user gesture (resumeAudio) retries.
	needsStart: false,
};

function musicPickIdx() {
	if (music.bag.length === 0) {
		for (let i = 0; i < MUSIC_FILES.length; i++) music.bag.push(i);
		// Fisher–Yates shuffle.
		for (let i = music.bag.length - 1; i > 0; i--) {
			const j = (Math.random() * (i + 1)) | 0;
			const t = music.bag[i]; music.bag[i] = music.bag[j]; music.bag[j] = t;
		}
		// Don't let the first draw repeat the last-played track if we can avoid it.
		if (music.bag[0] === music.lastIdx && music.bag.length > 1) {
			const t = music.bag[0]; music.bag[0] = music.bag[1]; music.bag[1] = t;
		}
	}
	const idx = music.bag.shift();
	music.lastIdx = idx;
	return idx;
}

function musicSpawn(idx) {
	const a = new Audio(new URL(MUSIC_FILES[idx], import.meta.url).href);
	a.preload = 'auto';
	a.volume  = 0;
	const voice = { audio: a, idx, fade: 0 };
	a.play().catch(() => { music.needsStart = true; });
	return voice;
}

function musicTick(dt) {
	if (!music.enabled) return;

	// Cold start (or restart after a failed play()): begin a track.
	if (!music.current) {
		music.current = musicSpawn(musicPickIdx());
	}

	const cur = music.current;
	if (!cur) return;

	const fadeStep = dt / MUSIC_CROSSFADE_S;

	// Schedule the next track once we're inside the crossfade tail of the
	// current one. duration can read NaN briefly while metadata is loading.
	const dur = cur.audio.duration;
	const t   = cur.audio.currentTime || 0;
	if (!music.incoming && Number.isFinite(dur) && dur > 0 && t > 0 && (dur - t) <= MUSIC_CROSSFADE_S) {
		music.incoming = musicSpawn(musicPickIdx());
	}

	if (music.incoming) {
		// Crossfade: outgoing ramps down, incoming ramps up. When the outgoing
		// hits zero we drop it and promote the incoming.
		cur.fade           = Math.max(0, cur.fade - fadeStep);
		music.incoming.fade = Math.min(1, music.incoming.fade + fadeStep);
		if (cur.fade <= 0) {
			try { cur.audio.pause(); cur.audio.src = ''; cur.audio.load(); } catch {}
			music.current = music.incoming;
			music.incoming = null;
		}
	} else {
		// Plain fade-in on the active track.
		cur.fade = Math.min(1, cur.fade + fadeStep);
	}

	// If the active track ended outside a crossfade (very short clip, or seek
	// past end), kick the next one cleanly on the following tick.
	if (music.current && music.current.audio.ended) {
		music.current = null;
	}

	// Apply combined volume to every live element. HTMLMediaElement.volume
	// is a strict [0, 1] range — any value outside that throws synchronously
	// (IndexSizeError), which would kill the RAF loop entirely. Clamp on
	// both ends to be safe against floating-point drift in `fade`.
	const mix  = MUSIC_VOLUME * masterVolume;
	const clip = (v) => Math.max(0, Math.min(1, v));
	if (music.current)  music.current.audio.volume  = clip(music.current.fade  * mix);
	if (music.incoming) music.incoming.audio.volume = clip(music.incoming.fade * mix);
}

function musicPause() {
	try { music.current?.audio.pause(); } catch {}
	try { music.incoming?.audio.pause(); } catch {}
}
function musicResume() {
	if (!music.enabled) return;
	music.current?.audio.play().catch(() => { music.needsStart = true; });
	music.incoming?.audio.play().catch(() => { music.needsStart = true; });
}

// Looped spatial voices, one per Sound family. Driven by `js_set_sound_loop`
// the same way the win32 backend uses `audio_set_loop` — the game flips this
// each frame based on whether any flak cannon is firing; the source stays alive
// across frames and just moves as the emitter centroid drifts.
const loopVoices = new Array(SOUND_FILES.length).fill(null);

function setSoundLoop(soundIdx, active, xPx, yPx) {
	const variants = SOUND_FILES[soundIdx];
	if (!variants || variants.length === 0) return;
	const existing = loopVoices[soundIdx];
	if (!active) {
		if (!existing) return;
		try { existing.src.stop(); } catch {}
		try { existing.src.disconnect(); } catch {}
		try { existing.panner.disconnect(); } catch {}
		loopVoices[soundIdx] = null;
		return;
	}
	if (!audioCtx) return;
	resumeAudio();

	const x = xPx / AUDIO_PIXELS_PER_UNIT;
	const z = yPx / AUDIO_PIXELS_PER_UNIT;
	if (existing) {
		const p = existing.panner;
		if (p.positionX) { p.positionX.value = x; p.positionZ.value = z; }
		else if (p.setPosition) p.setPosition(x, 0, z);
		return;
	}
	const variantIdx = (Math.random() * variants.length) | 0;
	const buf = audioBuffers[soundIdx][variantIdx];
	if (!buf) return;

	const src = audioCtx.createBufferSource();
	src.buffer = buf;
	src.loop = true;
	const gain = audioCtx.createGain();
	gain.gain.value = Math.min(1, SOUND_GAIN[soundIdx] ?? 1);
	const panner = audioCtx.createPanner();
	panner.panningModel  = 'HRTF';
	panner.distanceModel = 'linear';
	panner.refDistance   = AUDIO_REF_DISTANCE;
	panner.maxDistance   = AUDIO_MAX_DISTANCE;
	panner.rolloffFactor = AUDIO_ROLLOFF;
	if (panner.positionX) {
		panner.positionX.value = x;
		panner.positionY.value = 0;
		panner.positionZ.value = z;
	} else if (panner.setPosition) {
		panner.setPosition(x, 0, z);
	}
	src.connect(gain).connect(panner).connect(audioMasterGain);
	src.start();
	loopVoices[soundIdx] = { src, panner };
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
	// `window.close()` is blocked in CrazyGames iframes and flagged by review,
	// so we soft-pause instead: drop gameplay state and let the host decide
	// (e.g. CrazyGames may show its own exit prompt). The game currently never
	// triggers this — kept as a no-op for safety.
	js_request_quit: () => { setGameplayActive(false); },
	js_play_sound:        (sound) => { playSound(sound); },
	js_play_sound_at:     (sound, x, y) => { playSoundAt(sound, x, y); },
	js_set_sound_loop:    (sound, active, x, y) => { if (typeof setSoundLoop === "function") setSoundLoop(sound, active !== 0, x, y); },
	js_set_listener:      (x, y) => { setListener(x, y); },
	js_set_master_volume: (v)     => {
		masterVolume = Math.max(0, Math.min(1, v));
		if (audioMasterGain) audioMasterGain.gain.value = masterVolume;
	},
	js_set_gameplay_active: (active) => { setGameplayActive(active !== 0); },
	js_save_f32: (ptr, len, value) => {
		const key = decodeString(ptr, len);
		if (!key) return;
		storageSet(key, String(value));
	},
	js_load_f32: (ptr, len, def) => {
		const key = decodeString(ptr, len);
		if (!key) return def;
		const raw = storageGet(key);
		if (raw === null || raw === undefined) return def;
		const v = parseFloat(raw);
		return Number.isFinite(v) ? v : def;
	},
};

// --- Input mapping. Indices must match the Key enum in client/game/platform.odin.
// 0=Unknown, then W,A,S,D, C,B,R,V,N,Q,E,F, Num1..Num7, Escape, Enter, Space,
// Left_Shift, Right_Shift, F6. If you reorder the Odin enum, update this table.
const KEY = {
	KeyW: 1, KeyA: 2, KeyS: 3, KeyD: 4,
	KeyC: 5, KeyB: 6, KeyR: 7, KeyV: 8, KeyN: 9, KeyQ: 10, KeyE: 11, KeyF: 12,
	Digit1: 13, Digit2: 14, Digit3: 15, Digit4: 16, Digit5: 17, Digit6: 18, Digit7: 19,
	Escape: 20, Enter: 21, Space: 22,
	ShiftLeft: 23, ShiftRight: 24,
	F6: 25,
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

// --- Streaming fetch with progress -----------------------------------------
//
// Used to drive the splash bar for both the wasm and every sound file. The
// caller passes a `report(url, total, received)` callback (or null); we tally
// bytes as chunks arrive. If Content-Length is missing (some CDNs strip it
// with chunked encoding) we report only `received` and the bar's denominator
// stays approximate — the progress estimator below copes by averaging.
async function fetchWithProgress(url, report) {
	const resp = await fetch(url);
	if (!resp.ok) throw new Error(url + ': ' + resp.status);
	const total = parseInt(resp.headers.get('Content-Length') || '0', 10) || 0;
	if (report) report(url, total, 0);

	const reader = resp.body && resp.body.getReader ? resp.body.getReader() : null;
	if (!reader) {
		// Old browser without ReadableStream — just buffer it whole.
		const bytes = new Uint8Array(await resp.arrayBuffer());
		if (report) report(url, bytes.byteLength, bytes.byteLength);
		return bytes;
	}

	const chunks = [];
	let received = 0;
	for (;;) {
		const { done, value } = await reader.read();
		if (done) break;
		chunks.push(value);
		received += value.byteLength;
		if (report) report(url, total || received, received);
	}
	const out = new Uint8Array(received);
	let off = 0;
	for (const c of chunks) { out.set(c, off); off += c.byteLength; }
	return out;
}

// --- Responsive sizing ------------------------------------------------------
// CrazyGames embeds in iframes of varying sizes (desktop ~1280×720 default,
// mobile portrait can be ~360×640). Match both canvases' internal pixel
// dimensions to the viewport so the game (which renders directly in
// screen-pixel coords) fills the iframe at 1:1 without letterboxing.
const bgStage = document.getElementById('stage');
function resizeCanvases() {
	const w = Math.max(1, window.innerWidth  | 0);
	const h = Math.max(1, window.innerHeight | 0);
	if (canvas.width  !== w) canvas.width  = w;
	if (canvas.height !== h) canvas.height = h;
	if (bgCanvas && (bgCanvas.width !== w || bgCanvas.height !== h)) {
		bgCanvas.width  = w;
		bgCanvas.height = h;
	}
}
resizeCanvases();
window.addEventListener('resize', resizeCanvases);

// --- Window blur / tab-hidden handling --------------------------------------
// When the player tabs away or the browser hides the iframe, force the game
// into the pause menu and suspend audio. Otherwise:
//   - requestAnimationFrame throttles to ~1 Hz (or stops entirely), and the
//     first frame back receives a huge `dt` that spikes the simulation.
//   - Looping audio (flak cannon spray) keeps ringing in the background.
// We deliberately don't auto-resume on focus — the player explicitly clicks
// Resume when they're ready, which matches every other web game's UX.
function handleHostBlur() {
	if (exports && exports.web_blur) {
		try { exports.web_blur(); } catch {}
	}
	if (audioCtx && audioCtx.state === 'running') {
		audioCtx.suspend().catch(() => {});
	}
	musicPause();
	// CrazyGames SDK: gameplayStop fires naturally next frame via
	// js_set_gameplay_active (the game writes !paused into gameplay_active),
	// so no extra call is needed here.
}
function handleHostFocus() {
	// Audio context resumes here so background music / UI hover sounds work
	// the instant the player clicks Resume; the game itself stays paused.
	resumeAudio();
	musicResume();
}
document.addEventListener('visibilitychange', () => {
	if (document.hidden) handleHostBlur();
	else                 handleHostFocus();
});
window.addEventListener('blur',  handleHostBlur);
window.addEventListener('focus', handleHostFocus);

let mouseX = 0, mouseY = 0, mouseLeft = 0, mouseRight = 0, scrollDy = 0;

canvas.addEventListener('mousemove', (e) => {
	const r = canvas.getBoundingClientRect();
	mouseX = (e.clientX - r.left) * (canvas.width  / r.width);
	mouseY = (e.clientY - r.top)  * (canvas.height / r.height);
});
canvas.addEventListener('mousedown', (e) => {
	canvas.focus();
	// First input event: resume the AudioContext (browsers create it in
	// `suspended` without a user gesture). resume() is idempotent on an
	// already-running context.
	resumeAudio();
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
	resumeAudio();
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
		// Init the CrazyGames SDK first so it can register our loading window
		// (and so storageGet during web_init can hit cloud save). If the SDK
		// isn't present we skip silently — the game still runs.
		await initCrazyGames();

		const cgGame = (cgReady && CG.game) ? CG.game : null;
		const callLoadingStart = () => {
			if (!cgGame) return;
			try { (cgGame.sdkGameLoadingStart || cgGame.loadingStart)?.call(cgGame); } catch {}
		};
		const callLoadingStop = () => {
			if (!cgGame) return;
			try { (cgGame.sdkGameLoadingStop  || cgGame.loadingStop )?.call(cgGame); } catch {}
		};
		callLoadingStart();

		// Combined-progress book-keeping. One entry per URL we fetch (wasm +
		// every sound). `total` is whatever the server reports; if a server
		// strips Content-Length we fall back to "treat received as total so
		// far", which means the bar floats up to ~100% by the time everything
		// finishes (without ever appearing to go backwards).
		const progressItems = new Map();
		const reportProgress = (url, total, received) => {
			progressItems.set(url, { total: total || received || 0, received });
			let r = 0, t = 0;
			for (const p of progressItems.values()) { r += p.received; t += p.total; }
			setProgress(t > 0 ? r / t : 0);
			// Friendly status text: "loading… 4.2 / 8.1 MB"
			if (t > 0) {
				const mb = (b) => (b / (1024 * 1024)).toFixed(1);
				setStatus('loading…  ' + mb(r) + ' / ' + mb(t) + ' MB');
			}
		};

		// Fetch wasm and every sound file in parallel so the progress bar
		// reflects the true wait. Audio decode runs as each fetch completes.
		const wasmUrl = new URL('client.wasm', import.meta.url).href;
		const wasmBytesPromise = fetchWithProgress(wasmUrl, reportProgress);
		const audioPromise     = preloadAudio(reportProgress);

		const wasmBytes = await wasmBytesPromise;
		setStatus('initializing…');
		const result = await WebAssembly.instantiate(wasmBytes, imports);
		exports = result.instance.exports;
		memory  = exports.memory;

		// Wait for audio decode to finish too so the splash doesn't disappear
		// while the player is still waiting for sounds to be ready.
		await audioPromise;
		setProgress(1);

		initBackgroundGL();
		exports.web_init();
		hideSplash();
		canvas.focus();

		callLoadingStop();

		const start = performance.now();
		let last = start;
		function frame(now) {
			// Clamp dt so a long requestAnimationFrame gap (tab hidden, system
			// sleep, debugger pause) can't slam the simulation with a huge
			// step on the next frame. 100 ms is generous — anything beyond
			// that is "the game was paused, treat this frame like any other".
			// The Math.max(0, …) guard handles a Chrome quirk where the rAF
			// timestamp and the `last`-time snapshot from `performance.now()`
			// can come from different clock samples, occasionally producing a
			// tiny negative delta on the first frame.
			const dt    = Math.max(0, Math.min((now - last) / 1000, 0.1));
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

			// Tick music last so it picks up the freshest masterVolume the
			// game just pushed via js_set_master_volume.
			musicTick(dt);

			// Render bg after web_frame so we use the fog lights and camera
			// the game just pushed. Layering is by canvas stacking, not by
			// draw order, so doing this last is safe.
			renderBackground(time);

			requestAnimationFrame(frame);
		}
		requestAnimationFrame(frame);
	} catch (err) {
		setStatus('failed to load: ' + err.message);
		console.error(err);
	}
})();
