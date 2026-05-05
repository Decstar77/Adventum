@echo off
setlocal enabledelayedexpansion

rem Web/wasm build via emscripten + Odin's wasm32 freestanding target.
rem
rem Self-bootstraps: sources the bundled emsdk to put emcc/emar on PATH,
rem builds the sokol wasm clibs on first run if missing, then compiles
rem the Odin client to wasm and links via emcc into build\web\index.html.
rem
rem Prereq: the bundled .\emsdk must already be installed/activated once:
rem     emsdk\emsdk install latest
rem     emsdk\emsdk activate latest

rem 1) Put emcc/emar on PATH for this shell.
call "%~dp0emsdk\emsdk_env.bat" >nul 2>&1

where emcc >nul 2>nul
if errorlevel 1 (
    echo emcc not on PATH after sourcing emsdk_env.bat. Activate emsdk first:
    echo     emsdk\emsdk install latest ^&^& emsdk\emsdk activate latest
    exit /b 1
)

rem 2) Build the sokol wasm clibs if they're missing. Presence of the gfx
rem    release .a is the sentinel.
if not exist "%~dp0client\sokol\gfx\sokol_gfx_wasm_gl_release.a" call :build_clibs || exit /b 1

if not exist "%~dp0build\web" mkdir "%~dp0build\web"

rem 3) Compile the Odin client to a wasm object file (no linking).
odin build client ^
    -target:js_wasm32 ^
    -out:build/web/client.wasm.o ^
    -build-mode:obj ^
    -define:SOKOL_USE_GL=true
if errorlevel 1 exit /b 1

rem 4) Link with emcc, pulling in the sokol wasm clibs and producing index.html.
rem Locate Odin's vendored stb wasm objects. ODIN_ROOT lets us avoid hard-coding
rem the Odin install path; falls back to deriving it from `where odin`.
if "%ODIN_ROOT%"=="" (
    for /f "delims=" %%i in ('where odin') do set "ODIN_EXE=%%i"
    for %%i in ("!ODIN_EXE!") do set "ODIN_ROOT=%%~dpi"
)
set "STB_LIB_DIR=%ODIN_ROOT%vendor\stb\lib"

emcc build\web\client.wasm.o ^
    client\sokol\app\sokol_app_wasm_gl_release.a ^
    client\sokol\gfx\sokol_gfx_wasm_gl_release.a ^
    client\sokol\glue\sokol_glue_wasm_gl_release.a ^
    client\sokol\log\sokol_log_wasm_gl_release.a ^
    "%STB_LIB_DIR%\stb_truetype_wasm.o" ^
    -o build\web\index.html ^
    -sUSE_WEBGL2=1 ^
    -sFULL_ES3=1 ^
    -sALLOW_MEMORY_GROWTH=1 ^
    -sERROR_ON_UNDEFINED_SYMBOLS=0 ^
    --pre-js client\web\odin.js ^
    --preload-file res
if errorlevel 1 exit /b 1

echo.
echo Built build\web\index.html. Serve it from a local HTTP server, e.g.:
echo   python -m http.server -d build\web 8000

endlocal
exit /b 0

:build_clibs
echo Building sokol wasm clibs ^(one-time^)...
pushd "%~dp0client\sokol"
call .\build_clibs_wasm.bat
set "CLIB_ERR=%ERRORLEVEL%"
popd
if not "%CLIB_ERR%"=="0" (
    echo sokol wasm clib build failed ^(exit %CLIB_ERR%^).
    exit /b %CLIB_ERR%
)
exit /b 0
