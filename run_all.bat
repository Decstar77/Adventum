@echo off
call build.bat
if %ERRORLEVEL% neq 0 (
    pause
    exit /b %ERRORLEVEL%
)

start "Adventum Server" "build/server.exe"
call "build/client.exe"
