@echo off
rem Builds the first-person guns and arms (git-ignored sources, never committed):
rem   1. Blender: art_source\sketchfab\*.zip -> assets\models\guns\<id>_high/med/low.glb
rem   2. Blender: art_source\mixamo\soldier.fbx -> assets\models\arms\arms_high/med/low.glb
rem   3. Godot imports them, sets their import options (no auto LODs, VRAM
rem      textures, normal maps), and imports again.
setlocal
cd /d "%~dp0..\.."
set "GODOT=C:\Godot\Godot_v4.7.2-stable_win64_console.exe"
set "BLENDER=C:\Program Files\Blender Foundation\Blender 5.3\blender.exe"
"%BLENDER%" -b --factory-startup --python tools\blender\build_guns.py || goto :fail
"%BLENDER%" -b --factory-startup --python tools\blender\build_arms.py || goto :fail
"%GODOT%" --headless --path . --import
"%GODOT%" --headless --path . --script res://tools/gun_imports.gd || goto :fail
"%GODOT%" --headless --path . --import
echo Guns and arms built.
endlocal
exit /b 0
:fail
echo Gun / arms build FAILED.
endlocal
exit /b 1
