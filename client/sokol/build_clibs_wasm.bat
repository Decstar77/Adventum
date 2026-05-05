@echo off

set sources=log app gfx glue time audio debugtext shape gl

REM sokol_app's emscripten path provides its own main() unless SOKOL_NO_ENTRY
REM is defined. Odin's sapp.run binding expects NO_ENTRY mode (its bindings
REM comment notes that in standard mode the run() symbol is "an empty stub").
set extra_app=-DSOKOL_NO_ENTRY

REM Debug
for %%s in (%sources%) do (
    echo %%s\sokol_%%s_wasm_gl_debug.a
    if /I "%%s"=="app" (
        call emcc -c -g -DIMPL -DSOKOL_GLES3 %extra_app% c\sokol_%%s.c
    ) else (
        call emcc -c -g -DIMPL -DSOKOL_GLES3 c\sokol_%%s.c
    )
    call emar rcs %%s\sokol_%%s_wasm_gl_debug.a sokol_%%s.o
    del sokol_%%s.o
)

REM Release
for %%s in (%sources%) do (
    echo %%s\sokol_%%s_wasm_gl_release.a
    if /I "%%s"=="app" (
        call emcc -c -O2 -DNDEBUG -DIMPL -DSOKOL_GLES3 %extra_app% c\sokol_%%s.c
    ) else (
        call emcc -c -O2 -DNDEBUG -DIMPL -DSOKOL_GLES3 c\sokol_%%s.c
    )
    call emar rcs %%s\sokol_%%s_wasm_gl_release.a sokol_%%s.o
    del sokol_%%s.o
)
