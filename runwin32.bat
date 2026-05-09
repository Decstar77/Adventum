@echo off
call buildwin32.bat
if %ERRORLEVEL% neq 0 (
    pause
    exit /b %ERRORLEVEL%
)

call "build/client.exe"
