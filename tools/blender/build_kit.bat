@echo off
rem Builds the modular level kit with Blender (headless): texture atlas,
rem pieces + LOD1, baked AO, exported to assets/models/kit/kit.glb.
rem Then rebuild the maps with Godot:
rem   tools/blender/rebuild_maps.bat
setlocal
cd /d "%~dp0..\.."
set "BLENDER=C:\Program Files\Blender Foundation\Blender 5.3\blender.exe"
"%BLENDER%" -b --factory-startup --python tools\blender\build_kit.py
endlocal
