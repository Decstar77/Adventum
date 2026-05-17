@echo off
rem Build the browser target. Output lands in build\web\ alongside the static
rem assets (index.html + host.js). Serve over HTTP -- file:// will not satisfy
rem WebAssembly.instantiateStreaming.

if not exist build\web mkdir build\web

odin build client/web -target:js_wasm32 -out:build/web/client.wasm
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

copy /y client\web\index.html build\web\index.html >nul
copy /y client\web\host.js     build\web\host.js     >nul

rem Mirror runtime assets (sounds, fonts, sprites) so the dev server rooted
rem at build\web\ can serve them alongside the wasm.
if not exist build\web\res mkdir build\web\res
xcopy /e /y /i /q res build\web\res >nul

rem Strip the assets the web build doesn't use: the .wav source SFX (web
rem loads the .ogg siblings produced by compress_audio.bat) and the music
rem mp3s (not yet wired into the web audio path — see host.js SOUND_FILES).
rem Keeping these in res\ for the win32 build but out of the upload zip is
rem the difference between a ~5 MB and a ~40 MB CrazyGames upload.
if exist build\web\res\sounds\*.wav del /q build\web\res\sounds\*.wav >nul
if exist build\web\res\sounds\music-*.mp3 del /q build\web\res\sounds\music-*.mp3 >nul

echo.
echo Web build complete: build\web\
echo Serve with: py -m http.server -d build\web 8000
