// Host glue for the wasm build. Implements the foreign imports declared in
// client/web/main.odin, drives the frame loop via requestAnimationFrame, and
// forwards browser input into the wasm module.

const canvas = document.getElementById('screen');
const ctx    = canvas.getContext('2d');
const status = document.getElementById('status');

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
	js_set_camera:   (sx, sy, ox, oy) => { cam = { sx, sy, ox, oy }; },
	js_clear_camera: ()               => { cam = { sx: 1, sy: 1, ox: 0, oy: 0 }; },
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
};

// --- Input mapping. Indices must match the Key enum in client/game/platform.odin.
const KEY = {
	KeyW: 1, KeyA: 2, KeyS: 3, KeyD: 4,
	KeyC: 5, KeyB: 6, KeyR: 7,
	Digit1: 8, Digit2: 9, Digit3: 10, Digit4: 11, Digit5: 12, Digit6: 13,
	Escape: 14, Enter: 15,
	ShiftLeft: 16, ShiftRight: 17,
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
			// Equivalent of the win32 Vulkan render-pass clear; canvas keeps the
			// previous frame around otherwise.
			ctx.setTransform(1, 0, 0, 1, 0, 0);
			ctx.fillStyle = '#03030a';
			ctx.fillRect(0, 0, canvas.width, canvas.height);
			exports.web_frame(dt, time, canvas.width, canvas.height, mouseX, mouseY, dy, mouseLeft, mouseRight);
			requestAnimationFrame(frame);
		}
		requestAnimationFrame(frame);
	} catch (err) {
		status.textContent = 'failed to load: ' + err.message;
		console.error(err);
	}
})();
