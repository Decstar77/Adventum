// Pre-JS for emscripten: Odin's wasm output imports a non-default module
// namespace called "odin_env" (see core:fmt/fmt_js.odin, core:os/os_js.odin).
// Emscripten only populates "env" + "wasi_snapshot_preview1" out of the box,
// so without this hook the wasm fails to instantiate with:
//   "Import #0 'odin_env': module is not an object or function"
//
// We override Module.instantiateWasm to splice odin_env into the imports
// object before handing it to WebAssembly.instantiate. The implementations
// route Odin's print/eprint calls to console.log / console.error so logging
// surfaces in DevTools.

var OdinEnv = {
    write: function (fd, ptr, len) {
        var bytes = HEAPU8.subarray(ptr, ptr + len);
        var s = (typeof TextDecoder !== 'undefined')
            ? new TextDecoder('utf-8').decode(bytes)
            : Array.prototype.map.call(bytes, function (b) { return String.fromCharCode(b); }).join('');
        s = s.replace(/\n$/, '');
        if (s.length === 0) return;
        if (fd === 2) {
            console.error(s);
        } else {
            console.log(s);
        }
    },

    // core:math/math_basic_js.odin imports these from "odin_env" on the js
    // target (link_names sin/cos/pow/fmuladd/ln/exp). The wasm fails to
    // instantiate if any are missing.
    sin:     function (x) { return Math.sin(x); },
    cos:     function (x) { return Math.cos(x); },
    pow:     function (x, y) { return Math.pow(x, y); },
    ln:      function (x) { return Math.log(x); },
    exp:     function (x) { return Math.exp(x); },
    fmuladd: function (a, b, c) { return a * b + c; },

    // core:time/time_js.odin signatures:
    //   time_now() -> i64 (ms since epoch; Odin then multiplies by 1e6 for ns)
    //   tick_now() -> f64 (seconds; Odin multiplies by 1e6 for microseconds)
    //   time_sleep(ms: u32)
    time_now:  function () { return BigInt(Date.now()); },
    tick_now:  function () { return (typeof performance !== 'undefined' && performance.now) ? performance.now() / 1000.0 : 0; },
    time_sleep: function (_ms) { /* synchronous sleep is impossible on the main thread */ },

    // base:runtime + core:sys/wasm/js abort/trap helpers.
    trap:     function () { throw new Error('odin_env.trap'); },
    abort:    function () { throw new Error('odin_env.abort'); },
    alert:    function (ptr, len) {
        var s = new TextDecoder('utf-8').decode(HEAPU8.subarray(ptr, ptr + len));
        if (typeof window !== 'undefined' && window.alert) window.alert(s); else console.warn('[alert]', s);
    },
    evaluate: function (ptr, len) {
        var s = new TextDecoder('utf-8').decode(HEAPU8.subarray(ptr, ptr + len));
        // eslint-disable-next-line no-eval
        (0, eval)(s);
    },
    open:     function (urlPtr, urlLen, namePtr, nameLen, specsPtr, specsLen) {
        var dec = new TextDecoder('utf-8');
        var url   = dec.decode(HEAPU8.subarray(urlPtr,   urlPtr   + urlLen));
        var name  = dec.decode(HEAPU8.subarray(namePtr,  namePtr  + nameLen));
        var specs = dec.decode(HEAPU8.subarray(specsPtr, specsPtr + specsLen));
        if (typeof window !== 'undefined' && window.open) window.open(url, name, specs);
    },

    // core:crypto/rand_js.odin
    rand_bytes: function (ptr, len) {
        var view = new Uint8Array(HEAPU8.buffer, ptr, len);
        if (typeof crypto !== 'undefined' && crypto.getRandomValues) crypto.getRandomValues(view);
        else { for (var i = 0; i < len; i++) view[i] = (Math.random() * 256) | 0; }
    },
};

Module.instantiateWasm = function (imports, successCallback) {
    imports.odin_env = OdinEnv;

    function done(instance, module) {
        successCallback(instance, module);
    }

    if (Module.wasmBinary) {
        WebAssembly.instantiate(Module.wasmBinary, imports)
            .then(function (result) { done(result.instance, result.module); })
            .catch(function (err) { console.error('wasm instantiate failed:', err); throw err; });
        return {};
    }

    // Streaming path: wasmBinaryFile is the URL emscripten resolved.
    var url = (typeof Module.locateFile === 'function')
        ? Module.locateFile('index.wasm', '')
        : 'index.wasm';
    fetch(url, { credentials: 'same-origin' })
        .then(function (r) {
            if (typeof WebAssembly.instantiateStreaming === 'function') {
                return WebAssembly.instantiateStreaming(r, imports);
            }
            return r.arrayBuffer().then(function (buf) {
                return WebAssembly.instantiate(buf, imports);
            });
        })
        .then(function (result) { done(result.instance, result.module); })
        .catch(function (err) { console.error('wasm instantiate failed:', err); throw err; });
    return {};
};
