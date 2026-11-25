@echo off
rem Re-bakes the lightmap (main.lmbake / main.exr) and every map's navmeshes
rem (tools/bake_navmesh.gd) after the level changes. Opens the editor briefly;
rem it closes by itself.
rem If you changed the generated level detail, first run:
rem   Godot_v4.7.2-stable_win64_console.exe --headless --path . --script res://tools/build_level.gd
setlocal
cd /d "%~dp0.."
set "GODOT=C:\Godot\Godot_v4.7.2-stable_win64_console.exe"
rem Import new/changed files headless first (CPU texture compression): the
rem editor compresses VRAM textures on the GPU, which crashed it on this PC.
"%GODOT%" --headless --path . --import
"%GODOT%" --editor --path . -- --autobake
"%GODOT%" --headless --path . --script res://tools/bake_navmesh.gd
rem Store the lightmap uncompressed: the HDR VRAM formats (BPTC / ASTC-HDR)
rem are missing on many phone GPUs, which would make the lightmap black there.
powershell -NoProfile -Command "(Get-Content main.exr.import) -replace '^compress/mode=.*','compress/mode=3' | Set-Content main.exr.import"
"%GODOT%" --headless --path . --import
endlocal
