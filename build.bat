@echo off
rem Native (Windows) build. Sokol GL backend - set SOKOL_USE_GL so sokol_app /
rem sokol_gfx link against the GL clibs and so the Odin code selects GL shaders.
if not exist build mkdir build
odin build client -debug -out:build/client.exe -define:SOKOL_USE_GL=true
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
