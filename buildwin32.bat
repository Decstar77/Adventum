@echo off

rem compile shaders
"%VULKAN_SDK%\Bin\glslc.exe" client/shaders/shapes.vert -o client/shaders/shapes.vert.spv
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
"%VULKAN_SDK%\Bin\glslc.exe" client/shaders/shapes.frag -o client/shaders/shapes.frag.spv
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
"%VULKAN_SDK%\Bin\glslc.exe" client/shaders/text.vert -o client/shaders/text.vert.spv
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
"%VULKAN_SDK%\Bin\glslc.exe" client/shaders/text.frag -o client/shaders/text.frag.spv
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
"%VULKAN_SDK%\Bin\glslc.exe" client/shaders/background.vert -o client/shaders/background.vert.spv
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
"%VULKAN_SDK%\Bin\glslc.exe" client/shaders/background.frag -o client/shaders/background.frag.spv
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

rem build client (win32 host; pulls in client/game as a sibling package)
odin build client/win32 -debug -out:build/client.exe
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
