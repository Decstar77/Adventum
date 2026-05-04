@echo off
rem Web/wasm build via emscripten + Odin's wasm32 freestanding target.
rem
rem Prerequisites (one-time):
rem   1) Install emsdk and run emsdk_env.bat in this shell so emcc is on PATH.
rem   2) Build the sokol wasm clibs. There is no script for that in this repo;
rem      grab build_clibs_emcc.sh from the upstream sokol-odin repo and run it
rem      under emsdk. It produces:
rem        client/sokol/app/sokol_app_wasm_gl_{debug,release}.a
rem        client/sokol/gfx/sokol_gfx_wasm_gl_{debug,release}.a
rem        client/sokol/glue/sokol_glue_wasm_gl_{debug,release}.a
rem        client/sokol/log/sokol_log_wasm_gl_{debug,release}.a
rem      Until those are present this build will fail with link errors.
rem
rem   3) Run from a shell with emcc, emar, etc. on PATH.

if not exist build\web mkdir build\web

rem Compile the Odin client to a wasm object file (no linking).
odin build client ^
    -target:freestanding_wasm32 ^
    -out:build/web/client.wasm.o ^
    -build-mode:obj ^
    -define:SOKOL_USE_GL=true ^
    -no-entry-point
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

rem Link with emcc, pulling in the sokol wasm clibs and producing index.html.
emcc build\web\client.wasm.o ^
    client\sokol\app\sokol_app_wasm_gl_release.a ^
    client\sokol\gfx\sokol_gfx_wasm_gl_release.a ^
    client\sokol\glue\sokol_glue_wasm_gl_release.a ^
    client\sokol\log\sokol_log_wasm_gl_release.a ^
    -o build\web\index.html ^
    -sUSE_WEBGL2=1 ^
    -sFULL_ES3=1 ^
    -sALLOW_MEMORY_GROWTH=1 ^
    --preload-file res
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

echo.
echo Built build\web\index.html. Serve it from a local HTTP server, e.g.:
echo   python -m http.server -d build\web 8000
