@echo off
rem Re-bakes the lightmaps (main.lmbake / main.exr for the yard,
rem maps/training.lmbake / .exr for the Training Arena) and every map's
rem navmeshes (tools/bake_navmesh.gd) after the level changes. Opens the
rem editor briefly; it closes by itself.
rem   rebake.bat            both lightmaps
rem   rebake.bat training   only the Training Arena's lightmap (or: yard)
rem If you changed the generated level detail, first run:
rem   Godot_v4.7.2-stable_win64_console.exe --headless --path . --script res://tools/build_level.gd
setlocal
cd /d "%~dp0.."
set "GODOT=C:\Godot\Godot_v4.7.2-stable_win64_console.exe"
set "BAKE=--autobake"
if not "%~1"=="" set "BAKE=--autobake=%~1"
rem Import new/changed files headless first (CPU texture compression): the
rem editor compresses VRAM textures on the GPU, which crashed it on this PC.
"%GODOT%" --headless --path . --import
"%GODOT%" --editor --path . -- %BAKE%
"%GODOT%" --headless --path . --script res://tools/bake_navmesh.gd
rem Store the lightmaps uncompressed: the HDR VRAM formats (BPTC / ASTC-HDR)
rem are missing on many phone GPUs, which would make the lightmap black there.
for %%F in (main.exr.import maps\training.exr.import) do (
    if exist %%F powershell -NoProfile -Command "(Get-Content %%F) -replace '^compress/mode=.*','compress/mode=3' | Set-Content %%F"
)
"%GODOT%" --headless --path . --import
endlocal
