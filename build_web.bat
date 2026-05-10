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

echo.
echo Web build complete: build\web\
echo Serve with: py -m http.server -d build\web 8000
