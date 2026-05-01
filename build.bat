@echo off

rem compile shaders
"%VULKAN_SDK%\Bin\glslc.exe" client/shaders/triangle.vert -o client/shaders/triangle.vert.spv
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
"%VULKAN_SDK%\Bin\glslc.exe" client/shaders/triangle.frag -o client/shaders/triangle.frag.spv
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
"%VULKAN_SDK%\Bin\glslc.exe" client/shaders/text.vert -o client/shaders/text.vert.spv
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
"%VULKAN_SDK%\Bin\glslc.exe" client/shaders/text.frag -o client/shaders/text.frag.spv
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

rem build client
odin build client -debug -out:build/client.exe
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
