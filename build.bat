@echo off

rem https://github.com/floooh/sokol-tools/blob/master/docs/sokol-shdc.md
sokol-shdc -i client/shader.glsl -o client/shader.odin -l hlsl5:wgsl -f sokol_odin
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

rem build client
odin build client -debug -out:build/client.exe
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

rem build server
odin build server -debug -out:build/server.exe
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
