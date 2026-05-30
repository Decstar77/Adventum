@echo off
rem Generate .ogg siblings for every SFX .wav in client\game1\res\sounds\. The .wav files
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

pushd client\game1\res\sounds
for %%F in (*.wav) do (
    echo Encoding %%~nF.ogg
    ffmpeg -y -loglevel error -i "%%F" -c:a libvorbis -q:a 3 -ac 1 "%%~nF.ogg"
    if errorlevel 1 (
        echo failed on %%F
        popd
        exit /b 1
    )
)

rem Re-encode music tracks in place at 96 kbps stereo. The originals are
rem committed to git, so if you ever want the higher-quality source back you
rem can `git checkout client/game1/res/sounds/music-*.mp3`. ffmpeg refuses to write to the
rem input path so we go via a .tmp.mp3 sibling.
for %%F in (music-*.mp3) do (
    echo Re-encoding %%F
    ffmpeg -y -loglevel error -i "%%F" -c:a libmp3lame -b:a 96k -ac 2 "%%~nF.tmp.mp3"
    if errorlevel 1 (
        echo failed on %%F
        popd
        exit /b 1
    )
    move /y "%%~nF.tmp.mp3" "%%F" >nul
)
popd

echo.
echo Done. Run build_web.bat to rebuild the web target with the .ogg assets.
