@echo off
call build.bat
if %ERRORLEVEL% neq 0 (
    pause
    exit /b %ERRORLEVEL%
)
call "build/client.exe"