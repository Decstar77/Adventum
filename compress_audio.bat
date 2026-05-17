@echo off
rem Generate .ogg siblings for every SFX .wav in res\sounds\. The .wav files
rem are kept so the win32 build (miniaudio, no Vorbis decoder by default)
rem keeps working; the web build picks up the .ogg files instead — see
rem client\web\host.js SOUND_FILES and build_web.bat's copy step.
rem
rem Vorbis quality 3 ≈ ~96 kbps; mono since none of these SFX are mixed in
rem stereo intentionally. If a clip really needs stereo (e.g. building-explode
rem with wide reverb), drop "-ac 1" for that one file and re-run.

where ffmpeg >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo ffmpeg not on PATH — install it or update the script.
    exit /b 1
)

pushd res\sounds
for %%F in (*.wav) do (
    echo Encoding %%~nF.ogg
    ffmpeg -y -loglevel error -i "%%F" -c:a libvorbis -q:a 3 -ac 1 "%%~nF.ogg"
    if errorlevel 1 (
        echo failed on %%F
        popd
        exit /b 1
    )
)
popd

echo.
echo Done. Run build_web.bat to rebuild the web target with the .ogg assets.
