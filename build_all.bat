@echo off
rem Exports the Android APK and the Windows exe into builds\ (git-ignored).
rem Does not commit or push. Use publish.bat for the web build.
setlocal
cd /d "%~dp0"

set "GODOT=C:\Godot\Godot_v4.7.2-stable_win64_console.exe"
if not exist "%GODOT%" (
    echo Godot not found at %GODOT%
    exit /b 1
)

if not exist builds mkdir builds
if not exist builds\windows mkdir builds\windows
rem Keep Godot from importing the exported files back into the project.
if not exist builds\.gdignore type nul > builds\.gdignore

set "FAILED="

echo === Exporting Android APK to builds\DeadPerimeter.apk ===
if exist builds\DeadPerimeter.apk del /q builds\DeadPerimeter.apk
"%GODOT%" --headless --path . --export-debug "Android" builds/DeadPerimeter.apk
if errorlevel 1 (
    set "FAILED=%FAILED% Android"
) else if not exist builds\DeadPerimeter.apk (
    set "FAILED=%FAILED% Android"
)

echo === Exporting Windows exe to builds\windows\DeadPerimeter.exe ===
if exist builds\windows\DeadPerimeter.exe del /q builds\windows\DeadPerimeter.exe
"%GODOT%" --headless --path . --export-release "Windows Desktop" builds/windows/DeadPerimeter.exe
if errorlevel 1 (
    set "FAILED=%FAILED% Windows"
) else if not exist builds\windows\DeadPerimeter.exe (
    set "FAILED=%FAILED% Windows"
)

if defined FAILED (
    echo === Export failed for:%FAILED% ===
    exit /b 1
)

echo === Done. ===
echo   builds\DeadPerimeter.apk
echo   builds\windows\DeadPerimeter.exe
endlocal
