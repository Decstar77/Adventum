@echo off

rem https://github.com/floooh/sokol-tools/blob/master/docs/sokol-shdc.md
sokol-shdc -i client/shader.glsl -o client/shader.odin -l hlsl5:wgsl -f sokol_odin

rem call odin
odin build client -debug -out:build/client.exe
