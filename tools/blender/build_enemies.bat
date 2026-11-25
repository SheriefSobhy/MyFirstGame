@echo off
rem Builds the enemy models from the Mixamo FBX files in art_source\mixamo\
rem (git-ignored, never committed) into assets\models\enemies\:
rem   1. Godot reads the FBX files (Blender can't read the old FBX 6.1 ones)
rem      and writes art_source\build\<id>_raw.glb
rem   2. Blender makes the 3 detail levels <id>_high/med/low.glb
rem   3. Godot imports them, sets their textures to VRAM compression,
rem      reimports, and retargets the animations into <id>_anims.res
setlocal
cd /d "%~dp0..\.."
set "GODOT=C:\Godot\Godot_v4.7.2-stable_win64_console.exe"
set "BLENDER=C:\Program Files\Blender Foundation\Blender 5.3\blender.exe"
"%GODOT%" --headless --path . --script res://tools/mixamo_export.gd || goto :fail
"%BLENDER%" -b --factory-startup --python tools\blender\build_enemies.py || goto :fail
"%GODOT%" --headless --path . --import
"%GODOT%" --headless --path . --script res://tools/mixamo_anims.gd -- --textures-only || goto :fail
"%GODOT%" --headless --path . --import
"%GODOT%" --headless --path . --script res://tools/mixamo_anims.gd || goto :fail
echo Enemy models built.
endlocal
exit /b 0
:fail
echo Enemy model build FAILED.
endlocal
exit /b 1
