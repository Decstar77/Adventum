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

rem build client
odin build client -debug -out:build/client.exe
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
