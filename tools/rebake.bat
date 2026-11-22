@echo off
rem Re-bakes the navmesh (level_navmesh.res) and the lightmap (main.lmbake / main.exr)
rem after the level changes. Opens the editor briefly; it closes by itself.
rem If you changed the generated level detail, first run:
rem   Godot_v4.7.2-stable_win64_console.exe --headless --path . --script res://tools/build_level.gd
setlocal
cd /d "%~dp0.."
set "GODOT=C:\Godot\Godot_v4.7.2-stable_win64_console.exe"
"%GODOT%" --editor --path . -- --autobake
rem Store the lightmap uncompressed: the HDR VRAM formats (BPTC / ASTC-HDR)
rem are missing on many phone GPUs, which would make the lightmap black there.
powershell -NoProfile -Command "(Get-Content main.exr.import) -replace '^compress/mode=.*','compress/mode=3' | Set-Content main.exr.import"
"%GODOT%" --headless --path . --import
endlocal
